# codex-pilot-2 implementation progress

Working log for the autonomous implementation of `plans/codex-pilot-2.md`.

**STUDY COMPLETE 2026-06-01. Phases 0-4 all DONE.** Full 200×9 run finished (clean n=200 every arm), Phase-4 analysis run, and 4 follow-up investigations delivered.
Earlier launch/restart history is preserved below; this block is the final state.

### FINAL RESULT (n=200, ranked by solve@90 / mean%)
codex-free **3.5 / 48.7** (WIN) · rust 2.5/46.8 · js 2.0/44.5 · ruby 2.0/44.8 · c 1.5/44.1 · python 1.5/45.8 · go 1.0/45.3 · ts 0.5/45.1 · java 0.5/40.1.
Paired Wilcoxon on mean% vs codex-free, Holm-corrected: **significant** for c, java, js, ruby, ts; **not significant** for go, python, rust (rust closest).
All arms compile ~100%; codex-free is also the cheapest ($1.10/task) and lowest-token (987k/task), picking python 160/200.
Headline: **free language choice beats mandating any single language** — but see the investigation caveats below, it is narrower than the headline suggests.

### Run incidents (2026-05-29 → 06-01) and how each was handled
- **PAUSED at stripe-5 (2026-05-29, LLM quota), RESUMED 2026-05-30** on Kun's explicit signal.
- **codex-free DROPPED on the 2026-05-30 resume**: the resume command omitted `PB_ARMS`, so `run-stripe-pipeline.sh` fell back to its DEFAULT arm list (the pilot-1 8 mandated arms, *no codex-free*) and silently set baseline=codex-lang-ts.
  Caught at stripe 9; codex-free frozen at 120/200 (stripes 0-5 intact).
  Fix: let the 8-arm run finish, then an isolated `PB_ARMS=codex-free PB_START_TASK=120` backfill brought codex-free to 200.
  **Now CODE-FIXED durably (2026-06-01): `run-stripe-pipeline.sh`'s default arm list is the arms discovered under `runs/$RUN_NAME/`, so a resume can never drop an arm again; a fresh run with no run dir still must pass PB_ARMS.**
- **n=200 cleanup (3 unscored tasks):** `zk-org__zk` errored for all 9 arms during the concurrent run (transient 300s test-timeout → results_read_failed, no eval.json); a solo re-eval scored it fine on all 9 (no code change — inherent slow-suite flakiness, recovered by re-running alone).
  `tomnomnom__gron` (python, java) + `guumaster__hostctl` (java) hit a real eval-harness bug: `tar: build: Cannot open: File exists` — the submission's compiled `build` dir collides with the test fixture's `build` path during container extraction → RuntimeError, no eval.json.
  **Fixed durably (patch #6, see below); re-eval gave real scores (java hostctl 52, gron 0 for py+java = genuine capability, NOT synth-0).**

### Phase-4 investigation findings (4 subagents, see `[[project_pilot2-final-findings]]`)
1. **Python "gap" is selection, not skill.** On the 160 tasks codex-free chose python, free-python vs mandated-python is a dead heat (median Δ +0.05). 78% of free's +2.90 mean edge comes from the 40 tasks where free chose a *compiled* language (or wrapped the native binary) on perf-heavy systems tools where a python reimpl times out (results_read_failed → ~0).
2. **solve@90 is too thin to rank by** (1-7 tasks/arm, SD 0.91; mid-table order is bootstrap noise). Best discriminator is **solve@60** (spread 16.5, ρ=0.97 with mean%, free #1 in 99% of bootstraps); **mean%/median%** already separate all 9 arms and feed the Wilcoxon. solve@70/75 actually invert free vs rust; solve@95/100 are saturated. Recommendation: headline on mean% (+ solve@60); keep solve@90/95 as reported-not-ranking with a noise caveat. (This pushes back on the solve@90-primary convention; Kun asked.)
3. **Dominant axis = per-test process-spawn cost → not_run cascade under the 300s branch budget.** java is worst (40.1) NOT from wrong answers (it has the lowest absolute failure count) but from ~1.7s/test JVM cold-start → 54% of its tests never run (vs ~39% native), 111 timeout-tasks, ~10.5 min/task wall (2× the others) + split-artifact 0s (gron loose `build/*.class` → ClassNotFound). Per-lang profiles (rust=parsers/protocols/perf, python=text/file stdlib but dynamic-typing crashes, c=codec/fidelity, etc.) in the memory note.
4. **No task-type→language pattern (null result).** Per-bucket margins are within noise; mean-winner ≠ per-task-win-leader in 8/13 domains. Only robust signals: avoid java broadly; weak rust edge on system+compiler tasks. codex-free ignores domain (80% python) and is ~6.8 pts BELOW the per-task oracle → free wins by beating the *average* forced language, not the best.

**Cross-cutting caveat for the writeup:** a large share of the measured "language effect" (esp. java's −8.6) is the eval's 300s per-test timeout × process-spawn cost = partly a BENCHMARK ARTIFACT, not pure capability. "Free choice wins" is real but narrow.

See `[[project_codex-pilot-2-full-run-live]]`, `[[project_pilot2-final-findings]]`, `[[project_pilot2-python-gap-is-artifact]]`.

## Decisions / findings (verified this session)

- **`:task` image is safe as the agent cleanroom.** Inspected `sharkdp_1776_hyperfine.327d5f4:task`:
  `/workspace` tracks only 11 files (README/LICENSE/doc + run-only `executable` mode `---x--x--x`),
  git history is a single squashed "Initial commit" (no source leak), no readable tests/solution/eval dir
  anywhere on the fs. The image is Ubuntu 22.04 and already ships Python 3.10 + Go + pytest (the eval env).
  => pilot-2 premise validated: cleanroom can == eval image with no solution leak.
- **pb currently 1.0.1**; 1.0.1 eval already has an `ignored_tests` / `branch_ignored` mechanism +
  `EvaluationResult.without_ignored()`. Open: does 1.0.2 set `ignored:true` on the new slow_or_hang/hung tests?

## Phase status

- [x] Phase 0 - Foundation: pb 1.0.2 + patches; cleanroom==`:task` topology (PB_PILOT2); Ubuntu-native
      pb-toolkit2 (node/ts/jdk/maven/ruby); 9 arms (setup.sh + orchestration); env + eval + agent-smoke validated.
- [x] Phase 1 - Harness & pre-reg: analyze.py dual metric (mean%/ran%) + ignored-test filter + language-choice
      logging + precise wrapping detection + Holm correction; branch-cascade investigated (upstream thread->signal
      handles per-test, residual measured by ran%); disk-watchdog.sh; pre-reg doc; provenance snapshot.
- [x] Phase 2 - Pilot: COMPLETE 2026-05-27. All 9 arms n=20, 100% compile, cleanroom==eval validated end-to-end.
      Results + verdict (READY for full run): `plans/codex-pilot-2-pilot-RESULTS.md`. Headline (n=20, directional):
      mandating a language is NOT significantly worse than free choice after Holm (de-confounding removed pilot-1's
      gap); free choice picks python 16/20; dual metric (ran%) shows free has more not_run but higher per-test
      correctness. $1.36/task -> full run ~$2.45k. apply-200-fix applied (full run = 200). pip-config bug fixed durably.
- [x] Phase 2 (orig launch line): LAUNCHED 2026-05-26 as `codex-pilot-2-pilot` (20 tasks x 9 arms, one stripe, PB_MAX_TASKS=20).
      orchestrator pid /tmp/codex-pilot-2-pilot-stripe.pid, disk-watchdog /tmp/codex-pilot-2-pilot-watchdog.pid,
      health cron d7961d3f (session-only, ~25min). Smoke evidence: rust 46/100, ruby 73/100 on gron.
      NOTE: caught a scope bug at launch - the orchestrator loops ALL tasks regardless of STRIPE_SIZE; added
      `PB_MAX_TASKS` cap (aborted the mis-scoped attempt in ~20s, 0 spend).

### BUG FOUND + FIXED DURABLY during the pilot (2026-05-27): profile.d PIP_NO_INDEX broke the eval
- Symptom: codex-free scored 0 on all 20 (error_code=None, ALL tests not_run). codex-lang-python would too.
- Root cause: programbench `container.py` runs EVERY eval step via `bash -lc` (login shell) -> sources
  `/etc/profile.d/pb-activate.sh`. The codex-free + python setup.sh exported `PIP_NO_INDEX=1` there, so the
  eval's OWN `pip install pytest-timeout pytest-rerunfailures` was forced offline -> failed -> pytest rejected
  `--timeout=30` -> no results.xml -> results_read_failed -> all not_run. (The other 7 arms have no PIP var in
  profile.d, which is why the rust/ruby smoke passed.)
- DURABLE FIX (in `arms/{codex-free,codex-lang-python}/setup.sh` = source of truth for BOTH pilot and full run):
  profile.d now carries PATH (+ non-pip vars) only; `PIP_NO_INDEX/PIP_FIND_LINKS` are an INLINE export (reaches
  the agent's compile.sh, which is where the prelude runs, but NOT the eval's separate bash -lc pip step) plus an
  agent-home `/home/agent/.config/pip/pip.conf` (uid agent, never read by the root-run eval).
- Validated: re-injected codex-free's 20 submissions (`reinject-prelude.py --run codex-pilot-2-pilot codex-free
  --all`, now setup.sh-aware) and re-eval'd cmatrix -> **95/100, 507 tests run** (was 0/all-not_run). The full
  run uses the fixed setup.sh fresh, so it is correct by construction.
- Generalization to watch: anything in profile.d applies to the eval (bash -lc). Keep profile.d to PATH + benign
  toolchain env; never put package-manager OFFLINE/no-index there.

### PRE-FULL-RUN TODO — all DONE (2026-05-27)
- [x] Exactly-200 fix APPLIED via `harness/apply-200-fix.sh` (idempotent, bash -n verified, tested on copies).
      Both `run-batch.sh` and `run-stripe-pipeline.sh` now pre-exclude the `testorg__calculator.abc1234` scaffold
      BEFORE slicing -> TOTAL=200, clean 10x20 stripes, indices aligned. (Re-running apply-200-fix is a safe no-op.)
- [x] pip-config bug fixed durably in `arms/{codex-free,codex-lang-python}/setup.sh` (see bug section above);
      the full run uses the fixed setup.sh fresh, so no recovery is needed for it.

---

## How to finish: the full run (Phase 3) + analysis (Phase 4)

Everything is ready. The full run reuses the exact pilot pipeline; only the launch args change.

### 0. Pre-flight (re-verify — the pilot ran overnight, auth may have lapsed)
```sh
cd /Users/kunchen/github/kunchenguid/programbench-bench
docker pull -q hello-world >/dev/null 2>&1 && echo "registry ok"   # confirm docker login still valid (parallel=4 needs auth)
docker volume ls | grep -E 'pb-toolkit2|pb-deps-'                  # want pb-toolkit2 + 7 pb-deps-*
ls ~/.codex/auth.json && df -h /                                   # codex auth present; want >=150 GB free
bash harness/apply-200-fix.sh                                      # idempotent; should print [skip] x2 (already applied)
```

### 1. Launch (200 tasks x 9 arms, stripe mode) — `RUN_NAME=codex-pilot-2`, NO `PB_MAX_TASKS`
```sh
RUN_NAME=codex-pilot-2
# Real-time disk watchdog FIRST (the hang-task cluster + 200 tasks stress disk).
PB_DISK_FLOOR_GB=50 nohup ./harness/disk-watchdog.sh > /tmp/${RUN_NAME}-watchdog.log 2>&1 &
echo $! > /tmp/${RUN_NAME}-watchdog.pid

RUN_NAME=$RUN_NAME \
  STRIPE_SIZE=20 \
  PB_PILOT2=1 \
  PB_ARMS="codex-free,codex-lang-c,codex-lang-go,codex-lang-rust,codex-lang-java,codex-lang-js,codex-lang-ts,codex-lang-python,codex-lang-ruby" \
  PB_BASELINE=codex-free \
  PARALLEL=4 \
  WORKERS=2 \
  BRANCH_WORKERS=1 \
  BRANCH_RETRIES=0 \
  PB_DISK_EVICT_GB=100 \
  PB_RUN_TESTS_TIMEOUT_SEC=300 \
  nohup ./harness/run-stripe-pipeline.sh >> /tmp/${RUN_NAME}-stripe.log 2>&1 &
echo $! > /tmp/${RUN_NAME}-stripe.pid
```
- `WORKERS=2` (lowered 4->2 on 2026-05-28 at Kun's request to lighten eval CPU/mem load + slow wall-clock pace; note: eval workers consume ZERO LLM tokens, so this does NOT reduce total quota - the burn-rate lever is PARALLEL) + `BRANCH_WORKERS=1` + `BRANCH_RETRIES=0` (set 2026-05-27 to bound eval load + kill the futile-retry time sink) MUST all be passed on every (re)launch or they revert (`--workers 4 -b 2`, retries 1). Combined with the 1-eval concurrency cap in `run-stripe-pipeline.sh`: peak eval parallelism = 1 eval x 2 workers x 1 branch = 2 test execs, and hang/broken tasks fail fast (no 300s retry). `--branch-retries` is scoring-neutral for the hang cluster (they score 0 either way).
- **`PB_START_TASK` (added 2026-05-28):** skip-guard in the stripe loop that skips stripes whose task range is entirely below it - use on resume to jump past fully-complete stripes WITHOUT re-walking their hang-task evals (every restart otherwise re-runs the broken/incomplete branches in all completed stripes; this was ~8-18h of wasted recompute after the WORKERS=2 restart). Set to a multiple of STRIPE_SIZE where all tasks [0:N] are fully evaluated, else you silently drop real work. Relaunched 2026-05-28 with `PB_START_TASK=80` (stripes 0-3 done) -> resumed at stripe 4. **Orchestrator pid is now 36980** (each restart gated on a fresh 0-agents check, zero wasted LLM spend).
- Expect the log to report **"200 tasks ... 10 stripes"** (NOT 201/11). If it says 201, apply-200-fix didn't take — stop and re-apply.
- `caffeinate -i -s -w "$(cat /tmp/${RUN_NAME}-stripe.pid)" &` to keep the machine awake (optional but recommended).
- Arm a ~25-min supervisor (same prompt as the pilot's, with RUN_NAME=codex-pilot-2) if running unattended.

### 2. Estimate / monitor
- Wall time: ~10x the pilot's per-stripe time. The pilot's single 20-task stripe took ~6 h (agents + the slow
  hang-task evals); 10 stripes is NOT 60 h because stripes pipeline agents-vs-eval, but budget **~1.5-2.5 days**.
  (If that's too long, raise `PARALLEL`/`WORKERS` only while docker-login'd, or shard by stripe range.)
- Cost: ~$1.36/task x 1800 = **~$2,450**.
- Health: `tail /tmp/codex-pilot-2-stripe.log`; per-arm `ls runs/codex-pilot-2/<arm>/*/*.eval.json | wc -l`;
  real rate-limit `grep -hiE 'toomanyrequests|HTTP 429|status code 429|rate limit' /tmp/codex-pilot-2-stripe.log`.

### 3. On "ALL STRIPES DONE" (Phase 4 analysis)
```sh
# Assert full n=200 per arm (the convention - no clean-cut subset):
for a in codex-free codex-lang-c codex-lang-go codex-lang-rust codex-lang-java codex-lang-js codex-lang-ts codex-lang-python codex-lang-ruby; do
  echo "$a $(ls runs/codex-pilot-2/$a/*/*.eval.json 2>/dev/null | wc -l)"; done   # want 200 each
# Full report (the orchestrator also runs this at the end):
cache/pb-venv/bin/python harness/analyze.py --run codex-pilot-2 \
  --arms codex-free,codex-lang-c,codex-lang-go,codex-lang-rust,codex-lang-java,codex-lang-js,codex-lang-ts,codex-lang-python,codex-lang-ruby
kill "$(cat /tmp/codex-pilot-2-watchdog.pid)" 2>/dev/null   # stop watchdog
```
Then interpret per the frozen plan (`plans/codex-pilot-2-prereg.md`): primary = mean% paired Wilcoxon vs
codex-free, Holm across 8; secondary = ran% (dual metric); report language distribution, wrapping rates,
M1/M2 decomposition; full n=200 denominator.

### Gotchas carried over from the pilot
- **NO `PB_MAX_TASKS`** for the full run (that env caps the task set — pilot-only).
- Don't edit `run-batch.sh` / `run-stripe-pipeline.sh` while the run is live (bash re-reads scripts -> corruption).
- Any arm finishing < 200 eval.json -> re-eval that arm with `harness/score-with-toolkit.py eval runs/codex-pilot-2/<arm>`
  using the SAME params (don't tighten hang-task timeouts -> would bias that arm vs the others).
- The hang/broken tasks (chroma/srgn/i3-style/oranda/hwatch/zoxide + the disk-runaways tinycc/ditaa/tarka-xcp)
  score ~0 uniformly across arms — neutral; the blocklist + watchdog + per-task timeouts keep them bounded.

## Phase 0 log

### Done
- **pb 1.0.1 -> 1.0.2** in fresh `cache/pb-venv` (1.0.1 preserved at `cache/pb-venv-1.0.1-backup`). All deps resolved.
- **Fixed a latent bug in `harness/patches/_apply_patches.py`**: idempotency check used `new[:80]`, which for
  patches that wrap stock code is stock text always present. Once patch #1 wrote `PATCH_MARKER` into
  `container.py`, patch #2 (the in-container SIGKILL sweep) false-positived as "already patched" and was
  SILENTLY SKIPPED on the 1.0.2 install. Replaced with per-patch unique sentinels. All 5 patches now apply;
  verified idempotent (2nd run skips all 5).
- **1.0.2 hang-annotation gate: CONFIRMED auto-exclude.** New `slow_or_hang`/`hung` tests are recorded as
  per-branch `ignored_tests` in `tests.json` (chroma grew 16->28); the eval batch path applies
  `EvaluationResult.without_ignored()` to drop them from the score. So chroma/bat/etc hang caveats clear for free.
  ACTION FOR PHASE 1: `.eval.json` stores ALL tests (incl. ignored); `analyze.py` must apply the `ignored_tests`
  filter itself (via `get_ignored_tests`) to match the official score.

### Architecture validation (zero API cost, container-only)
- **`:task` is safe as the agent cleanroom** (verified: /workspace = docs + run-only `executable`, no source/tests).
- **`:task` base ships natively: gcc 11.4, Rust 1.92 (`/usr/local/cargo`), Go (`/usr/local/go`), Python 3.10.12, Perl.**
  Missing natively: node, ruby, javac.
- => **codex-lang-{c,rust,go,python}: cleanroom==eval with ZERO mounts, ZERO preludes** (toolchain already in `:task`).
  Only need to mount the *deps* volume (vendored crates / GOMODCACHE / wheels) for offline packages; C needs none.
- **The existing `pb-all-langs-toolkit` is debian-12 and UNUSABLE on Ubuntu 22.04**: mounting its `/usr/lib` via
  `LD_LIBRARY_PATH` segfaults EVERY binary incl. native python3 (glibc mismatch). pilot-1 only got away with it
  by dpkg-force-installing debian debs (the band-aids pilot-2 removes).
- => **codex-lang-{js,ts,ruby,java} + codex-free need an Ubuntu-22.04-native toolkit** (`pb-toolkit2`): node + JDK
  via self-contained tarballs (relocatable, PATH/JAVA_HOME only); ruby is the fiddly one (runtime libs must resolve
  at TEST time when pytest spawns the agent's `executable`, without dpkg).

### Decisions
- New runner path gated by `PB_PILOT2=1` (keeps pilot-1 run-codex.sh behavior intact). IMAGE switches to `:task`.
- Toolchain normalization: codex-lang-X cleanroom exposes only X (+ gcc/make as universal linkers); other native
  language entrypoints (cargo/go/node/ruby/javac/tsc and competing python) neutralized in the cleanroom. Mandate
  integrity is also backstopped by Phase-1 language-choice logging + violation detection.

### DONE (Phase 0 build)
- [x] **New pilot-2 topology in `run-codex.sh`** (gated `PB_PILOT2=1`): cleanroom = `:task`; per-arm volume
      mounts; runs `arms/<arm>/setup.sh` in cleanroom; strips competing toolchains for mandated arms. pilot-1
      path preserved in the `else`. Syntax-checked.
- [x] **`pb-toolkit2`** built (`Dockerfile.pilot2-toolkit`, ubuntu:22.04) + populated (586MB: jdk316/node195/ruby66/maven11).
      node20+tsc5.5+ts-node, Temurin JDK17+maven3.9, ruby3.1.6 (`--enable-shared`, libyaml copied in).
- [x] **All 9 arms**: `setup.sh` (env via /etc/profile.d + world-readable configs + /usr/local/bin symlinks;
      ruby uses narrow-LD wrappers for test-time) + pilot-2 `orchestration.md`. codex-free created.
- [x] **`score-with-toolkit.py`** mounts `pb-toolkit2` -> /opt/tk2 at eval (matches cleanroom).
- [x] **Env validation (zero API cost):** in `:task` containers, all toolkit langs (node/tsc/ts-node, java/javac/mvn,
      ruby+yaml) AND native langs (rust/go/python offline configs) work via setup.sh; **native python3 stays intact**
      (narrow-LD ruby wrapper does NOT poison the loader). Mandate strip verified (ruby kept, cargo/go gone, python stub).
- [x] **Eval-side validation (zero API cost):** mimicked programbench's compile step (fresh `:task` as root + injected
      setup.sh prelude) - ruby & rust `./executable` build and run, python3 intact => cleanroom==eval holds.

### TODO (Phase 0 remaining) — all DONE
- [x] Agent smoke (rust 46 / ruby 73 on gron) validated the codex agent loop; then the full 20x9 pilot
      exercised all 9 arms end-to-end (100% compile across the board).
- [x] run-batch.sh codex-free routing + `PB_PILOT2` propagation confirmed working (pilot ran codex-free + all
      8 mandated arms through the stripe orchestrator with PB_PILOT2=1).
