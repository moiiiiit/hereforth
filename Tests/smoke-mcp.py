"""Run with python3 Tests/smoke-mcp.py .build/debug/hereforth."""
import contextlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import select
import sqlite3
import subprocess
import sys
import tempfile


@contextlib.contextmanager
def server(binary, env):
    with subprocess.Popen(
        [binary, "mcp"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    ) as process:
        request_id = 0

        def send(message, expect_response=True):
            line = json.dumps(message).encode() if isinstance(message, dict) else message
            process.stdin.write(line + b"\n")
            process.stdin.flush()
            if expect_response:
                ready, _, _ = select.select([process.stdout], [], [], 5)
                assert ready, f"No MCP response for {message}"
                return json.loads(process.stdout.readline())

        def request(method, params=None):
            nonlocal request_id
            request_id += 1
            message = {"jsonrpc": "2.0", "id": request_id, "method": method}
            if params is not None:
                message["params"] = params
            response = send(message)
            assert response["jsonrpc"] == "2.0" and response["id"] == request_id, response
            return response

        def initialize(version):
            result = request("initialize", {
                "protocolVersion": version, "capabilities": {},
                "clientInfo": {"name": "synthetic-smoke-test", "version": "1"},
            })["result"]
            send({"jsonrpc": "2.0", "method": "notifications/initialized"}, False)
            return result["protocolVersion"]

        def call(name, **arguments):
            return request("tools/call", {"name": name, "arguments": arguments})["result"]

        try:
            yield send, request, initialize, call
            process.stdin.close()
            assert process.wait(timeout=5) == 0
        finally:
            if process.poll() is None:
                process.kill()


def main(binary):
    with tempfile.TemporaryDirectory(prefix="hereforth-smoke-") as temp:
        root = Path(temp)
        owner = root / "owner"
        recipient = root / "recipient"
        recipient.mkdir()
        env = {**os.environ, "HEREFORTH_HOME": str(owner)}
        chatgpt = root / "chatgpt.json"
        claude = root / "claude.json"
        decision = "The Glacier pilot will switch to batched uploads on Tuesday."
        proposal = "Earlier proposal: keep individual uploads during the pilot."
        caveat = "Glacier batches must preserve the order expected by the billing system."
        notes = "\n\n" + "z" * 8_000 + "End of source."
        chatgpt.write_text(json.dumps([{
            "id": "synthetic-glacier-decision", "title": "Glacier planning",
            "current_node": "message", "mapping": {"message": {
                "parent": "proposal", "message": {
                    "id": "message", "author": {"role": "assistant"}, "create_time": 1_700_000_000,
                    "content": {"content_type": "text", "parts": [decision]},
                },
            }, "proposal": {
                "parent": None, "message": {
                    "id": "proposal", "author": {"role": "user"}, "create_time": 1_699_990_000,
                    "content": {"content_type": "text", "parts": [proposal]},
                },
            }},
        }]), encoding="utf-8")
        claude.write_text(json.dumps([{
            "uuid": "synthetic-glacier-caveat", "name": "Glacier billing",
            "chat_messages": [{
                "uuid": "message", "sender": "human", "created_at": "2025-06-04T10:30:00Z",
                "content": [{"type": "text", "text": caveat + notes}],
            }],
        }]), encoding="utf-8")
        imported = subprocess.run([binary, "import", chatgpt, claude], env=env, capture_output=True, timeout=10)
        assert imported.returncode == 0, imported.stderr.decode()
        assert imported.stdout.count(b"imported 1 conversation(s)") == 2
        voice_notes = "Prefer contractions and short paragraphs.\nStyle-only fixture: ‘Schedule a meeting.’\n"
        subprocess.run([binary, "voice", "set"], input=voice_notes, text=True, env=env,
                       capture_output=True, check=True, timeout=10)

        with server(binary, env) as (send, request, _, call):
            assert send(b"{invalid")["error"]["code"] == -32700
            assert request("ping")["result"] == {}
            assert request("tools/list")["error"]["code"] == -32002
            initialized = request("initialize", {
                "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "synthetic-smoke-test", "version": "1"},
            })["result"]
            assert initialized["protocolVersion"] == "2025-11-25"
            assert "Humanizer" in initialized["instructions"] and "get_writing_guide" in initialized["instructions"]
            send({"jsonrpc": "2.0", "method": "notifications/initialized"}, False)
            tools = request("tools/list")["result"]["tools"]
            assert {tool["name"] for tool in tools} == {
                "list_conversations", "search_decisions", "read_passage", "prepare_handoff", "get_handoffs",
                "publish_current_session", "unpublish_current_session", "list_peer_sessions",
                "offer_session_context", "read_session_context", "get_context_status", "list_context_requests",
                "submit_work_request", "get_work_request", "read_granted_brief", "list_work_requests",
                "request_standup_access", "list_standup_threads", "read_standup_thread", "reply_to_standup", "read_weekly_context",
                "get_writing_guide",
            }
            descriptions = {tool["name"]: tool["description"] for tool in tools}
            for tool in ("prepare_handoff", "offer_session_context", "submit_work_request",
                         "request_standup_access", "reply_to_standup", "read_standup_thread", "read_weekly_context"):
                assert "Humanizer" in descriptions[tool] and "get_writing_guide" in descriptions[tool]
            guide = call("get_writing_guide")["structuredContent"]
            assert guide["voice_notes"] == voice_notes and "style samples only" in guide["voice_notes_handling"]
            assert set(guide["mode_rules"]) == {"embedded", "standup", "answer", "handoff", "offer", "work_request", "reply"}
            assert "quotes, code, citations, approved text, and receipts exact" in guide["policy"]
            assert "humanizer_skill" not in guide
            full_guide = call("get_writing_guide", include_full_skill=True)["structuredContent"]
            assert full_guide["full_skill_available"] and full_guide["humanizer_skill"].startswith("---\nname: humanizer")
            assert "## Rewrite process" in full_guide["humanizer_skill"] and "**Embedded mode.**" in full_guide["humanizer_skill"]
            assert len(full_guide["humanizer_skill"]) > 20_000
            assert request("tools/call", {"name": "get_writing_guide", "arguments": {"include_full_skill": 1}})["error"]["code"] == -32602
            conversations = call("list_conversations")["structuredContent"]["conversations"]
            assert all(set(chat) == {"id", "title", "provider", "passage_count"} for chat in conversations)
            assert {(chat["title"], chat["provider"], chat["passage_count"]) for chat in conversations} == {
                ("Glacier planning", "ChatGPT", 2), ("Glacier billing", "Claude", 1),
            }
            assert request("not/a/method")["error"]["code"] == -32601
            assert request("tools/call", {"name": "read_passage", "arguments": {
                "citation": "hf:bad", "offset": True,
            }})["error"]["code"] == -32602
            assert call("read_passage", citation="/etc/hosts")["isError"]

            search = call("search_decisions", query="Glacier")
            hits = search["structuredContent"]["hits"]
            assert json.loads(search["content"][0]["text"])["hits"] == hits
            assert {hit["provider"] for hit in hits} == {"ChatGPT", "Claude"}, hits
            all_citations = {hit["citation"] for hit in hits}
            sources = {hit["provider"]: hit["citation"] for hit in hits if proposal not in hit["excerpt"]}
            chatgpt_passage = call("read_passage", citation=sources["ChatGPT"])["content"][0]["text"]
            assert decision in chatgpt_passage and proposal in chatgpt_passage
            first_page = call("read_passage", citation=sources["Claude"])["content"][0]["text"]
            assert caveat in first_page and first_page.endswith("Next offset: 8000")
            final_page = call("read_passage", citation=sources["Claude"], offset=8000)
            assert final_page["structuredContent"]["passage"].endswith("End of source.")

            fields = dict(
                recipient="Casey", title="Glacier pilot handoff", decision=decision,
                background=caveat, next_step="Verify ordered batches before the pilot opens.",
            )
            assert call("prepare_handoff", **fields, citations=["hf:bad"])["isError"]
            handoff = call("prepare_handoff", **fields, citations=list(sources.values()))
            preview = handoff["structuredContent"]
            assert preview == json.loads(handoff["content"][0]["text"])
            assert preview["draft_id"] and preview["recipient"] == "Casey"
            assert voice_notes not in preview["markdown"]
            assert "Handoffs" in preview["instructions"] and "paired session" in preview["instructions"]
            assert "Glacier planning" in preview["markdown"] and "Glacier billing" in preview["markdown"]

        for version in ("2024-11-05", "2025-03-26", "2025-06-18", "unknown"):
            with server(binary, env) as (_, _, initialize, call):
                assert initialize(version) == (version if version != "unknown" else "2025-11-25")
                result = call("search_decisions", query="Glacier")
                assert {hit["citation"] for hit in json.loads(result["content"][0]["text"])["hits"]} == all_citations
                assert ("structuredContent" in result) == (version in ("2025-06-18", "unknown"))

        with contextlib.closing(sqlite3.connect(owner / "hereforth.sqlite")) as library:
            assert library.execute("SELECT id, markdown FROM briefs").fetchall() == [
                (preview["draft_id"], preview["markdown"]),
            ]
            reviewed = preview["markdown"].replace(caveat, "[Removed in review.]")
            library.execute("UPDATE briefs SET markdown = ? WHERE id = ?", (reviewed, preview["draft_id"]))
            library.commit()

        with server(binary, env) as (_, _, initialize, call):
            initialize("2025-11-25")
            assert call("get_handoffs")["structuredContent"]["handoffs"] == [
                {key: preview[key] for key in ("draft_id", "title", "recipient")},
            ]
            assert call("get_handoffs", offset=1)["structuredContent"] == {"handoffs": []}
            recovered = call("get_handoffs", draft_id=preview["draft_id"])["structuredContent"]
            assert recovered["markdown"] == reviewed and caveat not in recovered["markdown"]
            assert call("get_handoffs", draft_id="/etc/hosts")["isError"]
            assert call("get_handoffs", draft_id="00000000-0000-0000-0000-000000000000")["isError"]

        markdown = recipient / "handoff.md"
        markdown.write_text(preview["markdown"], encoding="utf-8")
        # The recipient's library is independent. The file alone carries the selected quotes.
        with server(binary, {**env, "HEREFORTH_HOME": str(recipient / "library")}) as (_, _, initialize, call):
            initialize("2025-11-25")
            assert call("read_passage", citation=sources["ChatGPT"])["isError"]
            assert call("list_conversations")["structuredContent"]["conversations"] == []
            assert call("get_handoffs")["structuredContent"]["handoffs"] == []
            assert call("get_handoffs", draft_id=preview["draft_id"])["isError"]
            assert call("get_writing_guide")["structuredContent"]["voice_notes"] == ""
            text = markdown.read_text(encoding="utf-8")
            assert f"> {decision}" in text and f"> {caveat}" in text and fields["next_step"] in text
            assert all(citation in text for citation in sources.values())

        archive = root / "archive.json"
        archive.write_text(json.dumps([
            {"uuid": f"filler-{index}", "name": f"Filler chat {index:02}", "chat_messages": []}
            for index in range(49)
        ]), encoding="utf-8")
        subprocess.run([binary, "import", archive], env=env, capture_output=True, check=True, timeout=10)
        with server(binary, env) as (_, _, initialize, call):
            initialize("2025-11-25")
            first = call("list_conversations")["structuredContent"]
            second = call("list_conversations", offset=first["next_offset"])["structuredContent"]
            assert len(first["conversations"]) == first["next_offset"] == 50
            assert len(second["conversations"]) == 1 and "next_offset" not in second
            assert second["conversations"][0]["title"] == "Glacier planning"

        current = root / "this-week.json"
        weekly_text = "This week: verified the pilot checklist."
        current.write_text(json.dumps([{
            "uuid": "synthetic-current-week", "name": "Weekly synthetic evidence", "chat_messages": [{
                "uuid": "message", "sender": "human", "created_at": datetime.now(timezone.utc).isoformat(),
                "content": [{"type": "text", "text": weekly_text}],
            }],
        }]), encoding="utf-8")
        subprocess.run([binary, "import", current], env=env, capture_output=True, check=True, timeout=10)
        with server(binary, env) as (_, _, initialize, call):
            initialize("2025-11-25")
            inventory = call("read_weekly_context")["structuredContent"]
            weekly_chats = inventory["entries"]
            assert [chat["title"] for chat in weekly_chats] == ["Weekly synthetic evidence"]
            evidence = call("read_weekly_context", mode="evidence", chat_id=weekly_chats[0]["id"])["structuredContent"]
            assert evidence["weekStart"] == inventory["weekStart"]
            assert [entry["excerpt"] for entry in evidence["entries"]] == [weekly_text]

    print("MCP smoke test passed.")


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
