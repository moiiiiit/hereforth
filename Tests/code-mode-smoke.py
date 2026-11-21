"""Run with python3 Tests/code-mode-smoke.py .build/debug/hereforth."""
import contextlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile


@contextlib.contextmanager
def server(binary, env, *options):
    with subprocess.Popen([binary, "mcp", *options], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, env=env) as process:
        identifier = 0

        def request(method, params=None):
            nonlocal identifier
            identifier += 1
            frame = {"jsonrpc": "2.0", "id": identifier, "method": method}
            if params is not None:
                frame["params"] = params
            process.stdin.write(json.dumps(frame).encode() + b"\n")
            process.stdin.flush()
            ready, _, _ = select.select([process.stdout], [], [], 18)
            assert ready, f"No MCP response for {method}"
            response = json.loads(process.stdout.readline())
            assert response["jsonrpc"] == "2.0" and response["id"] == identifier
            return response

        initialized = request("initialize", {"protocolVersion": "2025-11-25"})
        assert initialized["result"]["protocolVersion"] == "2025-11-25"

        def call(name, **arguments):
            return request("tools/call", {"name": name, "arguments": arguments})

        def no_worker():
            children = subprocess.run(["/usr/bin/pgrep", "-P", str(process.pid)], capture_output=True, timeout=4)
            assert children.returncode == 1 and not children.stdout, "An isolated worker was left running"

        try:
            yield request, call, no_worker
            process.stdin.close()
            assert process.wait(timeout=5) == 0
        finally:
            if process.poll() is None:
                process.kill()


def main(binary):
    with tempfile.TemporaryDirectory(prefix="hereforth-code-mode-") as directory:
        root = Path(directory)
        env = {**os.environ, "HEREFORTH_HOME": str(root / "library"), "HEREFORTH_CODE_TEST_SECRET": "synthetic secret"}
        export = root / "Studio.txt"
        export.write_text("The studio decided to open the workshop twice a week.\n\nAn earlier note only proposed one event.",
                          encoding="utf-8")
        subprocess.run([binary, "import", export], env=env, check=True, capture_output=True, timeout=10)
        with server(binary, env) as (request, call, _):
            tools = request("tools/list")["result"]["tools"]
            assert "query_context" not in {tool["name"] for tool in tools}
            assert request("tools/call", {"name": "query_context", "arguments": {"code": "return 1;"}})["error"]["code"] == -32602
            hits = call("search_decisions", query="workshop")["result"]["structuredContent"]["hits"]
            assert len(hits) > 0
            source = call("read_passage", citation=hits[0]["citation"])["result"]["structuredContent"]
            empty_team = call("team_standup")["result"]["structuredContent"]

        with server(binary, env, "--code-mode") as (request, call, no_worker):
            tools = request("tools/list")["result"]["tools"]
            assert [tool["name"] for tool in tools] == ["query_context"]
            assert tools[0]["annotations"]["readOnlyHint"]
            assert call("search_decisions", query="workshop")["error"]["code"] == -32602
            assert call("prepare_handoff")["error"]["code"] == -32602
            assert call("query_context", code="return 1;", another_field=True)["error"]["code"] == -32602

            def query(code):
                return call("query_context", code=code)["result"]

            script = """
                const { hits } = search_decisions({query: "workshop"});
                const selected = hits.filter(hit => hit.excerpt.includes("twice")).slice(0, 1);
                const passages = selected.map(hit => read_passage({citation: hit.citation, offset: 0}));
                return {passages, team: team_standup({})};
                """
            result = query(script)
            expected = {"result": {"passages": [source], "team": empty_team}}
            assert result["structuredContent"] == expected
            assert json.loads(result["content"][0]["text"]) == expected
            no_worker()

            globals_test = query("""
                return [typeof process, typeof require, typeof fetch, typeof FileHandle,
                        typeof globalThis.__hereforthBroker, typeof HEREFORTH_CODE_TEST_SECRET];
                """)
            assert globals_test["structuredContent"] == {"result": ["undefined"] * 6}

            for code in ("return prepare_handoff({});", "let x = 1;", "return \"0\".repeat(30000);", " " * 4096 + "return 1;"):
                assert query(code)["isError"]
                no_worker()
            typo = query("return (;")
            assert typo["isError"] and "SyntaxError" in typo["content"][0]["text"]

            for code in ("while (true) {}", "for (let i = 0; i < 7; i++) search_decisions({query: \"studio\"}); return 0;",
                         "team_standup({}); team_standup({}); return 0;", 'return "/".repeat(14000);',
                         "const held = []; for (let i = 0; i < 200; i++) held.push(new Uint8Array(1048576).fill(1)); return held.length;"):
                stopped = query(code)
                assert stopped["isError"] and stopped["structuredContent"]["error"]["code"] == "execution_limit"
                no_worker()
                assert query("return 42;")["structuredContent"] == {"result": 42}
                no_worker()
    print("Code Mode smoke passed: isolated composable reads, scoped tools, limits, and recovery.")


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
