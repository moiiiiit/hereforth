#!/usr/bin/env python3
"""Run one hosted Codex or Claude Code trial against a synthetic Hereforth profile."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

PROMPT = "What did we decide about Juniper this week, and which decisions are missing from Ryan’s latest shared update?"
INSTRUCTION = "Use Hereforth evidence and cite sources."
TOOLS = {"ordinary": ["search_decisions", "team_standup", "read_passage"], "code": ["query_context"]}
WRITING_REMINDER = (" Before composing Hereforth prose, apply embedded Humanizer using get_writing_guide. "
                    "Request include_full_skill once when the native skill is unavailable. Preserve verbatim content.")
CREDENTIAL_OVERRIDES = {
    "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
}


def proxy(binary, profile, mode, log, incoming, outgoing):
    """Filter stock MCP discovery and invocation; observe without changing Code Mode."""
    environment = {**os.environ, "HEREFORTH_HOME": profile}
    arguments = [binary, "mcp"] + (["--code-mode"] if mode == "code" else [])
    with subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=environment) as child:
        requests = {}
        lock = threading.Lock()

        def output(message):
            with lock:
                outgoing.write(json.dumps(message) + "\n")
                outgoing.flush()

        def forward():
            for line in child.stdout:
                message = json.loads(line)
                method = requests.pop(message.get("id"), None)
                if method == "initialize" and "result" in message:
                    message["result"]["instructions"] = INSTRUCTION
                if method == "tools/list" and mode == "ordinary" and "result" in message:
                    result = message["result"]
                    result["tools"] = [tool for tool in result["tools"] if tool["name"] in TOOLS[mode]]
                    for tool in result["tools"]:
                        description = tool["description"]
                        if description.endswith(WRITING_REMINDER):
                            tool["description"] = description[:-len(WRITING_REMINDER)]
                output(message)

        reader = threading.Thread(target=forward, daemon=True)
        reader.start()
        try:
            for line in incoming:
                message = json.loads(line)
                method = message.get("method")
                if method == "tools/call":
                    name = message.get("params", {}).get("name")
                    permitted = name in TOOLS[mode]
                    with open(log, "a", encoding="utf-8") as trace:
                        trace.write(json.dumps({"name": name, "permitted": permitted,
                                               "arguments": message.get("params", {}).get("arguments", {})}) + "\n")
                    if not permitted:
                        output({"jsonrpc": "2.0", "id": message.get("id"),
                                "error": {"code": -32601, "message": "Tool outside benchmark allowlist"}})
                        continue
                if "id" in message:
                    requests[message["id"]] = method
                child.stdin.write(line.encode())
                child.stdin.flush()
        finally:
            child.stdin.close()
            reader.join(timeout=5)
            if child.poll() is None:
                child.terminate()


def relay(path):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.connect(path)

        def send():
            for line in sys.stdin.buffer:
                connection.sendall(line)
            connection.shutdown(socket.SHUT_WR)

        threading.Thread(target=send, daemon=True).start()
        with connection.makefile("rb") as incoming:
            for line in incoming:
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()


def isolation_profile():
    user_home = Path.home()
    codex_root = Path(os.environ.get("CODEX_HOME", user_home / ".codex"))
    claude_root = Path(os.environ.get("CLAUDE_CONFIG_DIR", user_home / ".claude"))
    folders = [user_home / ".agents", codex_root / "skills", claude_root / "skills"]
    files = [codex_root / "AGENTS.md", codex_root / "AGENTS.override.md", user_home / "AGENTS.md",
             user_home / "CLAUDE.md", claude_root / "CLAUDE.md"]
    rules = " ".join(f'({kind} {json.dumps(str(path.resolve()))})'
                     for kind, paths in [("subpath", folders), ("literal", files)] for path in paths)
    return "(version 1) (allow default) (deny file-read* " + rules + ")"


def cli_arguments(client, model, effort, config, bridge):
    if client == "claude":
        names = ",".join(f"mcp__hereforth__{name}" for name in bridge["names"])
        return ["claude", "-p", "--verbose", "--output-format", "stream-json",
                "--model", model, "--effort", effort, "--append-system-prompt", INSTRUCTION,
                "--restricted", "--no-session-persistence", "--setting-sources", "",
                "--disable-slash-commands", "--tools", "", "--allowedTools", names,
                "--permission-mode", "default", "--permission-prompts", "none",
                "--strict-mcp-config", "--mcp-config", str(config), "--", PROMPT]
    overrides = {
        "developer_instructions": INSTRUCTION,
        "model_reasoning_effort": effort,
        "project_doc_max_bytes": 0,
        "web_search": "disabled",
        "mcp_servers.hereforth.command": bridge["command"],
        "mcp_servers.hereforth.args": bridge["args"],
        "mcp_servers.hereforth.enabled_tools": bridge["names"],
        "mcp_servers.hereforth.required": True,
    }
    features = ["shell_tool", "apps", "plugins", "skill_search", "skill_mcp_dependency_install",
                "shell_snapshot", "memories", "multi_agent", "multi_agent_v2"]
    flags = [arg for feature in features for arg in ("--disable", feature)]
    return (["codex", "--ask-for-approval", "never", "exec", "--json", "--ephemeral",
             "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
             "--sandbox", "read-only", "--enable", "skip_host_skill_discovery",
             "--enable", "omit_skill_descriptions", "--model", model]
            + flags + [arg for key, value in overrides.items() for arg in ("-c", f"{key}={json.dumps(value)}")]
            + [PROMPT])


def summarize(client, events):
    if client == "codex":
        usage = next((event["usage"] for event in reversed(events) if event.get("type") == "turn.completed"), {})
        answers = [event["item"].get("text", "") for event in events if event.get("type") == "item.completed"
                   and event.get("item", {}).get("type") == "agent_message"]
        actual_model = next((event.get("model") for event in events if event.get("model")), None)
        return {"answer": answers[-1] if answers else "", "usage": usage, "actual_model": actual_model}
    result = next((event for event in reversed(events) if event.get("type") == "result"), {})
    init = next((event for event in events if event.get("type") == "system" and event.get("subtype") == "init"), {})
    usage = result.get("usage", {})
    totals = {
        "input_tokens": sum(usage.get(key, 0) for key in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")),
        "cached_input_tokens": usage.get("cache_read_input_tokens"),
        "output_tokens": usage.get("output_tokens"),
    } if usage else {}
    return {"answer": result.get("result", ""), "usage": totals, "actual_model": init.get("model"),
            "exposed_tools": init.get("tools"),
            "reported_error": result.get("is_error"), "turns": result.get("num_turns")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", choices=("codex", "claude"), required=True)
    parser.add_argument("--mode", choices=TOOLS, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--effort", default="medium")
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.profile = args.profile.resolve()
    if (args.profile.name != "owner" or not (args.profile / "hereforth.sqlite").is_file()
            or not (args.profile.parent / "rubric.json").is_file()):
        parser.error("Use the isolated owner directory created by the Juniper fixture.")
    args.output = args.output.resolve()
    args.output.mkdir(mode=0o700)
    environment = {key: value for key, value in os.environ.items() if key not in CREDENTIAL_OVERRIDES}
    with tempfile.TemporaryDirectory(prefix="hf-hosted-", dir="/tmp") as cwd, \
            (args.output / "events.jsonl").open("w") as output, (args.output / "stderr.log").open("w") as stderr:
        # Isolate the hosted CLI without making the independent Code Mode worker inherit a sandbox.
        relay_path = str(Path(cwd) / "mcp.sock")
        bridge = {"command": sys.executable, "args": [str(Path(__file__).resolve()), "--relay", relay_path],
                  "names": TOOLS[args.mode]}
        config = args.output / "mcp.json"
        config.write_text(json.dumps({"mcpServers": {"hereforth": {key: bridge[key] for key in ("command", "args")}}}))
        command = ["/usr/bin/sandbox-exec", "-p", isolation_profile()] + cli_arguments(
            args.client, args.model, args.effort, config, bridge)
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(relay_path)
            listener.listen(1)

            def serve():
                connection, _ = listener.accept()
                with connection, connection.makefile("r") as incoming, connection.makefile("w") as outgoing:
                    proxy(str(args.binary.resolve()), str(args.profile.resolve()), args.mode,
                          args.output / "tools.jsonl", incoming, outgoing)

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            began = time.monotonic()
            try:
                status = subprocess.run(command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                                        stdout=output, stderr=stderr, timeout=240).returncode
            except subprocess.TimeoutExpired:
                status = 124
            elapsed = round(time.monotonic() - began, 3)
            thread.join(timeout=1)
    events = []
    for line in (args.output / "events.jsonl").read_text().splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    summary = summarize(args.client, events)
    trace = args.output / "tools.jsonl"
    summary.update(client=args.client, mode=args.mode, requested_model=args.model, effort=args.effort,
                   wall_seconds=elapsed, exit_status=status,
                   tools=[json.loads(line)["name"] for line in trace.read_text().splitlines()] if trace.exists() else [])
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: value for key, value in summary.items() if key != "answer"}))
    return status


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--relay":
        relay(*sys.argv[2:])
    else:
        raise SystemExit(main())
