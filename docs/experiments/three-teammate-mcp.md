# Three teammates on regular MCP

On November 21, 2026, three signed-in Codex sessions worked on the same synthetic rollout through `hereforth mcp`. Each session had its own Hereforth library and owner. A fourth profile could discover published sessions and read the updates shared with it. All four profiles ran on one Apple Silicon Mac with separate loopback peer listeners.

## What the teammates did

| Teammate | Task | Verified first answer | Elapsed |
| --- | --- | --- | ---: |
| Ryan | Reconcile a ledger against the signed close rules, including a duplicate, reversal, pending charge and inclusive noon cutoff. | Four debits totaling 26,000 cents across three accounts. Identified every included and excluded record. | 35.1 s |
| Priya | Join the pilot registry to replay measurements and apply the final error and latency limits. | Cedar and Elm qualify. Elm is exactly on both boundaries. Spruce is over the latency limit, Birch is over the error limit, and Ash is outside the pilot. | 26.6 s |
| Sam | Compare a vendor evidence packet with the final controls and distinguish a listed subprocessor from an approved one. | Hold Northbank Relay. The DPA and incident contact are documented. Deletion took 21 days against a 14-day limit, and procurement approval for the subprocessor is missing. | 28.1 s |

All **19 structured findings** matched the fixture. All **seven required passage IDs** resolved in the correct owner's library. We checked the standup wording separately before simulating each owner's approval. The observer received the approved text byte for byte.

A fresh observer Codex session made one `team_standup` call. It identified the eligible pilot accounts, the reconciled amount, and both reasons to hold vendor review. It cited all three shared threads and timestamps and explicitly left deployment unconfirmed. The observer had zero imported chats. A marker planted in Sam’s private evidence was searchable in Sam’s profile and absent from the other three.

## One teammate’s work became another’s input

We opened a fresh Ryan session and asked it to calculate how much of the settlement belonged to release-eligible accounts. The prompt supplied neither the account names nor the answer. Priya's profile offered her exact reviewed standup to that session. The recipient's test owner approved the pending offer. Ryan received it once and combined it with his own ledger and settlement rules.

Ryan returned **$230 for Cedar and Elm** and **$30 for Spruce**, which adds back to the original $260. He cited both of his private sources in his own answer, attributed the cohort to Priya's offer, and left deployment unconfirmed. A retry returned the original receipt. A second read returned zero messages. We independently compared the hash of the offered text with the standup Priya had approved.

The saved evidence includes the three first answers, their shareable standups, the observer’s synthesis and the follow-up allocation. [Synthetic run results](three-teammate-results.json)

## Concurrency, handoffs and failure cases

- The first three sessions reported `running` concurrently for at least 7.3 seconds. A second batch reproduced all findings. Its observer captured three distinct routable sessions during an 8.1-second overlap. The owners could see task progress. A peer saw only the published session ID and label. After the Codex sessions exited, their routes closed and the approved standups remained readable.
- A deterministic handoff from Ryan to Priya waited in Priya's inbox. Editing Ryan’s original brief after offering it preserved the exact revision Priya received. Retrying the same request delivered one copy. Reusing the same request ID with different text failed. An unrelated session could neither claim the handoff nor look up its receipt.
- Before a grant, the observer saw no standup text. After approval it saw only the owner's update for that audience. Taking Sam offline made only Sam unavailable. Restarting the peer on its original port restored the update. Revoking Priya's grant removed access to her standup and thread while the other two stayed readable.

## How the test ran

The three clients used the signed-in Codex CLI configured for `gpt-6.2-sol` at medium effort. Each worked in a fresh directory and could call Hereforth's scoped evidence, publication, and progress tools. The harness hid personal instructions, disabled shell and web tools, and removed reminders for the out-of-scope writing-guide tool in those scored runs. The answer key stayed outside the model's tools. Test owners used the same local Store operations as the Mac approval UI.

The first concurrency snapshot expected the activity-write receipt's provenance on a session-list row. Those are separate fields. We fixed the assertion and repeated the simultaneous run. First-attempt answers and times are the ones shown above. A supplemental phone HTTP test also timed out when it copied a signed helper into a fabricated app bundle. Testing relocation with the complete signed app preserved its signature.

The deterministic team test passed against the release build from `a74792c` and installed **Hereforth 0.4.0**. The 30 Swift tests, two-peer handoff, 20-peer standup, phone business actions and phone HTTP checks passed. The grader also rejected a copy with an incorrect billing amount and a truncated citation. This setup exercises actual MCP processes, peer HTTP, stores and model inference on one Mac. A physical multi-Mac Tailscale connection, interactive UI approval, and a real vendor or deployment were outside this run.

## Reproduce

Run the deterministic suite from the repository root.

```sh
swift build -c release --product hereforth
python3 Tests/three-teammate-smoke.py .build/release/hereforth
```

For model inference, start a fresh fixture and keep that terminal running. The command prints the path to `ready.json`.

```sh
run_dir="$(mktemp -d)"
python3 Tests/three-teammate-smoke.py .build/release/hereforth --serve "$run_dir/live"
```

In a second terminal, set `run_dir` to the same directory. These commands use the signed-in Codex account and write the three model answers to a new local directory.

```sh
python3 Tests/three-teammate-clients.py --ready "$run_dir/live/ready.json" --output "$run_dir/clients"
python3 Tests/team-workloads.py --ready "$run_dir/live/ready.json" --results "$run_dir/clients"
```

To repeat the observer test, review each standup first. Write the exact approved text into `live/approvals/Ryan.md`, `Priya.md`, and `Sam.md` under the approvals directory. Create `live/approve`, wait for `live/approved-team.json`, then run the client harness with `--observer` and a fresh `--output` directory. Create `live/stop` to shut down the temporary peers.
