"""Exercise phone actions with isolated profiles. Passkey and HTTP routing have their own tests."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import uuid

helpers = runpy.run_path(str(Path(__file__).with_name("peer-smoke.py")))
command = helpers["command"]
listener = helpers["listener"]
server = helpers["server"]
owner_harness = helpers["owner_harness"]
repository = Path(__file__).resolve().parent.parent


def driver(root):
    core = sorted((repository / "Sources/HereforthCore").glob("*.swift"))
    cli = []
    for name in ("Peer", "PeerListener", "PhoneActions"):
        target = root / f"{name}.swift"
        target.write_text((repository / f"Sources/hereforth/{name}.swift").read_text().replace("import HereforthCore\n", ""))
        cli.append(target)
    main = root / "main.swift"
    main.write_text("""
import Foundation
func writeError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}
do {
    let response = try PhoneActions(store: Store()).handle(CommandLine.arguments[1], payload: FileHandle.standardInput.readDataToEndOfFile())
    FileHandle.standardOutput.write(response)
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(1)
}
""")
    entry = root / "actions"
    subprocess.run(["swiftc", "-I", repository / "Sources/CSQLite", *core, *cli, main, "-o", entry],
                   check=True, timeout=60, capture_output=True)
    return entry


def phone(entry, owner, action, *, succeeds=True, **payload):
    result = subprocess.run([entry, action], input=json.dumps(payload).encode(), env=owner,
                            capture_output=True, timeout=15)
    assert (result.returncode == 0) == succeeds, (action, result.stderr.decode())
    return json.loads(result.stdout) if succeeds else result.stderr.decode()


def main(binary):
    with tempfile.TemporaryDirectory(prefix="hereforth-phone-actions-") as directory:
        root = Path(directory)
        owner = dict(os.environ, HEREFORTH_HOME=str(root / "owner"))
        recipient = dict(os.environ, HEREFORTH_HOME=str(root / "recipient"))
        cli = driver(root)
        reviewer = owner_harness(root)
        fixture = root / "glacier.md"
        fixture.write_text("Glacier synthetic handoff.")
        brief = command(reviewer, owner, "create", fixture).decode().strip()
        text = "# Synthetic handoff\n\nReview the staged report."
        command(reviewer, owner, "update", brief, text)
        token = command(binary, recipient, "peer", "invite", "Owner fixture")

        with listener(binary, recipient) as origin, server(binary, recipient) as (_, _, initialize, receive):
            initialize("2025-11-25")
            publication = receive("publish_current_session", label="Ryan fixture")["structuredContent"]
            command(binary, owner, "peer", "add", "Ryan fixture", origin, input=token)
            assert phone(cli, owner, "list_peer_sessions", peer="Ryan fixture")["sessions"] == [
                {"id": publication["session_id"], "label": "Ryan fixture"}
            ]
            inputs = dict(brief_id=brief, peer="Ryan fixture", session_id=publication["session_id"], request_id=str(uuid.uuid4()))
            preview = phone(cli, owner, "preview_handoff", **inputs)
            assert preview["markdown"] == text and preview["peer"] == "Ryan fixture" and preview["state"] == "prepared"
            assert "destinationKey" not in preview
            assert phone(cli, owner, "preview_handoff", **inputs) == preview
            assert "changed" in phone(cli, owner, "send_handoff", id=preview["id"], digest="incorrect", succeeds=False)
            assert receive("list_context_requests")["structuredContent"]["requests"] == []
            sent = phone(cli, owner, "send_handoff", id=preview["id"], digest=preview["digest"])
            assert sent["state"] == "sent" and uuid.UUID(sent["receipt"])
            assert phone(cli, owner, "send_handoff", id=preview["id"], digest=preview["digest"]) == sent
            inbox = phone(cli, recipient, "inbox")["items"]
            assert len(inbox) == 1 and inbox[0]["body"] == text and inbox[0]["sender"] == "Owner fixture"
            item = inbox[0]
            phone(cli, recipient, "review_context", id=item["id"], digest="other", approve=True, succeeds=False)
            update = phone(cli, recipient, "review_context", id=item["id"], digest=item["digest"], approve=True)
            assert update["state"] == "approved"
            delivered = receive("read_session_context", receiver_key=publication["receiver_key"])["structuredContent"]
            assert [row["body"] for row in delivered["context"]] == [text]
            assert phone(cli, recipient, "review_context", id=item["id"], digest=item["digest"], approve=True)["state"] == "consumed"

            recipient_brief = command(reviewer, recipient, "create", fixture).decode().strip()
            with server(binary, owner) as (_, _, initialize_owner, sender):
                initialize_owner("2025-11-25")
                request_id = str(uuid.uuid4())
                grant = sender("submit_work_request", peer="Ryan fixture", request_id=request_id,
                               body="Review this exact synthetic brief.", requests_brief=True,
                               brief_id=recipient_brief)["structuredContent"]
                row = next(x for x in phone(cli, recipient, "inbox")["items"] if x["id"] == grant["id"])
                revision = phone(cli, recipient, "preview_work", id=row["id"], brief_id=recipient_brief)
                command(reviewer, recipient, "update", recipient_brief, "# Synthetic approved artifact")
                review = dict(id=row["id"], digest=row["digest"], approve=True, brief_id=recipient_brief,
                              revision_digest=revision["digest"])
                phone(cli, recipient, "review_work", **review, succeeds=False)
                revision = phone(cli, recipient, "preview_work", id=row["id"], brief_id=recipient_brief)
                review["revision_digest"] = revision["digest"]
                assert phone(cli, recipient, "review_work", **review)["state"] == "fulfilled"
                assert phone(cli, recipient, "review_work", **review)["state"] == "fulfilled"
                approved = sender("read_granted_brief", peer="Ryan fixture", request_id=request_id)["structuredContent"]
                assert approved["available"] and approved["markdown"] == "# Synthetic approved artifact"

                standup = sender("request_standup_access", peer="Ryan fixture", request_id=str(uuid.uuid4()),
                                 reason="Review a synthetic update.")["structuredContent"]
                prepared = phone(cli, recipient, "preview_standup", id=standup["id"], approved_text="Synthetic update.")
                arguments = dict(id=standup["id"], digest=prepared["digest"], approved_text="Synthetic update.")
                phone(cli, recipient, "review_standup", **{**arguments, "approved_text": "Changed."}, succeeds=False)
                confirmed = phone(cli, recipient, "review_standup", **arguments)
                assert confirmed["state"] == "fulfilled"
                assert phone(cli, recipient, "review_standup", **arguments) == confirmed

        request = dict(request_id=str(uuid.uuid4()), client="claude", kind="computer", prompt="Synthetic task." * 30)
        task = phone(cli, owner, "queue_task", **request)
        assert task["state"] == "pending_review"
        assert phone(cli, owner, "queue_task", **request) == task
        assert phone(cli, owner, "get_task", id=task["id"])["prompt"] == request["prompt"]
        phone(cli, owner, "queue_task", **{**request, "prompt": "Changed"}, succeeds=False)
        phone(cli, owner, "queue_task", **request, executable="/bin/sh", succeeds=False)

        with server(binary, owner) as (_, _, initialize, call):
            initialize("2025-11-25")
            inactive = call("publish_current_session", label="Unnamed work")["structuredContent"]
            assert call("update_session_activity", receiver_key=inactive["receiver_key"], summary="Rejected", phase="running")["isError"]
            active = call("publish_current_session", label="Public label", report_activity=True)["structuredContent"]
            assert call("update_session_activity", receiver_key=active["receiver_key"], summary="Private progress", phase="running")["structuredContent"]["updated"]
            from_phone = phone(cli, owner, "activity")
            from_mcp = call("get_assistant_activity")["structuredContent"]
            assert from_phone == from_mcp
            assert from_phone["tasks"][0]["descriptionTruncated"] and "prompt" not in from_phone["tasks"][0]
            state = next(row for row in from_phone["sessions"] if row["id"] == active["session_id"])
            assert state["summary"] == "Private progress" and state["activityAt"] and state["state"] == "published"

    print("Phone business actions smoke passed.")


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
