# AGENTS.md

Notes for any agent (Claude or otherwise) working in this repo.
Read this file before taking actions that change long-running state.

## What this repo is

Harness comparison study on ProgramBench, holding the model constant (Claude Opus 4.7) and varying the agent harness across arms (`vanilla`, `gstack-curated`).
See `README.md` for the experimental framing.
The eval is expensive in API quota and wall time, so operational mistakes are costly.

The active work is **`codex-pilot-2`** (OpenAI gpt-5.5): a clean-restart per-language study (`codex-free` + 8 mandated arms) on a de-confounded topology where the cleanroom IS the `:task` eval image. See `plans/codex-pilot-2.md` (design), `plans/codex-pilot-2-progress.md` (build state), `plans/codex-pilot-2-LAUNCH.md` (run command), and `[memory:project_codex-pilot-2]`.

The prior `codex-pilot-1` study is COMPLETE and its raw run data has been reclaimed; its results survive in `plans/codex-pilot-1-results/` (per-task.csv + summary.txt) and `[memory:project_codex-pilot-1-env-confound]` (the confound that pilot-2 fixes at the source).

## Long-running evaluations: always supervise

Eval batches run detached via `nohup ./harness/run-batch.sh ... &`.
Throughput: at parallel=4 (the default) ~47 tasks/hr (a 200-task arm in ~3.7 h, observed 2026-05-26); at parallel=1 only ~2.3 tasks/hr (~4 days for a 402-pair pilot).
Because the agent's REPL session is the only thing watching the batch, **you must arm a periodic health monitor whenever you launch or resume a run** (and for any large *eval*, also a real-time disk watchdog - see the disk-runaway gotcha).

### How to launch (or resume) a batch

The same command kicks off a fresh run and resumes a paused one - resume logic is driven by what's on disk, not by flags.
Pick a `<run-name>` (e.g. `pilot-2`); it determines the paths under `runs/`, `logs/`, and `/tmp/`.

```sh
cd /Users/kunchen/github/kunchenguid/programbench-bench
RUN_NAME=<run-name>

nohup ./harness/run-batch.sh \
  --arms vanilla,gstack-curated \
  --slice 0:201 \
  --run-name "$RUN_NAME" \
  --parallel 4 \
  > "/tmp/${RUN_NAME}-full.log" 2>&1 &
echo $! > "/tmp/${RUN_NAME}-full.pid"
```

**`--parallel 4` is the default (2026-05-26).** It REQUIRES being `docker login`'d (free authenticated = 200 pulls/6hr); anonymous (100/6hr) will hit a 429 pull-cascade and silently false-fail tasks. Drop to `--parallel 1` only when not logged in or deliberately rate-limiting cost/resources. At parallel=4 the codex-vanilla-clean 200-task run finished in ~3.7 h with 0 failures.

Resume semantics: any task with a `submission.tar.gz` >= 200 bytes is skipped on the next run.
Below 200 bytes (the 29-byte empty-tar sentinel from killed tasks) is treated as not-done and retried.

### Required: arm a periodic health check after launching a batch

Right after kicking off `run-batch.sh`, schedule a cron job firing roughly every 25 minutes.
Use an off-herd minute pattern such as `7,32,57 * * * *` rather than `*/25 * * * *` (which lands on :00).

Each fire should run these checks against the current `<run-name>` and report a 4-6 line `OK / WARN / FAIL` status:

1. **Batch alive** — `cat /tmp/<run-name>-full.pid && ps -p $(cat /tmp/<run-name>-full.pid) -o pid,etime,pcpu,pmem,command`.
   If the process is dead, surface loudly and **do not auto-restart** - ask the user.
2. **Progress** — `tail -n 5 /tmp/<run-name>-full.log` to see the latest task and running done/failed/remaining counts.
3. **System resources** — `top -l 1 -n 0 | head -n 10` plus `df -h /`.
   Flag memory pressure, load avg > number of cores, or disk < 10% free under `runs/`.
4. **Docker** — `docker ps --format 'table {{.Names}}\t{{.Status}}' | head -n 10`.
   At parallel=4 expect up to ~4 task container-sets live at once; also `grep -ciE '429|toomanyrequests' /tmp/<run-name>-full.log` - any hit means the run is rate-limited (not logged in, or limit exceeded) and tasks are false-failing.

### Caveats to tell the user when arming the monitor

- `CronCreate` defaults to session-only; if the Claude session closes, the monitor dies (the nohup'd batch keeps running, just unsupervised). Offer `durable: true` if they want it to survive across sessions.
- Recurring cron jobs auto-expire after 7 days.
  A parallel=1 pilot needs ~4 days, so one arming usually covers it - re-arm if it runs long.

## Tunables

In `harness/run.sh` (all overridable via env vars):

| Var                      | Default | Meaning                                                                 |
| ------------------------ | ------- | ----------------------------------------------------------------------- |
| `PB_BUDGET_USD`          | 50      | API budget per task                                                     |
| `PB_TIMEOUT_SEC`         | 7200    | Hard kill at 120 min                                                    |
| `PB_IDLE_KILL_SEC`       | 180     | Kill if idle 3 min after a result                                       |
| `PB_PRERESULT_IDLE_SEC`  | 900     | Kill if idle 15 min, no result yet                                      |
| `PB_AUTO_COMPACT_WINDOW` | 400000  | `claude -p` auto-compacts at this token cap (saves quota on long tasks) |

## Scoring a finished run

```sh
./harness/score-and-report.sh --run <run-name> --arms vanilla,gstack-curated
```

Writes the report to stdout and `runs/<run-name>/per-task.csv`.

For multi-arm runs (e.g. codex-pilot-1's 10 arms), the report comes from `harness/analyze.py --run <run-name> --arms <a,b,...>` (pure file reader over `*.eval.json` + transcripts, no Docker). It emits per-arm summary, paired comparisons vs the first arm, and the per-task CSV. The eval entrypoint is `score-with-toolkit.py eval <run-dir>` (mounts deps+toolkit volumes); useful flags: `--filter '<regex>'` (full-match), `--force` (re-eval already-scored), `--slice A:B`.

**Primary success metric: `solve@75` (Kun's preference, updated 2026-06-01; supersedes the earlier solve@90 primary).** Report, as the primary quality metric alongside mean test pass-rate, the **fraction of tasks that passed >= 75% of their (non-ignored) tests** - i.e. the count of tasks whose per-task test pass-rate >= 0.75, divided by n. Rationale: a near-complete pass is the thing that actually matters and mean% over-rewards partial credit; solve@75 captures "the task is basically solved" without being as statistically thin as the stricter cuts. When ranking or comparing arms, **rank by `solve@75` first and use mean test pass-rate as the tiebreaker.** Keep reporting `solve@60`, `solve@90`, and `solve@95` as additional cuts (solve@90/95 are statistically thin - 1-7 tasks/arm on n=200, so the codex-pilot-2 investigation found their mid-table order is bootstrap noise; report them but do NOT rank on them). Keep reporting mean% and ran% too (mean% is still the headline continuous metric and feeds the paired Wilcoxon/Holm tests; ran% is the dual-metric cascade check). NOTE the thresholds can disagree on the *winner* (in codex-pilot-2, mean%/solve@60 favor codex-free but solve@75 favors mandated rust) - when they diverge, report it explicitly rather than cherry-picking the flattering cut. The cuts are on the same non-ignored-test denominator as mean% (apply the `ignored_tests` filter), and the task denominator stays full n=200 (see below). `analyze.py` emits the solve@X columns in the per-arm summary.

**Wall-time caveat:** analyze.py's `min` column is the **median** per-task duration (patched 2026-05-25), dropping spans >120 min. Reason: duration is derived from transcript-birthtime → submission-mtime, which is corrupted (spans the inter-session gap) for tasks re-run in a later session - 66 tasks (3.7%, all ruby/rust/java) in codex-pilot-1. Cost (`$/task`) and `turns` are token-derived and unaffected. Don't trust per-task or summed wall time for retried arms; the median is the robust per-task estimate.

**Denominator convention: report n=193 for codex-pilot-2 (7 structurally-broken tasks blocklisted).** Updated 2026-06-02 (Kun's call), SUPERSEDING the earlier "always n=200" rule for this study. The reported denominator drops all 7 structurally-broken tasks - the 4 disk-runaways (`tinycc__tinycc`, `stathissideris__ditaa`, `tarka__xcp`, `alecthomas__chroma`) PLUS the 3 structurally-broken-and-confirmed (`sharkdp__hyperfine`, `eliukblau__pixterm`, `ggreer__the_silver_searcher`). These 3 were confirmed structural (not a timeout artifact) in the 6h re-eval: their `not_run` is identical across every arm AND unchanged between the 300s and 6h eval, so it's a defect in the ProgramBench task (the test branch hangs/errors regardless of submission), not a capability or timeout signal. All 7 are now treated consistently: a single `REPORT_BLOCKLIST` in `analyze.py` drops them from the denominator and all metrics, AND they are excluded from eval (60s cap in the `_apply_patches.py` cap map for the 3 new ones; `--filter` negative-lookahead built by `harness/reeval.sh`, which derives the skip-list from this same `REPORT_BLOCKLIST` so the two never drift). `n=193` is the only denominator to report; do not present the old `n=200` cut.

Rationale for the supersede: the old n=200 rule was reasoned only about the 4 disk-runaways (which score ~0, so keeping them was harmless and avoided a confusing second denominator). The 6h re-eval surfaced 3 more broken tasks where `not_run` *does* depress scores nonzero-ly (pixterm/silver_searcher have a runnable part), so leaving them in would misreport; Kun chose to blocklist all 7 broken tasks consistently rather than mix conventions.

## Reporting methodology and scientific rigor

These are the standing reporting practices for any harness-comparison write-up in this repo (the language study, the TDD study, the claude study).
They are how we keep the conclusions honest; reuse them, do not re-derive them per post.

**Label every result confirmatory or exploratory, and never let a post-hoc analysis borrow pre-registered credibility.**
Confirmatory = the metric/test was fixed before results were seen: mean test pass-rate (the headline continuous metric), solve@75 (the pre-registered primary cut, 2026-06-01), ran%, and the paired Wilcoxon signed-rank with Holm correction. These carry their p-values at face value.
Exploratory = the analysis was shaped by the data after seeing it: the difficulty stratification, the difficulty x arm interaction slope, the stochastic-dominance / threshold sweep, leave-one-out de-biasing. These are hypothesis-generating; their p-values are NOT corrected for the analytic choices made after seeing the data (the "garden of forking paths"), so they are suggestive, not established, and need pre-registration + replication before being treated as confirmed. Tag a method exploratory whenever the data shaped it, however well-motivated.

**Communicate with mean% stratified by task difficulty, but report it alongside (not in place of) the confirmatory metrics.**
A single pooled mean weights every task equally and conflates doing well on trivial tasks with making progress on hard ones; with bounded [0,100] scores and a wide difficulty spread, easy tasks saturate near 100 and hard near 0, so a pooled mean mixes signal-free tail mass with the band where arms actually separate, and it cannot represent a difficulty x arm interaction even in principle. So lead with the difficulty breakdown - but it is an exploratory lens, not confirmatory.
Difficulty = cross-arm mean pass-rate per task (low = hard), split into equal-count terciles. For any per-arm within-stratum claim use a LEAVE-ONE-OUT difficulty (each arm binned by difficulty computed from the *other* arms) so an arm cannot inflate its own bin; for a pairwise interaction test exclude *both* arms from the difficulty score. Flag that this is arm-defined (endogenous) difficulty and confirm key crossovers under at least one exogenous proxy (test count, LOC, repo age).

**Make better/worse claims from threshold-free inference, not cutoff rankings.**
Use the paired Wilcoxon signed-rank on the continuous per-task pass-rate (tasks matched across arms), Holm-corrected across the comparison family, reporting raw and adjusted p. Report effect sizes and uncertainty (median paired delta, win/lose/tie counts, interaction slope + p) so a "53.1 vs 52.1" gap is read as within noise. When metrics disagree on the winner (solve@60 vs solve@75 vs mean%), report the disagreement and explain it via the crossing distributions - never present only the flattering cut.

**solve@90/95 are dropped from ranking (report only as a thin tail, if at all).**
Empirically on this data: 0 of 28 arm-pairs first-order stochastically dominate (all 28 distributions cross), so no threshold-independent ranking exists and hunting for the "right" cutoff is the wrong activity. Climbing the cutoff strictly degrades the metric - discrimination falls (9.3 pts spread @75 -> 1.6 @95) and the smallest arm's task count collapses (15 @75 -> 1-2 @90+), so each 0.5-pt step is ~1 task of bootstrap noise. solve@90 is also insensitive (the 6h re-eval moved mean% +3-7 pts everywhere but left solve@90 essentially unchanged). Rank by solve@75, tiebreak on mean%; report solve@60/90/95 as supplementary cuts only.

**Choose methodology a priori; never justify a method by the result it produced (anti-HARKing).**
The reporting choices above are justified by properties of the task set and the metrics knowable before any arm's results (wide difficulty spread, ceiling/floor compression, threshold-arbitrariness), not by the findings they later yielded. A method that only looks good because it broke a tie in a direction we like is a result dressed as a method. The test to apply to every choice: *would this method read the same way if the results had come out the other way?* If not, it is post-hoc - label it exploratory. (The solve@90 demotion is legitimate despite using post-rerun data because it rests on arm-agnostic reliability properties - thinness, threshold-sensitivity, distribution crossing - not on which arm it crowns; the thinness concern itself was raised a priori on 2026-06-01.)

Deferred rigor upgrades (not yet done): a pooled mixed-model interaction (`pass_rate ~ arm * difficulty + (1|task)`) for an omnibus test with more power than the per-pair slopes (statsmodels is not in `cache/pb-venv`; add a scratch venv or use a permutation test); the exogenous difficulty-proxy robustness check; and pre-registering + replicating any crossover (e.g. the free-vs-rust difficulty interaction, which is only marginally significant post-de-pollution) before treating it as established. Consider baking the threshold-free suite (stochastic-dominance check, Wilcoxon/Holm, difficulty stratification, interaction slope) into `analyze.py` as standing output.

## Multi-arm pipelines: use stripe mode, not arm-major

For experiments that compare many arms over the same task set (e.g. the per-language-evaluation pipeline with 8 arms × 200 tasks), the naive arm-major schedule ("run all 200 tasks of arm 1, then all 200 of arm 2, ...") is wrong.
Each arm re-pulls the same `programbench/<task>:task_cleanroom` and `programbench/<task>:task` images, multiplying Docker Hub pulls by the arm count.
With anonymous (100/6hr) or authenticated free (200/6hr) limits, you will hit 429s mid-pipeline and tasks will silently fail with `RuntimeError: Failed to start container: Unable to find image` or batch-driver `FAIL` markers from `docker pull` errors.

We learned this the hard way on `codex-pilot-1` (47 JS agent failures + 149 false-zero TS scores all from rate-limit cascade).

### Stripe orchestrator

`harness/run-stripe-pipeline.sh` processes a small batch of tasks through ALL arms (agents + eval) before pruning, so each task image is pulled at most once per pipeline.

```sh
cd /Users/kunchen/github/kunchenguid/programbench-bench
RUN_NAME=codex-pilot-1 \
  STRIPE_SIZE=10 \
  PB_DISK_EVICT_GB=100 \
  nohup ./harness/run-stripe-pipeline.sh > /tmp/${RUN_NAME}-stripe.log 2>&1 &
echo $! > /tmp/${RUN_NAME}-stripe.pid
```

The orchestrator is idempotent.
Per stripe of N tasks:

1. Run agents for each arm on the stripe (existing resume-skip semantics handle partial state).
2. Delete any `<task>.eval.json` that contains `RuntimeError` (a rate-limit false-zero from a prior session) so the next step re-evaluates it.
3. Run `programbench eval --slice` for each arm on the stripe.
4. Prune `programbench/<task>:*` images for the stripe's tasks.

After all stripes finish, the orchestrator runs `harness/analyze.py` across all arms.

### Disk and pull math

| Knob | Effect |
| ---- | ------ |
| `STRIPE_SIZE` (default 10) | Lower = less peak disk per stripe but more orchestration overhead. 10 → ~60 GB peak per stripe (10 tasks × ~6 GB cleanroom+eval). |
| `PB_DISK_EVICT_GB` (**code default 30** - set it explicitly!) | Threshold for demand-based eviction inside `programbench eval`. Below this much free disk, the post-eval base-image cleanup fires; above it, images stay cached for the next arm. The 30 GB code default is dangerously low for the per-language pipeline - set `160` (the stripe launch above passes a value; **direct `score-with-toolkit.py eval` runs do NOT, so they fall back to 30** and let disk drift to near-empty before reclaiming - the cause of one wedge this run). |
| `PARALLEL` (default 4) | Per-arm agent parallelism (passed to `run-batch.sh`). |
| `WORKERS` (default 4) / `BRANCH_WORKERS` (default 2) | `programbench eval` parallelism (per eval). |

**1-eval concurrency cap (2026-05-27):** `run-stripe-pipeline.sh` waits on the prior arm's eval before launching the next, so at most ONE background eval runs at a time → total eval workers = `WORKERS` (not `WORKERS × arms-still-evaluating`).
Before this, each arm's eval was fired into the background and only joined at end-of-stripe, so evals stacked and oversubscribed the host (codex-pilot-2 hit load ~63 on a 14-core box with 3 evals × 4 workers).
The cap keeps the eval‖next-arm-agents overlap but stops the pile-up.
Note the last-element read uses `${eval_pids[${#eval_pids[@]}-1]}` (portable) - `/bin/bash` is 3.2 and has no `[-1]`, even though `#!/usr/bin/env bash` resolves to a newer bash on PATH.

Total pulls in a full N=10, 200-task, 8-arm run: ~400 (1 cleanroom + 1 eval image per task, used across all 8 arms).
Compare to arm-major: ~3200 pulls (each arm pulls each image fresh).

### Rate-limit and disk patches that make this work

**Skip-if-local guard** in `harness/run.sh:99` and `harness/run-codex.sh:111` skips `docker pull` when the image is already cached locally (lives in the harness scripts, in the repo - survives venv recreation). Without it, even cache hits hit Docker Hub for manifest checks, counting against the rate limit.

The remaining patches modify the **vendored programbench** and are all defined in `harness/patches/_apply_patches.py` (the single source of truth). As of 2026-05-25 there are **5**:

1. `container.py` `remove_image()` - retries on transient docker busy/lock, logs on permanent failure (stops compiled-image leaks).
2. `container.py` `execute()` - in-container SIGKILL sweep on TimeoutExpired (kills orphaned test processes left when host-side `docker exec` times out).
3. `eval/eval.py` finally block - demand-based eviction of the base `programbench/<task>:task` image (`PB_DISK_EVICT_GB`), instead of eager rmi-after-eval.
4. `eval/eval.py` `run_tests` - per-instance timeout map + lowered 900s default (vs stock 3600s); fast-fails to `results_read_failed` on timeout.
5. `container.py` `_stream_tar_in()` - strips macOS AppleDouble `._*` files after extraction (see the java false-zero gotcha below).

**Re-run `harness/patches/apply-disk-cleanup-patches.sh` whenever `cache/pb-venv/` is recreated** - it is idempotent and applies all 5. Verify with a second run (should print `[skip]` for every patch). Each patch carries a `LOCAL PATCH (programbench-bench)` marker in the vendored file for traceability. NOTE: the only thing in the repo that is NOT auto-restored by this script is the `harness/analyze.py` median-duration logic - but analyze.py is a repo file, not vendored, so it survives venv recreation on its own.

### Authentication

`docker login` to a Docker Hub account before launching a multi-arm pipeline.
Free authenticated tier (200/6hr) is enough with stripe mode.
Anonymous (100/6hr) is not, even with stripes - we still need ~20 pulls per stripe and stripes complete in ~2 hr.

### Health monitor in stripe mode

The monitor cron should track:

- `/tmp/<run-name>-stripe.pid` (the orchestrator), not per-arm PIDs.
- Current stripe (`grep "STRIPE \[" /tmp/<run-name>-stripe.log | tail -1`).
- Rate-limit watch: `grep -c "429\|toomanyrequests" /tmp/<run-name>-stripe.log` - any hit is a WARN.
- Disk free + cached `programbench/*` image count.

`WARN` if no log activity in 30 min or stripe progress stalls.
`FAIL` if orchestrator dies before `===== ALL STRIPES DONE =====` appears.

**Lead every health-check report with a per-arm overall-progress table, BEFORE the system-health table** (Kun's preference, 2026-05-27).
For each arm show submissions and evaluated counts (each out of the per-arm task total, e.g. /200), with a bold TOTAL row summing both columns (e.g. /1800 for 9 arms).
Build it from disk:
`for a in <arm1> <arm2> ...; do s=$(ls runs/<run-name>/$a/*/submission.tar.gz 2>/dev/null | wc -l); e=$(ls runs/<run-name>/$a/*/*.eval.json 2>/dev/null | wc -l); echo "$a sub=$s eval=$e"; done`.

**Also include each arm's current `solve@75` in that progress table** (Kun's preference, updated 2026-06-01) - the primary quality metric (% of tasks passing >= 75% of non-ignored tests; see "Scoring a finished run"). It's a per-arm rate so leave it blank on the TOTAL row, and flag it as partial/directional until the run finishes. Get it read-only (analyze.py never touches the orchestrator - safe mid-run):
`cache/pb-venv/bin/python harness/analyze.py --run <run-name> --arms <a,b,...> 2>/dev/null | sed -n '/Per-arm summary/,/Score distribution/p' | awk 'NF>=7 && $1 ~ /^codex-/ {printf "%s solve@75=%s mean%%=%s\n", $1, $3, $7}'` (summary cols after the 2026-06-01 reorder: $3=solve@75, $4=solve@60, $5=solve@90, $6=solve@95, $7=mean%).
The system-health (OK/WARN/FAIL) table comes after it.

### When stripe mode is overkill

Single-arm runs (e.g. just `vanilla`, or just `codex-vanilla` for a one-off pilot) don't need stripe mode.
Use `run-batch.sh` directly with the arm-major flow above.
Stripe mode pays for itself starting at ~3 arms over the same task set.

## Things to never do without asking

- Restart a batch that has died mid-run.
  Ask the user first - there may be a quota, billing, or resource reason it died.
- Raise `--parallel` above the default 4, OR run parallel>1 while NOT `docker login`'d.
  parallel=4 is the approved default (needs Docker Hub auth); going higher, or parallel>1 anonymous, risks the 429 pull-cascade - ask first.
- Delete files under `runs/<run-name>/` or `logs/<run-name>/`.
  These are the durable submissions and transcripts the score script reads.
- Force-kill the batch process to "clean up" - prefer letting in-flight tasks finish, since killed tasks waste API spend.

**Explicitly allowed without asking:** restarting the **Docker daemon** (Docker Desktop) to recover from a disk-runaway wedge, including force-killing the docker processes and pruning cached task images to reclaim Docker.raw. This is distinct from restarting the *batch/orchestrator* (still ask). Docker restart loses no durable data - see "Recovering from a disk-runaway wedge". When a runaway is actively filling the disk, also allowed: `docker rm -f` the running eval containers to halt it.

## codex-vanilla arm (prototype)

The `codex-vanilla` arm runs OpenAI Codex CLI (`@openai/codex`) against
the same cleanroom topology, holding "frontier reasoning model" roughly
constant.
See `SMOKE.md` at the repo root for status, known limitations, and the
first-time smoke checklist.

- Model: `gpt-5.5` (literal id accepted by Codex CLI 0.130.0).
- Auth: host's `~/.codex/auth.json` is bind-mounted read-only into the
  agent container at `/home/node/.codex/auth.json`.
  Run `codex login` once on the host before launching.
- Per-task runner: `harness/run-codex.sh` (sibling of `run.sh`).
- Batch routing: arm names prefixed with `codex-` are dispatched to
  `run-codex.sh` automatically by `run-batch.sh`.
- Proxy: new whitelist entries cover `api.openai.com`, `auth.openai.com`,
  `chatgpt.com`, and `ab.chatgpt.com`.
  See `harness/sandbox/filter`.
- Launch (single task):
  `./harness/run-codex.sh --arm codex-vanilla --task <id> --run-name codex-smoke --budget 1`
- Launch (batch): same as Claude arms; just pass `--arms codex-vanilla`.

Known caveats specific to this arm:

- Codex CLI 0.130.0 has no `--max-budget-usd` / `--max-turns` flag.
  `--budget` to `run-codex.sh` is informational.
  Wall-clock watchdog is the only ceiling.
- The watchdog uses the pre-result idle threshold uniformly (Codex's
  event stream doesn't have a `type:"result"` marker the way Claude
  does).
- `auth.json` is mounted read-only; any token refresh write-back will
  fail silently.
  In-memory refreshed tokens still work for the run's duration.

## Known gotchas

- **Disk-runaway tasks — `tinycc__tinycc.9b8765d`, `stathissideris__ditaa.f2286c4`, `tarka__xcp.5e5b448`** (plus the original `alecthomas__chroma.8d04def`): their test suites create recursive directory trees (`same_dir/same_dir/...`) that fill the VM disk (Docker.raw) to its cap and **wedge the Docker daemon**. The 900s timeout + in-container SIGKILL patches DO NOT save you - the SIGKILL teardown needs a responsive daemon, which disk-full denies. **Blocklist these before evaluating their stripe** (stripe 8 `[160:180]` for tinycc/ditaa/xcp). They score ~0 for every arm (broken test, not a capability signal), so excluding them is neutral to the comparison. Documented in `[memory:stripe8-disk-runaway]`.
  - **The named list is NOT exhaustive.** A 4th, previously-unknown runaway in the `codex-vanilla-clean` tail filled Docker.raw and crashed the host on 2026-05-26 (host hit 315 MiB free; daemon wedged). The name-allowlist guard reported "clean" because the task wasn't on it, and the 25-min health-check cron is blind to a fill that completes in <25 min.
  - **Always run a real-time disk watchdog for any large eval**, not just the cron. The proven pattern (`harness/resume-vc-tail.sh`): a background loop checking `df -k /` every ~10s that `docker rm -f $(docker ps -q)` + `docker image prune -f` the moment free disk drops below a floor (~50 GB) - long before the ~0-free wedge. It caught a 2nd runaway cleanly (no crash) on the same run. (NOTE: `timeout` is not a macOS builtin - use `gtimeout` or a `perl -e 'alarm N; exec ...'` wrapper, or a plain `sleep` loop; a bare `timeout docker ...` will exit "command not found" and look like a false wedge.)
  - **A short per-test timeout incidentally tames runaways.** Running the eval at `PB_RUN_TESTS_TIMEOUT_SEC=120 --branch-retries 0` killed the runaway's branches before they ballooned, so a `workers=2`/`-b 3` pass over the tail completed with zero watchdog trips.
- **chroma** (`alecthomas__chroma.8d04def`): eval pipeline times out reading results (`results_read_failed`) regardless of submission; scores 0 for all arms - neutral.
- **macOS AppleDouble false-zero (java)**: `run-codex.sh` tars submissions on the macOS host with AppleDouble enabled, so each file gets a hidden `._*` resource-fork companion (macOS `tar -tzf` hides them; `python -c "import tarfile..."` reveals them). The Linux eval container materializes `._Main.java`, and java's `find -name '*.java' | javac` compiles the binary file → `compile_failed` for the *whole java arm* (other langs' builds ignore `._*`). Fixed by patch #5 (strips `._*` at extraction). Permanent fix TODO: `COPYFILE_DISABLE=1` when run-codex.sh tars. If java suddenly shows ~1% compile, suspect this. Documented in `[memory:java-appledouble-falsezero]`.
- **cleanroom-vs-eval env mismatch (the per-language false-zero class).** Mandated `codex-lang-*` arms BUILD in `pb/clean-lang-<X>` (full toolchain) but `compile.sh` RE-RUNS at eval time inside the **upstream task image**, which lacks the mandated language's build env → systematic false-zeros (C missing dev headers, ruby missing libyaml, python wheel/venv/version skew). The per-arm `arms/codex-lang-<X>/compile-prelude.sh` dpkg-installs the missing bits from staged debs at eval. **The eval-container base is Ubuntu 22.04 (python 3.10), NOT Debian** - any staged `.deb` MUST come from `ubuntu:22.04`; Debian-12 debs force-installed over Ubuntu's libs (libssl/libicu/...) corrupt the container's python and break pytest (all tests `not_run`, looks like a fix that made things worse). Staged eval-env debs live in `pb-all-langs-toolkit` at `/opt/all-langs/debs/{cdev (C -dev headers+pkg-config), pyvenv (python3.10-venv)}`; python cp310 wheels were added to `pb-deps-python`. Documented in `[memory:project_codex-pilot-1-env-confound]`.
  - **B-fix (2026-05-26): the python version-skew sub-class is now fixed at the SOURCE, not papered over at eval.**
    The cleanroom python is pinned to CPython 3.10 to match the eval container (Ubuntu 22.04 = 3.10), via a multi-stage `COPY --from=python:3.10-slim-bookworm` in BOTH `harness/sandbox/Dockerfile.clean-lang-python` AND `Dockerfile.clean-lang-all` (python:3.10 is also bookworm, so its ABI matches `pb/clean-lang-base` - no base rebuild needed).
    The agent now develops on the same interpreter that scores it, so it no longer reaches for 3.11-only stdlib (`tomllib`) that vanished at eval on 3.10; `arms/codex-lang-python/orchestration.md` was corrected from "Python (3.11)" to "(3.10)".
    The eval-side band-aids in `compile-prelude.sh` (pyvenv deb + cp310 wheels) STAY - the eval image still ships neither.
    Both python-bearing cleanrooms were moved together ON PURPOSE: `clean-lang-all` (the codex-vanilla-clean free-choice baseline) also inherited debian-12/3.11, so fixing only the mandated arm would hand it an eval-matched interpreter VC lacks - a new asymmetry in the very M2 (same-language python-vs-python) comparison. Keep them symmetric.
    BEFORE any re-run: `run-codex.sh` only builds a cleanroom image IF MISSING - it does NOT rebuild on a Dockerfile change - so you MUST manually rebuild `pb/clean-lang-python:latest` and `pb/clean-lang-all:latest`, or the run silently uses the cached 3.11 images. A fair re-run therefore must re-run VC too, not python-only.
    Durable generalization (deferred, for the next study): build `clean-lang-base` FROM `ubuntu:22.04` so EVERY cleanroom matches the eval OS and the whole class (C dev headers, ruby libyaml, python version) dies at the root; not done now because it shifts the other 6 arms' toolchains (ruby 3.1->3.0 + the hardcoded `GEM_PATH=.../3.1.0`, gcc/openjdk versions) and would force re-running all arms.
- **The compile-prelude is baked into `submission.tar.gz` at AGENT-run time, not eval time.** So fixing an arm's `compile-prelude.sh` does NOT affect already-built submissions - you must re-inject it with `harness/reinject-prelude.py <arm> --all` (rewrites the block between the `# ===== compile-prelude` markers, preserving the agent's original `compile.sh`), then delete the stale `*.eval.json` and re-eval.
- **`eval <arm-dir>` re-runs any instance with incomplete/errored branches**, only skipping *fully* complete ones (so a run with many timeout/`results_read_failed` branches redoes a lot). Scope re-evals with `--filter '(t1|t2|...)'` (full-match regex, escape the `.`) to hit exactly the tasks you mean. After a mass re-eval that deletes-then-re-evals (e.g. `harness/reeval-fixed-arms.sh`), **verify every arm still has 200 `*.eval.json`** - a re-eval that errors after the delete leaves the task orphaned (mandated arms have no synth-skip backstop), which silently drops an arm to n=199 in analyze.
- **Hang tasks** (`blacknon__hwatch`, `cslarsen__jp2a`, `cmatsuoka__figlet`, srgn, i3-style, xsv, oranda, bore, entr, felix): watcher/TUI/loop tests that never terminate; capped by the per-instance timeout map in patch #4. Add new ones there as discovered.
- **`PB_DISK_EVICT_GB` defaults to 30, not 100.** The code default (patch #3) is 30 GB. The stripe orchestrator sets it higher. When running `score-with-toolkit.py eval` directly (outside the orchestrator), pass it explicitly so eviction reclaims before disk drifts near-empty. **But set it BELOW current free disk, not a fixed `160`.** If the value is >= free disk (e.g. `160` on a host with only ~158 GB free, 2026-05-26), eviction fires after *every* task and re-pulls each image - constant thrash, very slow. Rule: `PB_DISK_EVICT_GB ≈ free_disk_GB − 30..60` (e.g. 100-120 when ~160-186 GB free). This is a floor that triggers cleanup as disk fills, not a target to sit at.
- Reboots are safe: durable submissions on disk are all the resume logic needs; no in-memory state.
- `OPENCLAW_SESSION=1` (set in `harness/run.sh`) makes gstack skills auto-decide on AskUserQuestion, so the in-container agent never blocks on a prompt.

## Recovering from a disk-runaway wedge

When a runaway task fills Docker.raw, the daemon wedges (`docker rmi`/`exec`/`ps` hang or error with `rw layer snapshot not found`). **Restarting the Docker daemon to recover from a wedge is explicitly allowed without asking** (it does not lose durable data - submissions/evals/transcripts are host files under `runs/`/`logs/`, independent of Docker). Proven recovery sequence:

1. If the daemon is still responsive, first try halting the fill surgically: `docker rm -f $(docker ps -q)` removes the running eval containers (where the runaway writable layer lives). Often enough on its own.
2. If wedged: force-kill `pkill -9 -f com.docker.backend`, `pkill -9 -f "Docker Desktop"`, then `open -a Docker`; wait for `docker info` to respond (~10s).
3. Clear containers (corrupted ones first - parse the `rw layer snapshot not found` id from the error and `docker rm -f <id>` to unblock the list walk, then `docker rm -f $(docker ps -aq)`).
4. To reclaim host disk, the container clear may not be enough - the cached `programbench/*:task` images fill Docker.raw. Remove them (`docker images 'programbench/*' -q | xargs docker rmi -f`) and Docker.raw auto-TRIMs back (recovered 1.6 GiB → 196 GiB after wedge #2). They re-pull on demand (~20 pulls, within the authenticated rate limit). `pb/*` base images and `pb-deps-*`/toolkit volumes survive a restart.
5. Resume: completed `*.eval.json` persist, so a re-run skips them. Blocklist the offending task before re-evaluating its stripe.

## Files of interest

- `harness/run-batch.sh` - the batch driver (routes `codex-*` arms to `run-codex.sh`)
- `harness/run.sh` - single-task runner (Claude Code arms)
- `harness/run-codex.sh` - single-task runner (OpenAI Codex CLI arms)
- `harness/sandbox/Dockerfile.codex` - Codex agent container image
- `harness/sandbox/entrypoint-codex.sh` - in-container entrypoint for the codex arm
- `harness/score-and-report.sh` - score a finished run
- `harness/run-stripe-pipeline.sh` - multi-arm stripe orchestrator (see "Multi-arm pipelines" above)
- `arms/codex-vanilla-clean/` - fair free-choice control arm (free language choice in the SAME stripped sandbox the mandated arms get); its `orchestration.md` + union `compile-prelude.sh`. Built to de-confound the per-language study (see `[memory:project_codex-pilot-1-env-confound]`)
- `harness/sandbox/Dockerfile.clean-lang-all` - `pb/clean-lang-all` image: clean-lang-base + all 8 toolchains (no python deletion), used by `codex-vanilla-clean`; run-codex.sh maps that arm to overlay="all" + mounts all `pb-deps-*` volumes
- `harness/reinject-prelude.py` - re-inject an arm's current compile-prelude into already-built submissions (needed for eval-env fixes; prelude is baked at agent-run time)
- `harness/reeval-fixed-arms.sh`, `harness/resume-vc-tail.sh`, `harness/final-eval.sh` - the 2026-05-26 env-fix re-eval orchestration (re-eval the c/ruby/python/go/rust false-zeros + the vanilla-clean tail) with the built-in real-time disk watchdog
- `harness/patches/_apply_patches.py` - the 5 vendored-programbench patches (remove_image retry, in-container SIGKILL on timeout, demand-based eviction, run_tests timeout map, AppleDouble `._*` strip); run via `apply-disk-cleanup-patches.sh` after any `cache/pb-venv/` recreate
- `/tmp/<run-name>-full.log` - append-mode batch log (survives across resumes)
- `/tmp/<run-name>-full.pid` - current batch PID
- `/tmp/<run-name>-stripe.log` - stripe orchestrator main log
- `/tmp/<run-name>-stripe.pid` - stripe orchestrator PID
- `logs/<run-name>/_stripe/stripe-NNN.log` - per-stripe sublog (agent + eval output for one stripe)
- `runs/<run-name>/<arm>/<task>/submission.tar.gz` - durable per-task submissions
- `runs/<run-name>/<arm>/<task>/<task>.eval.json` - per-task eval result (delete to force re-eval)
- `logs/<run-name>/<arm>/<task>/transcript.jsonl` - per-task agent transcripts
- `logs/<run-name>/_batch/<arm>__<task>.log` - per-task runner logs
