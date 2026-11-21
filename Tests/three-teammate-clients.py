"""Run three signed-in Codex clients against the synthetic three-teammate fixture."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time

ROLES = ("Ryan", "Priya", "Sam")
READS = {"search_decisions", "read_passage", "read_weekly_context", "list_conversations"}
ACTIVITY = {"publish_current_session", "update_session_activity"}
INSTRUCTION = "Use Hereforth evidence and cite sources."
WRITING_REMINDER = (" Before composing Hereforth prose, apply embedded Humanizer using get_writing_guide. "
                    "Request include_full_skill once when the native skill is unavailable. Preserve verbatim content.")
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
RECEIVER_KEY = re.compile(UUID + UUID, re.IGNORECASE)


def now():
    return datetime.now(timezone.utc).isoformat()


def env_for(home=None):
    forbidden = {"OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"}
    env = {key: value for key, value in os.environ.items() if key not in forbidden}
    if home:
        env["HEREFORTH_HOME"] = str(home)
    return env


def mcp(binary, home):
    return subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                            env=env_for(home))


def structured(result):
    if result.get("isError"):
        raise ValueError("Hereforth returned a tool error")
    return result.get("structuredContent") or json.loads(result["content"][0]["text"])


def rpc(child, req_id, method, params):
    value = dict(jsonrpc="2.0", id=req_id, method=method, params=params)
    child.stdin.write(json.dumps(value) + "\n")
    child.stdin.flush()
    reply = json.loads(child.stdout.readline())
    return reply["result"]


def establish(child):
    rpc(child, 1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "fixture-observer", "version": "1"}})


def observe(binary, homes, labels):
    with mcp(binary, homes["observer"]) as observer:
        establish(observer)
        sessions = {}
        for index, role in enumerate(ROLES, start=2):
            value = structured(rpc(observer, index, "tools/call", {
                "name": "list_peer_sessions", "arguments": {"peer": role},
            }))
            sessions[role] = next(item for item in value["sessions"] if item["label"] == labels[role])
        observer.stdin.close()
    local_activity = {}
    for role in ROLES:
        with mcp(binary, homes[role]) as reader:
            establish(reader)
            activity = structured(rpc(reader, 2, "tools/call", {"name": "get_assistant_activity", "arguments": {}}))
            local_activity[role] = next(item for item in activity["sessions"] if item["id"] == sessions[role]["id"])
            assert local_activity[role]["phase"] == "running"
            assert local_activity[role]["provenance"] == "local_mcp_publication"
            reader.stdin.close()
    return {"observed_at": now(), "sessions": sessions, "local_activity": local_activity}


def bridge(binary, home, names, trace, arrived=None, release=None):
    with mcp(binary, home) as child:
        requests = {}
        write_lock = threading.Lock()

        def send(message):
            with write_lock:
                sys.stdout.write(json.dumps(message) + "\n")
                sys.stdout.flush()

        def responses():
            for line in child.stdout:
                response = json.loads(line)
                method, tool, phase = requests.pop(response.get("id"), (None, None, None))
                data = response.get("result", {})
                if method == "initialize":
                    data["instructions"] = INSTRUCTION
                elif method == "tools/list":
                    data["tools"] = [item for item in data.get("tools", []) if item["name"] in names]
                    for item in data["tools"]:
                        if item["description"].endswith(WRITING_REMINDER):
                            item["description"] = item["description"][:-len(WRITING_REMINDER)]
                elif tool:
                    success = not data.get("isError") and "error" not in response
                    provenance = structured(data).get("provenance") if success and tool == "update_session_activity" else None
                    log({"event": "result", "tool": tool, "phase": phase, "ok": success, "provenance": provenance})
                    if arrived and phase == "running" and provenance == "assistant_reported":
                        arrived.write_text(now())
                        until = time.monotonic() + 20
                        while not release.exists() and time.monotonic() < until:
                            time.sleep(.05)
                send(response)

        def log(event):
            with trace.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps({"at": now(), **event}) + "\n")

        worker = threading.Thread(target=responses, daemon=True)
        worker.start()
        try:
            for line in sys.stdin:
                message = json.loads(line)
                method = message.get("method")
                params = message.get("params", {})
                tool = params.get("name") if method == "tools/call" else None
                phase = params.get("arguments", {}).get("phase") if tool == "update_session_activity" else None
                if method == "tools/call":
                    log({"event": "call", "tool": tool, "phase": phase})
                if (tool and tool not in names) or (
                    method not in {"initialize", "ping", "tools/list", "tools/call", "notifications/initialized",
                                   "notifications/cancelled"}
                ):
                    if "id" in message:
                        send({"jsonrpc": "2.0", "id": message["id"],
                              "error": {"code": -32601, "message": "Method outside the fixture allowlist"}})
                    continue
                if "id" in message:
                    requests[message["id"]] = (method, tool, phase)
                child.stdin.write(line)
                child.stdin.flush()
        finally:
            child.stdin.close()
            worker.join(timeout=5)
            if child.poll() is None:
                child.terminate()


def isolate():
    home = Path.home()
    codex = Path(os.environ.get("CODEX_HOME", home / ".codex"))
    groups = [
        ("subpath", [home / ".agents", codex / "skills", home / ".claude" / "skills"]),
        ("literal", [codex / "AGENTS.md", codex / "AGENTS.override.md", home / "AGENTS.md"]),
    ]
    rules = " ".join(f"({kind} {json.dumps(str(path.resolve()))})" for kind, paths in groups for path in paths)
    return "(version 1) (allow default) (deny file-read* " + rules + ")"


def run_client(binary, home, role, prompt, output, label=None, release=None, observer=False):
    output.mkdir(mode=0o700)
    tools = {"team_standup"} if observer else READS | (ACTIVITY if label else set())
    relay = [str(Path(__file__).resolve()), "--bridge", binary, str(home), ",".join(sorted(tools)),
             str(output / "tools.jsonl")]
    if label:
        relay += [str(output / "running"), str(release)]
        prompt = (
            f"On my explicit request, publish this synthetic session as \"{label}\" with report_activity true. "
            "Use its private receiver key to report your actual phase as running with a short task summary before working. "
            "After completing the evidence task, report completed with a brief factual summary. Never include the receiver key "
            "in your response. Then return the requested output.\n\n" + prompt
        )
    config = {
        "developer_instructions": INSTRUCTION,
        "model_reasoning_effort": "medium",
        "project_doc_max_bytes": 0,
        "web_search": "disabled",
        "mcp_servers.hereforth.command": sys.executable,
        "mcp_servers.hereforth.args": relay,
        "mcp_servers.hereforth.enabled_tools": sorted(tools),
        "mcp_servers.hereforth.required": True,
        "mcp_servers.hereforth.tool_timeout_sec": 50,
    }
    disabled = ["shell_tool", "apps", "plugins", "skill_search", "skill_mcp_dependency_install",
                "shell_snapshot", "memories", "multi_agent", "multi_agent_v2"]
    command = ["/usr/bin/sandbox-exec", "-p", isolate(), "codex", "--ask-for-approval", "never", "exec",
               "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
               "--sandbox", "read-only", "--enable", "skip_host_skill_discovery", "--enable",
               "omit_skill_descriptions", "--model", "gpt-6.2-sol"]
    command += [part for name in disabled for part in ("--disable", name)]
    command += [part for key, value in config.items() for part in ("-c", f"{key}={json.dumps(value)}")]
    command += [prompt]
    began = now()
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="hereforth-teammate-cwd-") as cwd:
        result = subprocess.run(command, cwd=cwd, env=env_for(), stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=180)
    (output / "events.jsonl").write_text(RECEIVER_KEY.sub("[receiver key]", result.stdout))
    (output / "stderr.log").write_text(RECEIVER_KEY.sub("[receiver key]", result.stderr))
    events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    answers = [event["item"].get("text", "") for event in events if event.get("type") == "item.completed"
               and event.get("item", {}).get("type") == "agent_message"]
    answer = RECEIVER_KEY.sub("[receiver key]", answers[-1]) if answers else ""
    summary = {"role": role, "model": "gpt-6.2-sol", "effort": "medium", "start_at": began,
               "end_at": now(), "wall_seconds": round(time.monotonic() - start, 3),
               "exit_status": result.returncode, "answer": answer,
               "usage": next((e["usage"] for e in events if e.get("type") == "turn.completed"), {})}
    (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    if not observer:
        try:
            payload = json.loads(answer)
        except json.JSONDecodeError:
            block = re.search(r"```(?:json)?\s*([\s\S]+?)```", answer)
            if not block:
                raise
            payload = json.loads(block.group(1))
        (output / "result.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ready", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--correction", nargs=2, metavar=("ROLE", "PROMPT_FILE"))
    parser.add_argument("--observer", action="store_true")
    args = parser.parse_args()
    ready = json.loads(args.ready.read_text())
    binary = str(Path(ready["helper"]).resolve())
    roles = ready["roles"]
    fold = lambda record: Path(record["home"] if isinstance(record, dict) else record).resolve()
    homes = {role: fold(roles[role]) for role in ROLES}
    homes["observer"] = fold(ready["observer"])
    fixture = args.ready.resolve().parent
    if any(fixture not in home.parents or not (home / "hereforth.sqlite").is_file() for home in homes.values()):
        parser.error("Use the live synthetic three-teammate fixture.")
    args.output.mkdir(mode=0o700)
    if args.observer:
        result = run_client(binary, homes["observer"], "observer",
                   "Use Hereforth to read Ryan, Priya, and Sam’s latest shared standups. Which pilot accounts cleared "
                   "the release checks, what did billing reconcile, and is the vendor cleared or still awaiting review? "
                   "Explain what can proceed versus outstanding dependencies, and attribute each to its shared update "
                   "with thread and timestamp. Distinguish eligibility from deployment.",
                   args.output / "observer", observer=True)
        return int(result["exit_status"] != 0 or not result["answer"])
    if args.correction:
        role, path = args.correction
        if role not in ROLES:
            parser.error("Unknown correction role.")
        result = run_client(binary, homes[role], role, roles[role]["prompt"] + "\n\n" + Path(path).read_text(),
                            args.output / role)
        return int(result["exit_status"] != 0 or not result["answer"] or
                   not (args.output / role / "result.json").is_file())
    labels = {role: f"Codex {role} fixture task" for role in ROLES}
    release = args.output / "release"
    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(run_client, binary, homes[role], role, roles[role]["prompt"],
                               args.output / role, labels[role], release) for role in ROLES]
        try:
            first_seen = None
            deadline = time.monotonic() + 50
            running = {role: args.output / role / "running" for role in ROLES}
            while time.monotonic() < deadline:
                seen = [path.exists() for path in running.values()]
                if all(seen):
                    sample = observe(binary, homes, labels)
                    sample["arrivals"] = {role: path.read_text() for role, path in running.items()}
                    sample["overlap_ms_at_sample_minimum"] = round(
                        (datetime.fromisoformat(sample["observed_at"]) -
                         max(datetime.fromisoformat(value) for value in sample["arrivals"].values())).total_seconds()
                        * 1000)
                    (args.output / "barrier.json").write_text(json.dumps(sample, indent=2) + "\n")
                    break
                if any(future.done() for future in futures):
                    break
                if any(seen):
                    first_seen = first_seen or time.monotonic()
                    if time.monotonic() - first_seen > 16:
                        break
                time.sleep(.05)
        finally:
            release.touch()
        passed = (args.output / "barrier.json").is_file()
        for role, future in zip(ROLES, futures):
            value = future.result()
            print(json.dumps({key: item for key, item in value.items() if key != "answer"}))
            passed &= value["exit_status"] == 0 and bool(value["answer"]) and (args.output / role / "result.json").is_file()
        if not passed:
            print("A client result or the simultaneous session snapshot is missing.", file=sys.stderr)
        return int(not passed)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--bridge":
        _, _, helper, home, names, trace, *barrier = sys.argv
        bridge(helper, home, set(names.split(",")), Path(trace), *(Path(path) for path in barrier))
    else:
        raise SystemExit(main())
