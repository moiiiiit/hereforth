"""Run a live isolated 21-profile team and verify Inbox, approvals, and offline isolation."""
from concurrent.futures import ThreadPoolExecutor
import contextlib
import os
from pathlib import Path
import runpy
import sys
import tempfile
import uuid

harness = runpy.run_path(str(Path(__file__).with_name("peer-smoke.py")))
command = harness["command"]
listener = harness["listener"]
server = harness["server"]
owner_harness = harness["owner_harness"]


def payload(call, tool, **parameters):
    response = call(tool, **parameters)
    assert not response.get("isError"), (tool, response)
    return response["structuredContent"]


def main(binary):
    with tempfile.TemporaryDirectory(prefix="hereforth-team-") as temp, contextlib.ExitStack() as stack:
        root = Path(temp)
        owner_review = owner_harness(root)
        names = [f"Teammate {index:02}" for index in range(1, 21)]
        hub = dict(os.environ, HEREFORTH_HOME=str(root / "hub"))
        profiles = [dict(os.environ, HEREFORTH_HOME=str(root / f"member-{index}")) for index in range(1, 21)]

        def open_service(profile):
            child = stack.enter_context(contextlib.ExitStack())
            return child, child.enter_context(listener(binary, profile))

        _, hub_origin = open_service(hub)
        team_services = [open_service(profile) for profile in profiles]

        def pair(index):
            name, profile, (_, origin) = names[index], profiles[index], team_services[index]
            token = command(binary, hub, "peer", "invite", name)
            command(binary, profile, "peer", "add", "Hub", hub_origin, input=token)
            token = command(binary, profile, "peer", "invite", "Hub")
            command(binary, hub, "peer", "add", name, origin, input=token)

        with ThreadPoolExecutor(max_workers=8) as workers:
            list(workers.map(pair, range(20)))
        config_mode = (root / "hub/peer-settings.json").stat().st_mode
        assert config_mode & 0o077 == 0

        def connect(profile):
            _, _, initialize, call = stack.enter_context(server(binary, profile))
            assert initialize("2025-11-25") == "2025-11-25"
            return call

        hub_call = connect(hub)
        members = [connect(profile) for profile in profiles]
        roster = payload(hub_call, "list_peers")
        assert {entry["name"] for entry in roster["peers"]} == set(names)
        assert all(set(entry) == {"name"} for entry in roster["peers"])
        assert payload(hub_call, "list_peers", query="mate 20")["peers"] == [{"name": names[-1]}]

        # Twenty distinct credentials share the same destination and retry key.
        session = payload(hub_call, "publish_current_session", label="Team coordination")
        offer_request = str(uuid.uuid4())
        work_request = str(uuid.uuid4())

        def incoming(index):
            call = members[index]
            assert payload(call, "list_peer_sessions", peer="Hub")["sessions"] == [
                {"id": session["session_id"], "label": "Team coordination"}
            ]
            offer = dict(peer="Hub", session_id=session["session_id"], request_id=offer_request,
                         body=f"Context from {names[index]}")
            sent = payload(call, "offer_session_context", **offer)
            assert payload(call, "offer_session_context", **offer) == sent
            work = payload(call, "submit_work_request", peer="Hub", request_id=work_request,
                           body=f"{names[index]} requests the reviewed brief.", requests_brief=True)
            return sent["offer_id"], work["id"]

        with ThreadPoolExecutor(max_workers=20) as workers:
            receipts = list(workers.map(incoming, range(20)))
        assert len({offer for offer, _ in receipts}) == len({work for _, work in receipts}) == 20
        offers = payload(hub_call, "list_context_requests")["requests"]
        assert {row["id"]: (row["sender"], row["session_label"], row["state"]) for row in offers} == {
            offer: (name, "Team coordination", "pending") for name, (offer, _) in zip(names, receipts)
        }
        work = payload(hub_call, "list_work_requests")["requests"]
        assert {row["id"]: row["sender"] for row in work} == {
            request: name for name, (_, request) in zip(names, receipts)
        }

        # Equal request UUIDs never substitute for the credential that received an actual grant.
        fixture = root / "glacier.md"
        raw_evidence = "Glacier has a private synthetic artifact. ONLY_LOCAL_EVIDENCE_724."
        fixture.write_text(raw_evidence)
        brief = command(owner_review, hub, "create", fixture).decode().strip()
        reviewed = "# Reviewed brief\n\nSynthetic handoff approved for one teammate."
        command(owner_review, hub, "update", brief, reviewed)
        command(owner_review, hub, "grant", receipts[0][1], brief)
        for index, call in enumerate(members):
            status = payload(call, "get_work_request", peer="Hub", request_id=work_request)
            assert status["id"] == receipts[index][1]
            assert status["state"] == ("fulfilled" if index == 0 else "pending")
            grant = payload(call, "read_granted_brief", peer="Hub", request_id=work_request)
            if index == 0:
                assert grant["available"] and grant["markdown"] == reviewed
            else:
                assert grant == {"available": False}
        command(owner_review, hub, "revoke", receipts[0][1])
        assert payload(members[0], "read_granted_brief", peer="Hub", request_id=work_request) == {"available": False}

        standup_request = str(uuid.uuid4())
        open_threads = {}
        updates = {}
        long_update = "x" * 1999 + "🧭 Check the last task."
        for index, name in enumerate(names):
            filing = payload(hub_call, "request_standup_access", peer=name, request_id=standup_request,
                             reason="Coordinate the synthetic demo.")
            assert payload(hub_call, "get_work_request", peer=name, request_id=standup_request)["id"] == filing["id"]
            if index < 19:
                updates[name] = long_update if index == 18 else f"{name} finished synthetic item {index + 1}."
                thread = command(owner_review, profiles[index], "approve-standup", filing["id"], updates[name])
                open_threads[name] = (filing["id"], thread.decode().strip())
        assert len({request for request, _ in open_threads.values()}) == 19

        # A peer reply is not an owner update. A later owner reply in an older thread wins.
        first = names[0]
        older_thread = open_threads[first][1]
        new_request = payload(hub_call, "request_standup_access", peer=first, request_id=str(uuid.uuid4()),
                              reason="Check a different synthetic detail.")
        command(owner_review, profiles[0], "approve-standup", new_request["id"], "SUPERSEDED_SYNTHETIC_UPDATE")
        updates[first] = f"{first} posted the latest owner update in the older thread."
        payload(members[0], "reply_to_standup", thread_id=older_thread, request_id=str(uuid.uuid4()), body=updates[first])
        payload(hub_call, "reply_to_standup", peer=first, thread_id=older_thread, request_id=str(uuid.uuid4()),
                body="PEER_QUESTION_NOT_AN_OWNER_UPDATE")

        # The unshared teammate has both local evidence and a thread approved for a different caller.
        command(binary, profiles[-1], "import", fixture)
        alternate = command(binary, profiles[-1], "peer", "invite", "Different colleague")
        command(binary, profiles[1], "peer", "add", names[-1], team_services[-1][1], input=alternate)
        private = payload(members[1], "request_standup_access", peer=names[-1], request_id=standup_request,
                          reason="A different audience.")
        private_thread = command(owner_review, profiles[-1], "approve-standup", private["id"],
                                 "APPROVED_ONLY_FOR_DIFFERENT_COLLEAGUE").decode().strip()
        assert payload(members[1], "read_standup_thread", peer=names[-1], thread_id=private_thread)["available"]
        assert payload(hub_call, "read_standup_thread", peer=names[-1], thread_id=private_thread) == {"available": False}

        def capture_team(**params):
            aggregate = payload(hub_call, "team_standup", **params)
            rows = aggregate["teammates"]
            assert len({row["peer"] for row in rows}) == len(rows)
            text = str(aggregate)
            for secret in ("ONLY_LOCAL_EVIDENCE_724", "APPROVED_ONLY_FOR_DIFFERENT_COLLEAGUE",
                           "PEER_QUESTION_NOT_AN_OWNER_UPDATE", "SUPERSEDED_SYNTHETIC_UPDATE", private_thread):
                assert secret not in text
            return {row["peer"]: row for row in rows}

        before = capture_team()
        assert set(before) == set(names)
        for name, update in updates.items():
            assert before[name]["state"] == "shared"
            reported = before[name]["update"]
            assert reported["author"] == "owner" and reported["created_at"] and reported["expires_at"]
            if name == names[-2]:
                assert reported["truncated"] is True and reported["body"] == "x" * 1999
                full = payload(hub_call, "read_standup_thread", peer=name, thread_id=reported["thread_id"])
                assert full["messages"][0]["body"] == long_update
            else:
                assert reported["truncated"] is False and reported["body"] == update
        assert before[first]["update"]["thread_id"] == older_thread
        assert before[names[-1]]["state"] == "not_shared" and "update" not in before[names[-1]]

        revoked, offline, unpaired = names[2], names[3], names[4]
        command(owner_review, profiles[2], "revoke", open_threads[revoked][0])
        team_services[3][0].close()
        command(binary, profiles[4], "peer", "revoke", "Hub")
        after = capture_team()
        assert set(after) == set(names)
        assert after[revoked]["state"] == "not_shared" and "update" not in after[revoked]
        assert after[offline]["state"] == "unavailable" and "update" not in after[offline]
        assert after[unpaired]["state"] == "unavailable" and "update" not in after[unpaired]
        assert after[first]["state"] == "shared" and after[names[-2]]["state"] == "shared"
        assert set(capture_team(peers=[offline, first])) == {offline, first}
        alternate = command(binary, profiles[0], "peer", "invite", "Extra routing identity")
        command(binary, hub, "peer", "add", "Extra", team_services[0][1], input=alternate)
        assert len(payload(hub_call, "list_peers")["peers"]) == 21
        assert hub_call("team_standup").get("isError")
        assert capture_team(peers=[first])[first]["state"] == "shared"
    print("20-peer smoke passed: live roster, concurrent Inbox, scoped grants, approved standups, and offline isolation.")


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
