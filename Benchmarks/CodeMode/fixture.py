"""Seed the synthetic Juniper benchmark and keep Ryan's loopback service available."""
import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import runpy
import signal
import sys
import uuid

harness = runpy.run_path(str(Path(__file__).resolve().parents[2] / "Tests" / "peer-smoke.py"))
command, listener, server, owner_harness = [harness[name] for name in ("command", "listener", "server", "owner_harness")]
PROMPT = "What did we decide about Juniper this week, and which decisions are missing from Ryan’s latest shared update?"
SYSTEM = "Use Hereforth evidence and cite sources."
READS = ["search_decisions", "team_standup", "read_passage"]


def main(binary, root):
    root.mkdir(mode=0o700, exist_ok=True)
    assert not any(root.iterdir()), "Choose an empty fixture directory."
    owner_path, ryan_path = root / "owner", root / "ryan"
    owner = {**os.environ, "HEREFORTH_HOME": str(owner_path)}
    ryan = {**os.environ, "HEREFORTH_HOME": str(ryan_path)}
    now = datetime.now().astimezone()
    monday_wall = (now - timedelta(days=now.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
    monday = monday_wall.astimezone(timezone.utc)
    elapsed = now.astimezone(timezone.utc) - monday

    def stamp(fraction):
        return (monday + fraction * elapsed).isoformat().replace("+00:00", "Z")

    source = {
        "proposal": "Juniper proposal: Thursday at 3 p.m. Pacific, batch uploads for all accounts, and a revised billing CSV schema. These are options for review.",
        "confirmed": "Juniper release decision, confirmed: Friday at 10 a.m. Pacific. Enable batched uploads only for pilot accounts. Keep the existing billing CSV schema unchanged.",
        "scope": "Juniper approval notes: batched uploads are limited to pilot accounts. Non-pilot accounts keep individual uploads.",
        "schema": "Juniper billing review: retain the existing billing CSV schema. The proposed schema change was dropped.",
        "old": "Juniper retention: keep 45 days of staging logs. This was agreed in the prior local calendar week.",
        "noise": "Juniper was mentioned in the Bayberry planning meeting. Bayberry agreed to a Tuesday migration and 15-day debug logs. This is a separate project.",
    }

    def passage(key, timestamp):
        return {"uuid": "synthetic-juniper-" + key, "sender": "assistant", "created_at": timestamp, "text": source[key]}

    def chat(key, title, items):
        return {"uuid": "synthetic-chat-" + key, "name": title, "chat_messages": items}

    prior = (monday - timedelta(days=2)).isoformat().replace("+00:00", "Z")
    fixture = root / "private-owner-chats.json"
    fixture.write_text(json.dumps([
        chat("release", "Juniper release decision", [passage("proposal", stamp(0.18)), passage("confirmed", stamp(0.90))]),
        chat("pilot", "Juniper pilot approval", [passage("scope", stamp(0.78))]),
        chat("billing", "Juniper billing review", [passage("schema", stamp(0.82))]),
        chat("older", "Juniper previous-week retention", [passage("old", prior)]),
        chat("bayberry", "Bayberry planning", [passage("noise", stamp(0.65))]),
    ], ensure_ascii=False))
    command(binary, owner, "import", fixture)
    reviewer = owner_harness(root)
    token = command(binary, ryan, "peer", "invite", "Benchmark owner")
    update = "Juniper will go live Friday at 10 a.m. Pacific. The rollout checklist is ready."
    with listener(binary, ryan) as origin, server(binary, owner) as (_, _, initialize, call):
        command(binary, owner, "peer", "add", "Ryan", origin, input=token)
        initialize("2025-11-25")
        request = call("request_standup_access", peer="Ryan",
                       request_id=str(uuid.uuid5(uuid.NAMESPACE_URL, "hereforth:juniper:ryan")),
                       reason="Coordinate the synthetic Juniper rollout.")["structuredContent"]
        thread = command(reviewer, ryan, "approve-standup", request["id"], update).decode().strip()
        shared = call("team_standup", peers=["Ryan"])["structuredContent"]["teammates"][0]
        assert shared["state"] == "shared" and shared["update"]["body"] == update
        assert shared["update"]["thread_id"] == thread
        hits = call("search_decisions", query="Juniper")["structuredContent"]["hits"]
        citations = {key: next(hit["citation"] for hit in hits if hit["excerpt"].startswith(text[:35]))
                     for key, text in source.items()}
        for key in source:
            result = call("read_passage", citation=citations[key])
            assert source[key] in result["content"][0]["text"], key
        rubric = {
            "prompt": PROMPT, "system": SYSTEM, "week_start": monday.isoformat(),
            "content": [
                "Friday at 10 a.m. Pacific was confirmed.",
                "Only pilot accounts get batched uploads.",
                "The existing billing CSV schema stays unchanged.",
                "Ryan’s latest update includes the rollout time.",
                "Ryan’s update omits pilot-only batched uploads.",
                "Ryan’s update omits retaining the existing CSV schema.",
                "Thursday at 3 p.m. Pacific was a proposal only, if mentioned.",
                "Exclude the prior-week retention decision and unrelated Bayberry details."
            ],
            "grounding": {
                "confirmed timing": [citations["confirmed"]],
                "pilot scope": [citations["confirmed"], citations["scope"]],
                "billing schema": [citations["confirmed"], citations["schema"]],
                "Ryan comparison": {"thread_id": thread, "posted_at": shared["update"]["created_at"], "approved_text": update},
            },
            "citations": citations
        }
        (root / "rubric.json").write_text(json.dumps(rubric, indent=2, ensure_ascii=False) + "\n")
        print("READY " + json.dumps({"owner_home": str(owner_path), "peer_origin": origin,
                                     "rubric": str(root / "rubric.json"), "prompt": PROMPT, "system": SYSTEM,
                                     "tools": READS}, ensure_ascii=False), flush=True)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        try:
            while True:
                signal.pause()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="Path to the built Hereforth helper.")
    parser.add_argument("directory", type=Path, help="An empty temporary directory for synthetic profiles.")
    args = parser.parse_args()
    main(str(args.binary.resolve(strict=True)), args.directory.resolve())
