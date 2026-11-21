"""Test ordinary MCP teamwork, or run a live isolated fixture with --serve DIRECTORY."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import contextlib
import json
import os
from pathlib import Path
import runpy
import signal
import tempfile
import threading
import uuid

HERE = Path(__file__).resolve().parent
harness = runpy.run_path(str(HERE / "peer-smoke.py"))
command = harness["command"]
listener = harness["listener"]
server = harness["server"]
owner_harness = harness["owner_harness"]
NAMES = ("Ryan", "Priya", "Sam")
ALL = ("Observer", *NAMES)


def result(call, tool, **parameters):
    response = call(tool, **parameters)
    assert not response.get("isError"), (tool, response)
    return response["structuredContent"]


def atomically(path, value):
    intermediate = path.with_suffix(".tmp")
    intermediate.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    intermediate.replace(path)


class Team:
    def __init__(self, binary, root, stack, workload):
        self.binary = binary
        self.root = root
        self.stack = stack
        self.workload = workload
        self.profiles = {name: dict(os.environ, HEREFORTH_HOME=str(root / name)) for name in ALL}
        self.services = {}
        self.origins = {}
        self.calls = {}
        self.exports = {}
        self.sessions = {}
        self.observed = []

        for name in ALL:
            self.open_listener(name)
            _, _, initialize, self.calls[name] = stack.enter_context(server(binary, self.profiles[name]))
            assert initialize("2025-11-25") == "2025-11-25"

        def pair(pairing):
            source, recipient = pairing
            token = command(binary, self.profiles[recipient], "peer", "invite", source)
            command(binary, self.profiles[source], "peer", "add", recipient, self.origins[recipient], input=token)

        with ThreadPoolExecutor(max_workers=4) as workers:
            list(workers.map(pair, [(source, recipient) for source in ALL for recipient in ALL if source != recipient]))

        for name in NAMES:
            export = root / (name.lower() + "-workload.json")
            workload["write_fixture"](name, export)
            self.exports[name] = export
            command(binary, self.profiles[name], "import", export)

        def publish(name):
            label = f"{name} project room"
            session = self.call(name, "publish_current_session", label=label, report_activity=True)
            update = self.call(name, "update_session_activity", receiver_key=session["receiver_key"],
                               summary=f"{name} owner-only activity fixture", phase="running")
            assert update["provenance"] == "assistant_reported"
            return name, {**session, "label": label}

        with ThreadPoolExecutor(max_workers=3) as workers:
            self.sessions.update(workers.map(publish, NAMES))
        self.reviewer = owner_harness(root)

    def open_listener(self, name, port=None):
        connection = self.stack.enter_context(contextlib.ExitStack())
        self.services[name] = connection
        self.origins[name] = connection.enter_context(listener(self.binary, self.profiles[name], port=port))

    def call(self, name, tool, **parameters):
        response = result(self.calls[name], tool, **parameters)
        if name == "Observer":
            self.observed.append(response)
        return response

    def aggregate(self):
        rows = self.call("Observer", "team_standup")
        assert {entry["peer"] for entry in rows["teammates"]} == set(NAMES)
        return {row["peer"]: row for row in rows["teammates"]}

    def submit(self, name):
        filing = self.call("Observer", "request_standup_access", peer=name, request_id=str(uuid.uuid4()),
                           reason="Coordinate the synthetic team integration.")
        return filing["id"]

    def approve(self, texts, requests=None):
        requests = requests or {name: self.submit(name) for name in NAMES}
        threads = {}
        for name in NAMES:
            threads[name] = command(self.reviewer, self.profiles[name], "approve-standup", requests[name], texts[name]).decode().strip()
        return threads

    def initial_texts(self):
        return {name: self.workload["ROLES"][name].get("standup", f"{name} prepared a reviewed synthetic update.")
                for name in NAMES}

    def active_leases(self):
        for name in NAMES:
            session = self.sessions[name]
            remote = self.call("Observer", "list_peer_sessions", peer=name)
            assert remote["sessions"] == [{"id": session["session_id"], "label": session["label"]}]
            owner = self.call(name, "get_assistant_activity")["sessions"]
            matching = [current for current in owner if current["id"] == session["session_id"]]
            assert len(matching) == 1 and name + " owner-only activity fixture" in json.dumps(matching)
            assert name + " owner-only activity fixture" not in json.dumps(remote)
            assert session["receiver_key"] not in json.dumps(remote)
        assert self.call("Observer", "get_assistant_activity")["sessions"] == []

    def no_private_evidence(self, observed):
        canary = self.workload["PRIVATE_MARKER"]
        private_markers = {canary, *self.workload.get("PRIVATE_MARKERS", [])}
        for name in NAMES:
            private_markers.update(self.workload["ROLES"][name].get("private_markers", []))
            private_markers.add(name + " owner-only activity fixture")
        hits = self.call("Sam", "search_decisions", query=canary)["hits"]
        matching = [hit for hit in hits if canary in hit["excerpt"]]
        assert matching, "Privacy test could not find the canary in the source owner's real library"
        citation = matching[0]["citation"]
        assert canary in self.call("Sam", "read_passage", citation=citation)["passage"]
        denied = self.calls["Observer"]("read_passage", citation=citation)
        assert denied["isError"] and canary not in json.dumps(denied)
        raw_observed = json.dumps([observed, self.observed])
        for marker in private_markers:
            assert marker not in raw_observed
            assert self.call("Observer", "search_decisions", query=marker)["hits"] == []
        assert self.call("Observer", "list_conversations")["conversations"] == []

    def check_handoff(self):
        note = self.root / "approved-handoff-source.txt"
        note.write_text("Meeting packet: coordinate next Monday’s room reservation.", encoding="utf-8")
        command(self.binary, self.profiles["Ryan"], "import", note)
        citation = self.call("Ryan", "search_decisions", query="reservation")["hits"][0]["citation"]
        prepared = self.call("Ryan", "prepare_handoff", recipient="Priya", title="Room reservation",
                             decision="Coordinate the room reservation.", background="A synthetic meeting packet.",
                             next_step="Send the reviewed details to Priya’s project room.", citations=[citation])
        session = self.sessions["Priya"]
        parameters = dict(peer="Priya", session_id=session["session_id"], body=prepared["markdown"], request_id=str(uuid.uuid4()))
        offered = self.call("Ryan", "offer_session_context", **parameters)
        assert self.call("Ryan", "offer_session_context", **parameters) == offered
        assert self.call("Ryan", "get_context_status", peer="Priya", request_id=parameters["request_id"])["state"] == "pending"
        assert self.call("Priya", "read_session_context", receiver_key=session["receiver_key"])["context"] == []
        assert self.call("Observer", "list_context_requests")["requests"] == []
        assert self.call("Sam", "list_context_requests")["requests"] == []
        assert self.call("Observer", "get_context_status", peer="Priya", request_id=parameters["request_id"])["state"] == "unknown"
        assert self.calls["Observer"]("read_session_context", receiver_key=session["receiver_key"])["isError"]

        command(self.reviewer, self.profiles["Ryan"], "update", prepared["draft_id"], "Changed locally after the offered revision.")
        changed_retry = {**parameters, "body": "Attempt to replace the offered revision."}
        assert self.calls["Ryan"]("offer_session_context", **changed_retry)["isError"]
        command(self.reviewer, self.profiles["Priya"], "approve-context", offered["offer_id"])
        delivered = self.call("Priya", "read_session_context", receiver_key=session["receiver_key"])["context"]
        assert len(delivered) == 1 and delivered[0]["body"] == prepared["markdown"] and delivered[0]["sender"] == "Ryan"
        assert self.call("Ryan", "offer_session_context", **parameters) == offered
        assert self.call("Priya", "read_session_context", receiver_key=session["receiver_key"])["context"] == []
        assert self.call("Ryan", "get_context_status", peer="Priya", request_id=parameters["request_id"])["state"] == "delivered"
        assert self.calls["Observer"]("read_passage", citation=citation)["isError"]
        print("PASS named cross-teammate handoff waited for review, delivered immutable bytes once, and hid the offer from other peers")

    def check(self):
        self.active_leases()
        print("PASS three concurrent live leases expose only named routing metadata to the observer")
        requests = {name: self.submit(name) for name in NAMES}
        before = self.aggregate()
        assert all(row["state"] == "not_shared" and "update" not in row for row in before.values())
        initial = self.initial_texts()
        threads = self.approve(initial, requests)
        for name in NAMES:
            unauthorized = "Sam" if name != "Sam" else "Ryan"
            assert self.call(unauthorized, "read_standup_thread", peer=name, thread_id=threads[name]) == {"available": False}
        original = self.aggregate()
        assert all(original[name]["update"]["body"] == initial[name] for name in NAMES)
        self.call("Observer", "reply_to_standup", peer="Ryan", thread_id=threads["Ryan"],
                  request_id=str(uuid.uuid4()), body="This follow-up must not replace Ryan's update.")
        latest = "Ryan posted a later owner update."
        self.call("Ryan", "reply_to_standup", thread_id=threads["Ryan"], request_id=str(uuid.uuid4()), body=latest)
        updated = self.aggregate()
        assert updated["Ryan"]["update"]["body"] == latest
        assert updated["Ryan"]["update"]["thread_id"] == threads["Ryan"]
        assert updated["Priya"] == original["Priya"] and updated["Sam"] == original["Sam"]
        print("PASS standups stayed private before approval, then exposed only the approved owner updates to the granted audience")

        self.check_handoff()
        old_port = int(self.origins["Sam"].rsplit(":", 1)[1])
        self.services["Sam"].close()
        offline = self.aggregate()
        assert offline["Sam"] == {"peer": "Sam", "state": "unavailable"}
        assert offline["Ryan"] == updated["Ryan"] and offline["Priya"] == updated["Priya"]
        self.open_listener("Sam", port=old_port)
        recovered = self.aggregate()
        assert recovered == updated
        command(self.reviewer, self.profiles["Priya"], "revoke", requests["Priya"])
        revoked = self.aggregate()
        assert revoked["Priya"] == {"peer": "Priya", "state": "not_shared"}
        assert revoked["Ryan"] == updated["Ryan"] and revoked["Sam"] == updated["Sam"]
        assert self.call("Observer", "read_standup_thread", peer="Priya", thread_id=threads["Priya"]) == {"available": False}
        print("PASS one peer went offline, recovered, and a different peer revoked its grant without affecting the others")
        self.no_private_evidence([before, original, updated, offline, recovered, revoked])
        print("PASS private source canary and activity summaries stayed unavailable to the observer")

    def serve(self):
        self.active_leases()
        assert all(x["state"] == "not_shared" for x in self.aggregate().values())
        threads = self.approve(self.initial_texts())
        seeded = self.aggregate()
        self.no_private_evidence(seeded)
        atomically(self.root / "seeded-team.json", seeded)
        approvals = self.root / "approvals"
        approvals.mkdir(mode=0o700)
        atomically(self.root / "ready.json", {
            "helper": self.binary,
            "observer": {"home": self.profiles["Observer"]["HEREFORTH_HOME"], "origin": self.origins["Observer"]},
            "roles": {name: {
                "home": self.profiles[name]["HEREFORTH_HOME"],
                "origin": self.origins[name],
                "prompt": self.workload["ROLES"][name]["prompt"],
                "session_id": self.sessions[name]["session_id"],
                "thread_id": threads[name],
            } for name in NAMES},
            "approval": {"directory": str(approvals), "signal": str(self.root / "approve"),
                         "result": str(self.root / "approved-team.json")},
            "stop": str(self.root / "stop"),
        })
        print(f"Live synthetic fixture ready at {self.root / 'ready.json'}", flush=True)
        stopping = threading.Event()
        signal.signal(signal.SIGTERM, lambda *_: stopping.set())
        finalized = False
        while not stopping.wait(0.25) and not (self.root / "stop").exists():
            if not finalized and (self.root / "approve").exists():
                texts = {name: (approvals / f"{name}.md").read_text(encoding="utf-8") for name in NAMES}
                assert all(0 < len(text.encode()) <= 2_000 for text in texts.values()), "Keep every approved standup within 2,000 UTF-8 bytes."
                updated_threads = self.approve(texts)
                observed = self.aggregate()
                self.no_private_evidence(observed)
                for name in NAMES:
                    update = observed[name]["update"]
                    assert update["thread_id"] == updated_threads[name]
                    assert update["body"] == texts[name] and not update["truncated"]
                atomically(self.root / "approved-team.json", observed)
                print("PASS live observer recovered all three exact approved standups", flush=True)
                finalized = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path)
    parser.add_argument("--serve", type=Path, metavar="DIRECTORY")
    args = parser.parse_args()
    binary = str(args.helper.resolve(strict=True))
    workloads = runpy.run_path(str(HERE / "team-workloads.py"))
    with contextlib.ExitStack() as stack:
        if args.serve:
            root = args.serve.resolve()
            root.mkdir(mode=0o700, parents=True, exist_ok=True)
            if any(root.iterdir()):
                parser.error("--serve needs a new or empty fixture directory")
        else:
            root = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="hereforth-three-teammates-")))
        team = Team(binary, root, stack, workloads)
        if args.serve:
            team.serve()
        else:
            team.check()
            print("Three-teammate ordinary MCP smoke passed.")


if __name__ == "__main__":
    main()
