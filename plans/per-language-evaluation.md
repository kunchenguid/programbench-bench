# Per-language evaluation — execution plan

This document is the handover sheet for the babysitter agent.
Infrastructure is built and smoke-validated; what remains is operational: launch each arm in order, monitor, score, and report.

If you are picking this up cold, read this file end-to-end before running anything.

## Research question

Holding the model constant (OpenAI Codex CLI, gpt-5.5), how much does the choice of implementation language affect ProgramBench outcomes?

We mandate a specific implementation language per arm and compare scores side by side against a free-choice baseline (`codex-vanilla`, already complete: 52.2% mean / 200 tasks).

## Status

Infrastructure complete (smoke-validated 2026-05-19 on `antonmedv__walk.bf802ef`):

| Arm | Smoke pass rate | Notes |
|---|---|---|
| codex-vanilla (baseline) | 75.4% (smoke); 52.2% (full pilot, n=200) | Free language choice; already done |
| codex-lang-ts | 75.1% | npm-offline + tsc/ts-node symlinks |
| codex-lang-js | 74.9% | nodejs from staged .deb |
| codex-lang-python | 73.3% | python3 native + pip wheelhouse |
| codex-lang-go | 72.2% | Go 1.22 toolkit + GOTOOLCHAIN=local |
| codex-lang-c | 61.6% | gcc + dev headers |
| codex-lang-ruby | 59.9% | ruby from staged .debs |
| codex-lang-rust | 59.6% | cargo + vendored crates |
| codex-lang-java | 53.1% | openjdk-17 + maven from staged .debs |

What's in the repo:

- 8 per-language cleanroom images (`pb/clean-lang-{c,python,rust,go,js,ts,ruby,java}`).
- 7 per-language deps volumes (`pb-deps-{python,rust,go,js,ts,ruby,java}`); C uses dev headers baked into its image.
- One toolkit volume (`pb-all-langs-toolkit`, ~1 GB) carrying Go 1.22 + Java/Ruby/Node staged .debs.
- `arms/codex-lang-<X>/orchestration.md` (8 files) + `arms/codex-lang-<X>/compile-prelude.sh` (8 files).
- `harness/run-codex.sh` auto-injects each arm's `compile-prelude.sh` into the submission's `compile.sh` after the agent finishes.
- `harness/score-with-toolkit.py` is the canonical scoring entrypoint; `score-and-report.sh` invokes it; mounts the deps + toolkit volumes into every eval container automatically.
- Local patches to vendored `programbench` make image cleanup robust (`harness/patches/apply-disk-cleanup-patches.sh`).
- `harness/analyze.py` parses codex transcripts: cost via per-1M token pricing for gpt-5.5 ($5/$0.50/$30 input/cached/output), turns via `item.completed` counts, duration via transcript-birthtime → submission-mtime.

## Pilot scope

All 8 language arms run on the **same 200 tasks** as `codex-vanilla`, under the same run name `codex-pilot-1`.
Final analyze pulls all 9 arms (vanilla + 8 lang) and emits paired comparisons against the baseline.

Excluded by `EXCLUDED_TASKS` in `run-batch.sh`:

- `testorg__calculator.abc1234` (synthetic, no real cleanroom image).
- (Note: `alecthomas__chroma.8d04def` has a known `results_read_failed` eval bug — hits all arms equally; neutral to the comparison.)

## Run order

By smoke pass-rate descending — top arms first so any infrastructure regression surfaces on a language we know should work.

1. **codex-lang-ts** (dry-run; fully sequential; sanity-check before continuing)
2. codex-lang-js
3. codex-lang-python
4. codex-lang-go
5. codex-lang-c
6. codex-lang-ruby
7. codex-lang-rust
8. codex-lang-java

After the TS dry-run completes (agents + scoring) and the babysitter reviews the result, arms 2-8 run in **pipelined** mode: arm N+1's agents start as soon as arm N's agents finish, in parallel with arm N's scoring.

## Per-arm runbook

### Phase 1 — agent runs

```sh
cd /Users/kunchen/github/kunchenguid/programbench-bench
RUN_NAME=codex-pilot-1
ARM=codex-lang-ts   # change per arm

nohup ./harness/run-batch.sh \
  --arms $ARM \
  --slice 0:201 \
  --run-name $RUN_NAME \
  --parallel 4 \
  > /tmp/${RUN_NAME}-${ARM}.log 2>&1 &
echo $! > /tmp/${RUN_NAME}-${ARM}.pid
```

Expected wall time: ~25-30 hours per arm at parallel=4.
Expected API cost: ~$200 per arm (based on codex-vanilla's $1.03/task average).

### Phase 2 — scoring

Triggered when the agent batch finishes (no sentinels remaining, exit line `[batch] done` in the log).

```sh
nohup ./harness/score-and-report.sh \
  --run $RUN_NAME \
  --arms $ARM \
  --workers 4 --branch-workers 2 \
  > /tmp/${RUN_NAME}-${ARM}-score.log 2>&1 &
```

Expected wall time: ~13-14 hours per arm.
Throughput observed in baseline scoring: ~15 tasks/hour.

### Pipelined mode (arms 2-8)

After agent batch for arm N finishes, immediately:

1. Launch scoring for arm N (Phase 2 above).
2. Launch agent batch for arm N+1 (Phase 1 above).

Both run concurrently. The 14-core host has enough headroom: agents are I/O-bound on the LLM call; eval is CPU-bound (pytest-xdist). Load avg peaks around 20-25 during overlap — busy but not thrashing.

### Health monitor

For every active agent batch, arm a periodic health-check per CLAUDE.md's pattern.
Use `CronCreate` with an off-herd minute pattern (e.g. `7,32,57 * * * *`) and `durable: true` so it survives across sessions.

Each fire should report:

1. Batch alive — `ps -p $(cat /tmp/<run>-<arm>.pid)`.
2. Progress — `tail -n 5 /tmp/<run>-<arm>.log`.
3. System — `top -l 1 -n 0 | head` (flag load avg > 24 or memory pressure).
4. Disk — `df -h /` (flag if under 30 GB free; M3 patches should keep this steady).
5. Docker — eval container count + cleanroom container count.

### Decision point — TS dry-run review

After TS finishes both phases:

- Read `runs/codex-pilot-1/codex-lang-ts/per-task.csv` (will be regenerated by score-and-report).
- Compare TS mean to `codex-vanilla` mean (52.2%); expect TS in the 45-55% range based on smoke ratio.
- Spot-check 3-5 task transcripts for sanity (no systematic failures from the prelude).
- If anything looks broken (mean way below 40%, lots of `compile_failed`, eval results_read_failed clustering), pause and investigate before launching arms 2-8.
- If TS looks healthy, proceed to pipelined mode.

## Final analysis

After all 8 arms finish scoring:

```sh
./harness/analyze.py \
  --run codex-pilot-1 \
  --arms codex-vanilla,codex-lang-ts,codex-lang-js,codex-lang-python,codex-lang-go,codex-lang-c,codex-lang-ruby,codex-lang-rust,codex-lang-java
```

Outputs:

- `runs/codex-pilot-1/summary.txt` — per-arm table, score distribution, paired comparisons of each lang vs vanilla.
- `runs/codex-pilot-1/per-task.csv` — every (arm, task) row with pct/cost/turns/duration.

Cost from the CSV: `awk -F, 'NR>1{s+=$7}END{print "$"s}' runs/codex-pilot-1/per-task.csv`.

## Time + cost forecast

- TS dry-run (sequential): ~40 hr = 1.7 days.
- Arms 2-8 pipelined: ~7.9 days (bottleneck = 7 × 25 hr agent phase + 14 hr tail eval).
- **Total wall time: ~9.6 days.**
- **API cost: ~$1,650 total** (8 × ~$200).
- Disk peak: should stay under 30 GB thanks to programbench-patch M3.

## Known operational gotchas

- **`chroma` task**: eval pipeline bug `results_read_failed`; both arms score 0. Neutral to comparison.
- **Reboots are safe**: durable submissions on disk are all the resume logic needs.
- **Anthropic quota** doesn't apply (codex/OpenAI), but OpenAI usage limit might. Check usage every ~$500 spent.
- If scoring stalls (eval.json count not increasing for >2 hr on an active run), inspect long-running task containers via `docker ps`. Walk-class tasks legitimately take 30-45 min; chroma can hang indefinitely. SIGKILL stuck containers and let programbench retry.
- If disk creeps despite M3 patches: `docker system prune -af --filter "until=2h"` is safe while runs are active (it won't touch in-use images).
- `harness/patches/apply-disk-cleanup-patches.sh` is idempotent; re-run if `cache/pb-venv/` is ever recreated.

## Files of interest

- Submission tarballs: `runs/codex-pilot-1/<arm>/<task>/submission.tar.gz`.
- Transcripts: `logs/codex-pilot-1/<arm>/<task>/transcript.jsonl` (codex JSON-lines format).
- Per-task batch logs: `logs/codex-pilot-1/_batch/<arm>__<task>.log`.
- Batch driver logs: `/tmp/codex-pilot-1-<arm>.log` (PID written to sibling `.pid`).
- Scoring logs: `/tmp/codex-pilot-1-<arm>-score.log`.
- Cleanroom images: pulled per task as `programbench/<task>:task` (~3 GB each, auto-removed after scoring via M3 patch).
- Lang base images: `pb/clean-lang-<X>:latest`, ~150-380 MB each, persistent.
- Toolkit volume: `pb-all-langs-toolkit` (~1 GB, persistent).
- Deps volumes: `pb-deps-{python,rust,go,js,ts,ruby,java}` (45 MB - 1.4 GB each, persistent).

## What I'd want to read next, if I were the babysitter

1. `CLAUDE.md` (repo root) — overall harness conventions and the launch/monitor pattern.
2. `arms/codex-lang-<X>/orchestration.md` for the active arm — what each agent is instructed to do.
3. `arms/codex-lang-<X>/compile-prelude.sh` for the active arm — the env wiring the harness injects.
4. `harness/run-codex.sh` — single-task runner, especially the `LANG_OVERLAY` block (lines ~107-180) and the prelude-injection block at the tail.
5. `harness/score-with-toolkit.py` — eval wrapper; understands which volumes to mount.
6. `harness/analyze.py` — final report generator; codex-aware as of 2026-05-19.
