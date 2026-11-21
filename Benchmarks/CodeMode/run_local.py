"""Use a loopback llama-server and an isolated Juniper fixture with the real MCP helper."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import select
import subprocess
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

PROMPT = "What did we decide about Juniper this week, and which decisions are missing from Ryan’s latest shared update?"
SYSTEM = "Use Hereforth evidence and cite sources."
READS = {"search_decisions", "team_standup", "read_passage"}
WRITING_SUFFIX = (" Before composing Hereforth prose, apply embedded Humanizer using get_writing_guide."
                  " Request include_full_skill once when the native skill is unavailable. Preserve verbatim content.")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


http = build_opener(ProxyHandler({}), NoRedirect())


def redact(text, root):
    text = re.sub(r"<think>.*?(?:</think>|$)", "", text, flags=re.S | re.I)
    text = text.replace(str(root), "[fixture]")
    text = re.sub(r"(?:/Users/|/private/var/folders/)\S+", "[redacted-path]", text)
    return re.sub(r"(?<!hf:)\b[a-f0-9]{64}\b", "[redacted-key]", text, flags=re.I).strip()


@contextlib.contextmanager
def mcp(binary, fixture_home, mode):
    command = [str(binary), "mcp"] + (["--code-mode"] if mode == "code" else [])
    env = {**os.environ, "HEREFORTH_HOME": str(fixture_home)}
    process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    sequence = 0

    def write(message):
        process.stdin.write(json.dumps(message, ensure_ascii=False).encode() + b"\n")
        process.stdin.flush()

    def request(method, params=None):
        nonlocal sequence
        sequence += 1
        write({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params or {}})
        if not select.select([process.stdout], [], [], 20)[0]:
            raise RuntimeError(f"MCP {method} timed out")
        line = process.stdout.readline()
        if not line:
            raise RuntimeError("MCP helper stopped before replying")
        response = json.loads(line)
        if response.get("id") != sequence:
            raise RuntimeError("MCP reply did not match the request")
        return response

    try:
        reply = request("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "juniper-local-benchmark", "version": "1"}
        })
        if "result" not in reply:
            raise RuntimeError("MCP initialization failed")
        write({"jsonrpc": "2.0", "method": "notifications/initialized"})
        listed = request("tools/list").get("result", {}).get("tools", [])
        allowed = {"query_context"} if mode == "code" else READS
        tools = [{"type": "function", "function": {
            "name": tool["name"], "description": tool["description"].removesuffix(WRITING_SUFFIX),
            "parameters": tool["inputSchema"]
        }} for tool in listed if tool.get("name") in allowed]
        if {tool["function"]["name"] for tool in tools} != allowed:
            raise RuntimeError(f"MCP helper does not expose the expected {mode} tools")
        yield request, tools, allowed
    finally:
        if process.stdin:
            process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        if process.stdout:
            process.stdout.close()


def model_call(endpoint, options, messages, tools):
    body = {"model": options.model, "messages": messages, "tools": tools, "tool_choice": "auto",
            "stream": False, "temperature": 0, "seed": options.seed, "max_tokens": options.max_tokens,
            "cache_prompt": False}
    request = Request(endpoint, data=json.dumps(body, ensure_ascii=False).encode(),
                      headers={"Content-Type": "application/json", "Accept": "application/json"}, method="POST")
    try:
        with http.open(request, timeout=options.timeout) as response:
            return json.load(response)
    except HTTPError as error:
        raise RuntimeError(f"Local model returned HTTP {error.code}") from None
    except (TimeoutError, URLError):
        raise RuntimeError("Could not complete the loopback model request") from None


def run(options):
    messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": PROMPT}]
    start = time.perf_counter()
    stats = []
    answer = ""
    status = "round_limit"
    with mcp(options.binary, options.home, options.mode) as (request, tools, allowed):
        for index in range(1, options.max_rounds + 1):
            sent = time.perf_counter()
            result = model_call(options.endpoint, options, messages, tools)
            elapsed = time.perf_counter() - sent
            choice = result["choices"][0]
            assistant = choice["message"]
            content = assistant.get("content") or ""
            if not isinstance(content, str):
                raise RuntimeError("Local model returned an unsupported content format")
            calls = assistant.get("tool_calls") or []
            usage = result.get("usage") or {}
            details = usage.get("prompt_tokens_details") or {}
            timings = result.get("timings") or {}
            row = {"round": index, "model_seconds": round(elapsed, 3), "prompt_tokens": usage.get("prompt_tokens"),
                   "completion_tokens": usage.get("completion_tokens"), "finish_reason": choice.get("finish_reason"),
                   "cached_prompt_tokens": details.get("cached_tokens"), "runtime_cache_n": timings.get("cache_n"),
                   "tools": [], "tool_result_bytes": 0}
            stats.append(row)
            if not calls:
                answer = redact(content, options.home.parent)
                status = "answered" if answer and choice.get("finish_reason") == "stop" else "incomplete"
                break
            messages.append({"role": "assistant", "content": content or None, "tool_calls": calls})
            for call_index, call in enumerate(calls):
                function = call.get("function", {})
                name = function.get("name")
                permitted = isinstance(name, str) and name in allowed
                if not call.get("id"):
                    call["id"] = f"call_{index}_{call_index}"
                try:
                    arguments = function.get("arguments", {})
                    if isinstance(arguments, str):
                        arguments = json.loads(arguments)
                    if not isinstance(arguments, dict) or not permitted:
                        raise ValueError()
                    response = request("tools/call", {"name": name, "arguments": arguments})
                    if "error" in response:
                        evidence = {"error": response["error"].get("message", "Invalid tool request")}
                        failed = True
                    else:
                        result = response["result"]
                        evidence = result.get("structuredContent", result.get("content", []))
                        failed = bool(result.get("isError"))
                except (TypeError, ValueError):
                    evidence = {"error": "Use an available read-only tool with a JSON object."}
                    failed = True
                serialized = json.dumps(evidence, ensure_ascii=False, separators=(",", ":"))
                messages.append({"role": "tool", "tool_call_id": call["id"], "content": serialized})
                row["tools"].append({"name": name if permitted else "[unavailable]", "error": failed})
                row["tool_result_bytes"] += len(serialized.encode())
    totals = {}
    for field in ("prompt_tokens", "completion_tokens", "cached_prompt_tokens", "runtime_cache_n"):
        values = [row[field] for row in stats]
        totals[field] = sum(values) if all(isinstance(value, int) for value in values) else None
    return {"mode": options.mode, "model": redact(options.model, options.home.parent),
            "prompt": PROMPT, "system": SYSTEM, "status": status,
            "wall_seconds": round(time.perf_counter() - start, 3), "total": totals, "rounds": stats,
            "answer": answer, "temperature": 0, "seed": options.seed,
            "cache_prompt": False, "max_tokens_per_round": options.max_tokens}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--home", type=Path, required=True, help="The isolated owner directory made by the fixture script.")
    parser.add_argument("--endpoint", default="http://127.0.0.1:8080/v1/chat/completions")
    parser.add_argument("--model", required=True, help="Model alias served by llama-server.")
    parser.add_argument("--mode", choices=("normal", "code"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--max-rounds", type=int, default=8)
    parser.add_argument("--max-tokens", type=int, default=4096)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    args.binary = args.binary.resolve(strict=True)
    args.home = args.home.resolve(strict=True)
    endpoint = urlsplit(args.endpoint)
    if (endpoint.hostname not in {"127.0.0.1", "::1"} or endpoint.scheme != "http"
            or endpoint.username is not None or endpoint.query or endpoint.fragment
            or endpoint.path != "/v1/chat/completions"):
        parser.error("Use the loopback llama-server /v1/chat/completions endpoint.")
    if args.home.name != "owner" or not (args.home / "hereforth.sqlite").is_file() or not (args.home.parent / "rubric.json").is_file():
        parser.error("Use the isolated owner directory created by the Juniper fixture.")
    if not 1 <= args.max_rounds <= 16 or not 64 <= args.max_tokens <= 32_768 or not 1 <= args.timeout <= 600:
        parser.error("Use 1–16 rounds, 64–32,768 max tokens, and a timeout of 1–600 seconds.")
    result = run(args)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{result['mode']} {result['status']} · {len(result['rounds'])} rounds · {result['wall_seconds']} seconds")


if __name__ == "__main__":
    main()
