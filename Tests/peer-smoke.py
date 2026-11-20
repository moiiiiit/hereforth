"""Run with python3 Tests/peer-smoke.py .build/debug/hereforth."""
import contextlib
import hashlib
import http.server
import os
from pathlib import Path
import runpy
import select
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import uuid

server = runpy.run_path(str(Path(__file__).with_name("smoke-mcp.py")))["server"]


def command(binary, env, *arguments, input=None):
    result = subprocess.run([binary, *arguments], input=input, env=env, capture_output=True, timeout=5)
    assert result.returncode == 0, result.stderr.decode()
    return result.stdout


@contextlib.contextmanager
def listener(binary, env):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    with subprocess.Popen([binary, "peer", "serve", str(port)], stderr=subprocess.PIPE, env=env) as process:
        try:
            ready, _, _ = select.select([process.stderr], [], [], 5)
            assert ready and b"listening on 127.0.0.1" in process.stderr.readline()
            endpoints = subprocess.check_output(
                ["/usr/sbin/lsof", "-nP", "-a", "-p", str(process.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
                text=True, timeout=5,
            )
            assert [line[1:] for line in endpoints.splitlines() if line.startswith("n")] == [f"127.0.0.1:{port}"]
            yield f"http://127.0.0.1:{port}"
        finally:
            process.terminate()
            process.wait(timeout=5)


def check_redirect(binary, env, token):
    paths = []

    class Redirect(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            paths.append(self.path)
            self.send_response(302 if self.path == "/v1/sessions" else 200)
            self.send_header("Location", "/would-leak-token")
            self.end_headers()

        def log_message(self, *_):
            pass

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Redirect) as test_server:
        serving = threading.Thread(target=test_server.serve_forever)
        serving.start()
        try:
            command(binary, env, "peer", "add", "Redirect", f"http://127.0.0.1:{test_server.server_port}", input=token)
            with server(binary, env) as (_, _, initialize, call):
                initialize("2025-11-25")
                assert call("list_peer_sessions", peer="Redirect")["isError"]
            assert paths == ["/v1/sessions"]
        finally:
            test_server.shutdown()
            serving.join()


def owner_harness(root):
    # Build the same local Store operations the native review UI calls, without exposing an approval CLI in the app.
    source = root / "main.swift"
    source.write_text('''import Foundation

let store = try Store()
let args = CommandLine.arguments
switch args[1] {
case "create":
    _ = try store.importFile(URL(fileURLWithPath: args[2]))
    let hit = try store.search("Glacier").first!
    let brief = try store.draft(recipient: "Avery", title: "Glacier pilot", decision: "Proceed with the pilot", background: "Synthetic fixture", nextStep: "Confirm checklist", citations: [hit.citation])
    print(brief.id)
case "update":
    try store.updateBrief(args[2], markdown: args[3])
case "grant":
    let preview = try store.previewWorkRequest(id: args[2], briefID: args[3])
    _ = try store.reviewWorkRequest(id: args[2], approve: true, briefID: preview.briefID, digest: preview.digest)
case "review":
    _ = try store.reviewWorkRequest(id: args[2], approve: true)
case "revoke":
    try store.revokeWorkRequest(id: args[2])
default:
    exit(2)
}
''', encoding="utf-8")
    repo = Path(__file__).resolve().parent.parent
    executable = root / "synthetic-owner-review"
    subprocess.run([
        "swiftc", "-I", repo / "Sources/CSQLite", *sorted((repo / "Sources/HereforthCore").glob("*.swift")),
        source, "-o", executable,
    ], capture_output=True, timeout=60, check=True)
    return executable


def check_durable(binary, receiver, root, send):
    fixture = root / "glacier.md"
    fixture.write_text("The Glacier project will pilot batched intake.\n", encoding="utf-8")
    owner = owner_harness(root)
    brief_id = command(owner, receiver, "create", fixture).decode().strip()
    reviewed = "# Glacier pilot\n\nReviewed brief with the private source removed.\n"
    command(owner, receiver, "update", brief_id, reviewed)
    text = "Please grant read access to the Glacier pilot brief so I can check the intake instructions."
    filed = dict(peer="Morgan", request_id=str(uuid.uuid4()), body=text, requests_brief=True)
    receipt = send("submit_work_request", **filed)["structuredContent"]
    assert receipt["state"] == "submitted_for_review" and uuid.UUID(receipt["id"])
    assert send("submit_work_request", **filed)["structuredContent"] == receipt
    assert send("submit_work_request", **{**filed, "body": "A different request"})["isError"]
    lookup = {key: filed[key] for key in ("peer", "request_id")}
    wrong_sender = {**lookup, "peer": "Morgan other sender"}
    unknown = {**lookup, "request_id": str(uuid.uuid4())}
    assert send("get_work_request", **lookup)["structuredContent"]["state"] == "pending"
    for query in (lookup, wrong_sender, unknown):
        assert send("read_granted_brief", **query)["structuredContent"] == {"available": False}
    for query in (wrong_sender, unknown):
        assert send("get_work_request", **query)["structuredContent"] == {"state": "unknown"}

    warehouse = dict(peer="Morgan", request_id=str(uuid.uuid4()), category="data_access", body="Request read access to the external warehouse.")
    recorded = send("submit_work_request", **warehouse)["structuredContent"]
    command(owner, receiver, "review", recorded["id"])
    warehouse_lookup = {key: warehouse[key] for key in ("peer", "request_id")}
    assert send("get_work_request", **warehouse_lookup)["structuredContent"]["state"] == "reviewed"
    assert send("read_granted_brief", **warehouse_lookup)["structuredContent"] == {"available": False}

    future = dict(peer="Morgan", request_id=str(uuid.uuid4()), body="A general workplace question.")
    general = send("submit_work_request", **future)["structuredContent"]
    with server(binary, receiver) as (_, _, initialize, receive):
        initialize("2025-11-25")
        assert receive("list_work_requests")["structuredContent"]["requests"] == [
            {"id": general["id"], "sender": "Avery IT", "category": "other", "state": "pending"},
            {"id": recorded["id"], "sender": "Avery IT", "category": "data_access", "state": "reviewed"},
            {"id": receipt["id"], "sender": "Avery IT", "category": "data_access", "state": "pending"},
        ]

    command(owner, receiver, "grant", receipt["id"], brief_id)
    command(owner, receiver, "update", brief_id, "# Internal changes after grant\n")
    delivered = send("get_work_request", **lookup)["structuredContent"]
    assert delivered["id"] == receipt["id"] and delivered["state"] == "fulfilled" and delivered["receipt"]
    granted = send("read_granted_brief", **lookup)["structuredContent"]
    assert granted["available"] and granted["brief_id"] == brief_id and granted["markdown"] == reviewed
    assert granted["expires_at"] in delivered["receipt"] and granted["receipt"] == delivered["receipt"]
    assert send("read_granted_brief", **wrong_sender)["structuredContent"] == {"available": False}
    parts = ("work-request-brief-v1", brief_id, granted["title"], reviewed)
    assert granted["digest"] == hashlib.sha256("".join(f"{len(part.encode())}:{part}" for part in parts).encode()).hexdigest()

    command(owner, receiver, "revoke", receipt["id"])
    assert send("get_work_request", **lookup)["structuredContent"]["state"] == "revoked"
    assert send("read_granted_brief", **lookup)["structuredContent"] == {"available": False}

    exact = {**filed, "request_id": str(uuid.uuid4()), "brief_id": brief_id}
    expiring = send("submit_work_request", **exact)["structuredContent"]
    command(owner, receiver, "grant", expiring["id"], brief_id)
    lookup = {key: exact[key] for key in ("peer", "request_id")}
    assert send("read_granted_brief", **lookup)["structuredContent"]["available"]
    with contextlib.closing(sqlite3.connect(Path(receiver["HEREFORTH_HOME"]) / "hereforth.sqlite")) as db:
        db.execute("UPDATE work_requests SET grant_expires = unixepoch() - 1 WHERE id = ?", (expiring["id"],))
        db.commit()
    assert send("get_work_request", **lookup)["structuredContent"]["state"] == "expired"
    assert send("read_granted_brief", **lookup)["structuredContent"] == {"available": False}

    active = {**filed, "request_id": str(uuid.uuid4()), "brief_id": brief_id}
    active_receipt = send("submit_work_request", **active)["structuredContent"]
    command(owner, receiver, "grant", active_receipt["id"], brief_id)
    assert send("read_granted_brief", peer=active["peer"], request_id=active["request_id"])["structuredContent"]["available"]
    return active["request_id"]


def main(binary):
    with tempfile.TemporaryDirectory(prefix="hereforth-peer-") as temp:
        root = Path(temp)
        sender = {**os.environ, "HEREFORTH_HOME": str(root / "sender")}
        receiver = {**os.environ, "HEREFORTH_HOME": str(root / "receiver")}
        token = command(binary, receiver, "peer", "invite", "Avery IT")
        other_token = command(binary, receiver, "peer", "invite", "Taylor IT")
        assert len(token.strip()) == 64 and token != other_token

        with listener(binary, receiver) as origin:
            command(binary, sender, "peer", "add", "Morgan", origin, input=token)
            command(binary, sender, "peer", "add", "Morgan wrong token", origin, input=b"0" * 64 + b"\n")
            command(binary, sender, "peer", "add", "Morgan other sender", origin, input=other_token)
            assert (root / "sender" / "peer-settings.json").stat().st_mode & 0o077 == 0
            assert (root / "receiver" / "peer-settings.json").stat().st_mode & 0o077 == 0

            with server(binary, sender) as (_, _, init_sender, send):
                init_sender("2025-11-25")
                assert send("list_peer_sessions", peer="Morgan")["structuredContent"]["sessions"] == []
                assert send("list_peer_sessions", peer="Morgan wrong token")["isError"]

                with server(binary, receiver) as (_, request, init_receiver, receive):
                    init_receiver("2025-11-25")
                    first = receive("publish_current_session", label="Vendor intake")["structuredContent"]
                    second = receive("publish_current_session", label="Access review")["structuredContent"]
                    session = first["session_id"]
                    key = first["receiver_key"]
                    assert key != second["receiver_key"]
                    sessions = send("list_peer_sessions", peer="Morgan")["structuredContent"]["sessions"]
                    assert {item["id"] for item in sessions} == {session, second["session_id"]}
                    assert all(set(item) == {"id", "label"} for item in sessions)
                    assert receive("read_session_context", receiver_key=session)["isError"]
                    body = "Could you confirm the vendor intake owner? The intake ticket is DEMO-42."
                    offer = dict(peer="Morgan", session_id=session, body=body, request_id=str(uuid.uuid4()))
                    wrong = {**offer, "session_id": str(uuid.uuid4())}
                    assert send("offer_session_context", **wrong)["isError"]
                    submitted = send("offer_session_context", **offer)["structuredContent"]
                    offer_id = submitted["offer_id"]
                    assert submitted["state"] == "submitted_for_review"
                    assert submitted["request_id"] == offer["request_id"]
                    assert send("offer_session_context", **offer)["structuredContent"]["offer_id"] == offer_id
                    assert send("offer_session_context", **{**offer, "session_id": second["session_id"]})["isError"]

                    status_query = dict(peer="Morgan", request_id=offer["request_id"])
                    assert send("get_context_status", **status_query)["structuredContent"] == {"state": "pending"}
                    assert send("get_context_status", **{**status_query, "peer": "Morgan other sender"})[
                        "structuredContent"] == {"state": "unknown"}
                    assert receive("read_session_context", receiver_key=key)["structuredContent"]["context"] == []
                    assert receive("read_session_context", receiver_key=second["receiver_key"])["structuredContent"]["context"] == []
                    assert body not in str(request("tools/list"))
                    entries = receive("list_context_requests")["structuredContent"]["requests"]
                    assert entries == [{
                        "id": offer_id, "sender": "Avery IT", "session_label": "Vendor intake", "state": "pending",
                    }]
                    assert body not in str(entries) and key not in str(entries)

                    def approve_fixture():
                        # Simulate the recipient UI’s local approval. Store tests exercise the real review API.
                        time.sleep(0.35)
                        with contextlib.closing(sqlite3.connect(root / "receiver" / "hereforth.sqlite")) as db:
                            assert db.execute(
                                "UPDATE context_offers SET state = 'approved' WHERE id = ? AND state = 'pending'",
                                (offer_id,),
                            ).rowcount == 1
                            db.commit()

                    approval = threading.Thread(target=approve_fixture)
                    approval.start()
                    delivery = receive("read_session_context", receiver_key=key, wait_seconds=3)["structuredContent"]
                    approval.join()
                    assert len(delivery["context"]) == 1 and "untrusted" in delivery["instructions"]
                    assert delivery["context"][0]["body"] == body and delivery["context"][0]["sender"] == "Avery IT"
                    assert receive("read_session_context", receiver_key=key)["structuredContent"]["context"] == []
                    assert send("get_context_status", **status_query)["structuredContent"] == {"state": "delivered"}
                    assert receive("unpublish_current_session", receiver_key=key)["structuredContent"]["closed"]
                    assert receive("read_session_context", receiver_key=key)["isError"]
                    assert send("offer_session_context", **{**offer, "request_id": str(uuid.uuid4())})["isError"]
                    listing = send("list_peer_sessions", peer="Morgan")["structuredContent"]["sessions"]
                    assert [item["id"] for item in listing] == [second["session_id"]]

                assert send("list_peer_sessions", peer="Morgan")["structuredContent"]["sessions"] == []
                active_grant = check_durable(binary, receiver, root, send)
                command(binary, receiver, "peer", "revoke", "Avery IT")
                assert send("list_peer_sessions", peer="Morgan")["isError"]
                assert send("read_granted_brief", peer="Morgan", request_id=active_grant)["isError"]
                replacement = command(binary, receiver, "peer", "invite", "Avery IT")
                command(binary, sender, "peer", "add", "Morgan reissued", origin, input=replacement)
                old_lookup = dict(peer="Morgan reissued", request_id=active_grant)
                assert send("get_work_request", **old_lookup)["structuredContent"] == {"state": "unknown"}
                assert send("read_granted_brief", **old_lookup)["structuredContent"] == {"available": False}
                context_lookup = {**status_query, "peer": "Morgan reissued"}
                assert send("get_context_status", **context_lookup)["structuredContent"] == {"state": "unknown"}
                fresh = dict(peer="Morgan reissued", request_id=str(uuid.uuid4()), body="A request from the replacement pairing.")
                new_receipt = send("submit_work_request", **fresh)["structuredContent"]
                fresh_lookup = {key: fresh[key] for key in ("peer", "request_id")}
                assert send("get_work_request", **fresh_lookup)["structuredContent"]["id"] == new_receipt["id"]
                rotation = command(binary, receiver, "peer", "invite", "Avery IT")
                command(binary, sender, "peer", "add", "Morgan rotated", origin, input=rotation)
                assert send("get_work_request", **fresh_lookup)["isError"]
                assert send("get_work_request", **{**fresh_lookup, "peer": "Morgan rotated"})["structuredContent"] == {"state": "unknown"}
                assert send("list_peer_sessions", peer="Morgan other sender")["structuredContent"]["sessions"] == []
                command(binary, sender, "peer", "remove", "Morgan other sender")
                assert send("list_peer_sessions", peer="Morgan other sender")["isError"]
        check_redirect(binary, sender, token)
    print("Paired peer smoke test passed.")


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
