# Read-only Code Mode

In the development build, a connected assistant can write a short JavaScript query that runs on your Mac. For example, it can find the chats where you decided something, read the original passages, and compare them with the latest update a teammate shared with you. The assistant chooses which evidence to return to its chat. If you use Codex or Claude Code, that evidence can reach the model provider. In the Qwen test below, inference also ran on the Mac.

## Try it from a checkout

Run `swift build --product hereforth` on your Mac. For an additional stdio MCP connection in your client, set the command to the absolute path of `.build/debug/hereforth` and the arguments to `["mcp", "--code-mode"]`. This connection advertises one tool, `query_context`. The released 0.4.0 DMG predates the prototype.

A question like “Which decisions about onboarding came up in my chats, and did the team update cover them?” can use three functions inside a single tool call.

| Function | Evidence it can read |
| --- | --- |
| `search_decisions({query})` | Matching excerpts from your imports with dates and source handles. |
| `read_passage({citation, offset?})` | The source text for a handle returned by search. |
| `team_standup({peers?})` | Each named teammate’s latest owner-written update already shared with you, or its availability status. |

Hereforth runs each script in a fresh JavaScriptCore process. The parent checks each read and applies the same peer permissions as ordinary MCP. The worker can run up to six reads per script, including one standup lookup, and return up to 24 KiB of JSON. It starts with an empty working directory and a restricted environment. A macOS sandbox denies direct access to user files, the network and other processes. If the worker cannot enter that sandbox, the query fails. This prototype uses the deprecated macOS Seatbelt initialization API. We tested it on Apple Silicon running macOS 26.6.2.

## The Juniper comparison

We asked each assistant the same question in a fresh session.

> What did we decide about Juniper this week, and which decisions are missing from Ryan’s latest shared update?

The fixture contained five synthetic conversations and a loopback Hereforth peer named Ryan. An earlier message proposed Thursday afternoon. The confirmed decision was **Friday at 10 a.m. Pacific, batched uploads for pilot accounts only, and the existing billing CSV schema**. Ryan’s approved update included the launch time and said the checklist was ready. It omitted the pilot restriction and the billing decision. Search could also surface an older log-retention agreement and a different project's meeting notes.

Regular MCP advertised three individual reads. Code Mode advertised one tool that could call those same three functions. The harness used identical writing instructions and removed reminders for a writing tool outside the three-read benchmark. The models chose their own queries. We kept the expected answer outside the model’s profile and scored only the final answers.

### Results on November 21, 2026

Time, tokens and client-visible tool calls are means of two fresh sessions per row. The two scores in each quality column are the individual runs. Content covers eight checks on the decisions, the comparison with Ryan, and handling of the proposal and decoys. Source credit covers three decisions and Ryan’s update. It requires a full relevant source handle, or the full thread ID or exact timestamp for the update.

| Client and model | Interface | Content /8 | Sources /4 | Input tokens | Cached input | Output tokens | Seconds | Tool calls |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Codex, GPT-6.2 Sol | Regular MCP | 8, 8 | 4, 4 | 52,492 | 42,432 | 554 | 18.5 | 6.5 |
| Codex, GPT-6.2 Sol | Code Mode | 8, 8 | 3, 4 | 68,651 | 61,440 | 610 | 21.4 | 2.5 |
| Claude Code, Sonnet 5 | Regular MCP | 7, 8 | 3, 0 | 14,016 | 11,900 | 932 | 12.5 | 2 |
| Claude Code, Sonnet 5 | Code Mode | 7, 8 | 4, 0 | 14,132 | 9,154 | 933 | 11.4 | 2 |
| Qwen3-4B, local | Regular MCP | 5, 7 | 0, 0 | 3,191 | 0 | 258 | 6.2 | 2 |
| Qwen3-4B, local | Code Mode | 4, 4 | 0, 0 | 1,414 | 0 | 333 | 6.5 | 1 |

**Codex** identified both omissions in every run. It made fewer tool calls in Code Mode, yet used 31% more total input and took about three seconds longer. Caching matters here. Mean input outside the reported cache dropped from 10,060 to 7,211 tokens. All four answers included usable handles for the three local decisions. One Code Mode answer omitted the standup thread ID. Another included the right ID inside an invalid passage link.

**Claude** also identified both omissions every time. One Code Mode answer added a third gap from the previous week. One regular MCP answer mentioned that old decision separately. Claude abbreviated source IDs in the second run of each mode, so someone following up could not pass them to Hereforth. Input and output totals were similar across the two modes.

**Local Qwen** cut input by 56% in Code Mode. Both answers nevertheless told the user Ryan had covered everything. With regular MCP it identified the pilot restriction in both runs and the billing omission in one. It provided no retrievable source IDs in either mode.

I’d keep regular MCP as the default for questions like this. For a larger comparison, I’d test whether Code Mode can discard enough irrelevant passages on the Mac to improve the answer or the cost of getting it. This fixture’s six search hits already fit comfortably in one reply.

### Measurement details

The hosted runs used signed-in Codex and Claude Code with medium reasoning effort. Codex was configured for `gpt-6.2-sol`; its turn events did not independently report a model ID. Claude reported `claude-sonnet-5`. Both ran in fresh directories with their built-in execution tools disabled. A benchmark-only local relay let us hide personal instructions from the clients while the real Hereforth worker applied its own sandbox. A separate Claude Code session successfully called the native helper directly. The timed Codex runs used the relay.

The local runs used the official Qwen3-4B Q4_K_M weights with llama.cpp build 12606 on an M5 Pro with 48 GiB of memory. The model was loaded before timing. We used a 16,384-token context, temperature zero, seed 42, and thinking off. The runner disabled prompt caching and verified zero reported cache hits in all four runs. [Qwen model and weights](https://huggingface.co/Qwen/Qwen3-4B-GGUF/tree/bc640142c66e1fdd12af0bd68f40445458f3869b)

We reversed the order of the two interfaces for the second pair on each client. Wall time includes client or MCP startup, tool calls and the final response. Input and output cover every model round in a session. Cached tokens are a subset of input and can have a different price. The hosted clients have their own prompts, caching and network overhead, so compare modes within a client. With one question and two trials per cell, the timings describe this run.

The ledger contains all twelve synthetic answers, the per-run counters, and the criteria each answer missed. [Per-run results](../Benchmarks/CodeMode/results.json) · [Rerun the experiment](../Benchmarks/CodeMode/README.md)
