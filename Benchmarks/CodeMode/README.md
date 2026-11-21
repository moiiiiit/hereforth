# Juniper code mode benchmark

Build Hereforth, then seed the fixture in a terminal and leave it running while the benchmark runs.

```sh
swift build --product hereforth
fixture_dir="$(mktemp -d)"
python3 Benchmarks/CodeMode/fixture.py .build/debug/hereforth "$fixture_dir"
```

The fixture prints a `READY` record with the absolute owner directory. It verifies the six source citations and the exact owner-approved Ryan update before writing the scoring rubric outside the owner directory. It creates new synthetic profiles and uses a loopback peer service. Seed a new fixture when the local week changes.

In another terminal, set `fixture_dir` to the path from `READY` without the trailing `/owner`. Run both modes against the same local llama-server and model alias.

```sh
python3 Benchmarks/CodeMode/run_local.py \
  --binary .build/debug/hereforth --home "$fixture_dir/owner" \
  --endpoint http://127.0.0.1:8080/v1/chat/completions --model MODEL_ALIAS \
  --mode normal --output "$fixture_dir/local-normal.json"

python3 Benchmarks/CodeMode/run_local.py \
  --binary .build/debug/hereforth --home "$fixture_dir/owner" \
  --endpoint http://127.0.0.1:8080/v1/chat/completions --model MODEL_ALIAS \
  --mode code --output "$fixture_dir/local-code.json"
```

Ordinary mode exposes `search_decisions`, `team_standup`, and `read_passage`. Code mode exposes `query_context` over the same reads. Both modes use the same system instruction and user question. The runner asks llama-server to disable prefix caching and records the cached-token fields the server actually reports. A null counter means the server omitted it.

Score the response against `rubric.json` after the run. Give one content point for each of its eight claims or distinctions and score grounding independently. Give one grounding point for each of the three confirmed decisions tied to a listed source citation, and one for Ryan’s comparison tied to his shared thread ID or exact post timestamp. A single relevant citation can support several facts. The model receives only tool descriptions and results from its chosen reads. The run artifact retains the final redacted answer, usage and timing counters, and tool names with error flags.

## Rerun a hosted trial

With the fixture and your signed-in client ready, run the following example on macOS.

```sh
python3 Benchmarks/CodeMode/hosted-benchmark.py \
  --client codex --model gpt-6.2-sol --effort medium --mode ordinary \
  --binary .build/debug/hereforth --profile "$fixture_dir/owner" \
  --output "$fixture_dir/hosted-codex-ordinary"
```

Use `--mode code` for the other mode and give it a fresh output path. For Claude Code, use `--client claude --model claude-sonnet-5`. Keep the model and effort fixed within each pair. The hosted output directory includes raw client events for local inspection.
