# codex-pilot-2: launch handover

Everything is built and smoke-validated. The Phase 2 pilot (20 tasks x 9 arms)
is a real ~$200-260, multi-hour run needing Docker Hub auth, so per Kun's
decision it is NOT launched - this is the ready-to-go command.

## Pre-flight (do these first)

1. `docker login`  (free authenticated tier = 200 pulls/6hr; needed for parallel pulls).
2. Confirm codex auth: `ls ~/.codex/auth.json` (present).
3. Confirm volumes: `docker volume ls | grep -E 'pb-toolkit2|pb-deps-'` (pb-toolkit2 + 7 pb-deps-*).
4. (Optional) free disk check: `df -h /` (want >=120 GB free under runs/).

## Launch the Phase 2 PILOT (20 tasks x 9 arms, stripe mode)

```sh
cd /Users/kunchen/github/kunchenguid/programbench-bench
RUN_NAME=codex-pilot-2-pilot

# Real-time disk watchdog FIRST (catches sub-25-min disk runaways).
PB_DISK_FLOOR_GB=50 nohup ./harness/disk-watchdog.sh > /tmp/${RUN_NAME}-watchdog.log 2>&1 &
echo $! > /tmp/${RUN_NAME}-watchdog.pid

# Stripe pipeline: ONE stripe of 20 tasks through all 9 arms (agents + eval).
# PB_MAX_TASKS=20 caps the task universe to the first 20 (CRITICAL - without it
# the orchestrator runs ALL 201 tasks = the full study, not the pilot).
RUN_NAME=$RUN_NAME \
  PB_MAX_TASKS=20 \
  STRIPE_SIZE=20 \
  PB_PILOT2=1 \
  PB_ARMS="codex-free,codex-lang-c,codex-lang-go,codex-lang-rust,codex-lang-java,codex-lang-js,codex-lang-ts,codex-lang-python,codex-lang-ruby" \
  PB_BASELINE=codex-free \
  PARALLEL=4 \
  PB_DISK_EVICT_GB=100 \
  PB_RUN_TESTS_TIMEOUT_SEC=300 \
  nohup ./harness/run-stripe-pipeline.sh > /tmp/${RUN_NAME}-stripe.log 2>&1 &
echo $! > /tmp/${RUN_NAME}-stripe.pid
```

Note: the pilot is a single 20-task stripe, so each task image is pulled once and
used across all 9 arms (~40 pulls total) - well within the authenticated limit.
Cost projection target: ~20 tasks x 9 arms x ~$1.2/task = ~$216 (refine from the
actual per-task.csv $/task column afterward).

## Monitor

- Orchestrator alive: `cat /tmp/${RUN_NAME}-stripe.pid && ps -p $(cat /tmp/${RUN_NAME}-stripe.pid)`
- Progress: `grep 'STRIPE \[' /tmp/${RUN_NAME}-stripe.log | tail -1` ; `tail -20 /tmp/${RUN_NAME}-stripe.log`
- Rate-limit watch: `grep -ciE '429|toomanyrequests' /tmp/${RUN_NAME}-stripe.log` (any hit = WARN)
- Disk: `df -h /` ; watchdog log `tail /tmp/${RUN_NAME}-watchdog.log`
- Stop watchdog when done: `kill "$(cat /tmp/${RUN_NAME}-watchdog.pid)"`
- (Arm a ~25-min health-check cron per AGENTS.md if running unattended.)

## Score / analyze (auto-run at end of stripe; re-run manually anytime)

```sh
cache/pb-venv/bin/python harness/analyze.py --run codex-pilot-2-pilot \
  --arms codex-free,codex-lang-c,codex-lang-go,codex-lang-rust,codex-lang-java,codex-lang-js,codex-lang-ts,codex-lang-python,codex-lang-ruby
```
Report: per-arm dual metric (mean% + ran%), language distribution, wrapping rate,
Holm-corrected paired comparisons (codex-free vs each mandated). CSV at
`runs/codex-pilot-2-pilot/per-task.csv`.

## After the pilot: the FULL run (Phase 3, 200 x 9)

Same command with `RUN_NAME=codex-pilot-2`, **OMIT `PB_MAX_TASKS`**, keep
`STRIPE_SIZE=20`, keep everything else. ~$2.2-2.6k at K=1.

### REQUIRED before the full run: make it exactly 200 (drop the scaffold fixture)

The task dir has **201** entries; `testorg__calculator.abc1234` (sorted pos 177)
is a scaffold fixture with no published image. Today run-batch drops it from
agents post-slice and analyze drops it (never in the run dir), so RESULTS are
already n=200 per arm - but the stripe orchestrator still COUNTS 201, iterates
the scaffold in its eval/prune loop (a no-op), and emits a ragged trailing
1-task stripe `[200:201]`. To make it a clean 200 (10x20 stripes), apply this
BEFORE launching the full run (NOT while the pilot is running - editing a live
bash script corrupts it):

1. `harness/run-batch.sh`: move the `EXCLUDED_TASKS` filter to BEFORE slicing
   (build `ALL_TASKS` then drop excluded, so `--slice` indexes a 200-list).
2. `harness/run-stripe-pipeline.sh`: after building `TASKS`, drop `EXCLUDED_TASKS`
   (the scaffold) so `TOTAL=200`. Keep both pre-exclude so `--slice` indices stay
   aligned between orchestrator and run-batch.

(Verify after: orchestrator logs "200 tasks ... 10 stripes".) Assert full n=200 per arm
at the end (every arm has 200 `*.eval.json`). The blocklist (tinycc/ditaa/xcp/chroma)
is recorded in the orchestrator and operationally tamed by the watchdog + short
test timeout.

## Validation already done (Phase 0/1, this session)

- pb 1.0.2 + 5 patches (fixed a latent patch-skip bug); 1.0.2 auto-excludes hung tests.
- cleanroom == `:task` eval image; 4/8 langs native, 4 from Ubuntu-native pb-toolkit2.
- Agent smokes on gron: codex-lang-rust 46/100, codex-lang-ruby 73/100 (224 tests,
  zero env false-zeros) - full pipeline proven end-to-end. Evidence in runs/p2smoke/.
- analyze.py dual-metric + language-choice + wrapping + Holm: validated on the smoke.
```
