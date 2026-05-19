# codex-pilot-2-pilot — morning brief

**Status: COMPLETE.** 20 tasks x 9 arms, all arms n=20, 100% compile. Pipeline validated end-to-end.
Ran 2026-05-26 23:31 -> 2026-05-27 ~07:1x (incl. a mid-run bug fix + codex-free recovery re-eval).
Full report: `runs/codex-pilot-2-pilot/summary.txt`; per-task CSV: `runs/codex-pilot-2-pilot/per-task.csv`.

## Per-arm summary (n=20, baseline = codex-free)

| arm | mean% | ran% | median% | compile% | $/task | language(s) | wrap% |
| --- | ----- | ---- | ------- | -------- | ------ | ----------- | ----- |
| **codex-free** | **47.1** | 61.5 | 50.6 | 100 | 1.19 | python:16 go:2 c:1 js:1 | 15 |
| codex-lang-c | 51.7 | 55.9 | 56.9 | 100 | 1.26 | c | 5 |
| codex-lang-go | 48.0 | 57.2 | 55.6 | 100 | 1.16 | go | 30 |
| codex-lang-rust | 48.7 | 56.1 | 57.3 | 100 | 1.59 | rust | 10 |
| codex-lang-java | 38.3 | 54.3 | 35.3 | 100 | 1.33 | java | 10 |
| codex-lang-js | 42.1 | 55.0 | 42.6 | 100 | 1.38 | js | 40 |
| codex-lang-ts | 46.1 | 56.4 | 50.7 | 100 | 1.56 | ts | 35 |
| codex-lang-python | 47.7 | 60.0 | 50.4 | 100 | 1.22 | python | 20 |
| codex-lang-ruby | 48.4 | 56.9 | 56.4 | 100 | 1.56 | ruby | 15 |

mean% = % of non-ignored tests passed (primary). ran% = % passed over tests that actually ran (excl not_run).

## Findings (PILOT - n=20, directional only, NOT powered)

- **Mandating a language costs little-to-nothing here.** Paired Wilcoxon (codex-free vs each mandated),
  Holm-corrected across 8: **none significant** (all Holm-adj p >= 0.21). Raw deltas are small and mixed -
  c/go/rust/python/ruby actually score >= free on raw mean%; only java (-8.8, raw p=0.027 but Holm p=0.21)
  and js (-5.0, ns) trail. This is the opposite tilt from codex-pilot-1's "mandating costs 7-17 pts" - the
  de-confounded topology (cleanroom == eval) appears to remove most of that gap. Needs n=200 to confirm.
- **Dual metric is informative.** ran% > mean% for every arm, and **codex-free has the largest mean->ran gap**
  (47.1 -> 61.5, +14.4) vs mandated (~+5-8). So free choice suffered MORE not_run cascade, but on tests that
  ran its per-test correctness was actually highest (Δ mean ran% is negative for ALL mandated arms, -1.5 to -7.2).
  Interpretation to test at scale: raw mean% and runtime-robustness (not_run) tell different stories.
- **Language choice (codex-free): python 16/20**, go 2, c 1, js 1. The model overwhelmingly picks Python for
  these CLI-tool tasks. M2 (same-language): codex-free 47.1 ~= codex-lang-python 47.7 (Δ +0.6, ns) - mandating
  python is indistinguishable from the model freely choosing python.
- **Wrapping rate:** 5-40% (js 40, ts 35, go 30 highest; codex-free 15). NOTE: the detector likely over-flags
  legitimate subprocess use - eyeball a few js/ts submissions before trusting the absolute rate (not a blocker).

## Anomalies / caveats

- **Hang tasks dominate eval time.** chroma/srgn/i3-style/oranda/hwatch (in the first-20 set) hit their
  per-instance timeouts (1200s + retry) and score ~0 across ALL arms (neutral). zoxide shows high not_run
  on several arms (a slow test branch). These drag mean% uniformly. codex-free's recovery re-eval took ~70 min
  almost entirely because of these (same cost each arm paid). For the full 200x9 run, budget extra eval wall
  time for the hang-task cluster; the disk watchdog + per-task timeouts keep it bounded.
- The pip-config bug (below) was caught + fixed; codex-free was recovered by re-injecting the fixed prelude and
  re-evaluating with the SAME params the other arms used (symmetric - not tightened, to avoid baseline bias).

## The bug we caught + fixed (durable)

codex-free + codex-lang-python `setup.sh` put `PIP_NO_INDEX=1` in `/etc/profile.d`. programbench runs every
eval step via `bash -lc` (login shell) which sources profile.d, so the eval's OWN `pip install pytest-timeout
pytest-rerunfailures` was forced offline -> failed -> pytest rejected `--timeout` -> no results.xml -> ALL
tests not_run (false zero on those 2 arms). **Fixed in the arm setup.sh source (applies to the full run):**
PIP_* moved to an inline export (covers the agent's compile.sh) + an agent-home `pip.conf` (uid agent, never
read by the root-run eval); profile.d carries PATH only. Validated: python re-ran clean (20/20, tests run),
codex-free recovered (cmatrix 95). General rule recorded: never put package-manager offline/no-index env in
profile.d (the eval sources it).

## Cost projection (full 200 x 9)

Pilot mean **$1.36/task** (180 task-rows). Full run = 200 x 9 x $1.36 ~= **$2,450** (in line with the ~$2.2-2.6k
estimate). Per-arm $/task: rust/ts/ruby highest (~$1.56-1.59), go/c/python/free lowest (~$1.16-1.26).

## Ready for the full run? YES.

- Pipeline validated end-to-end on all 9 arms; 100% compile; cleanroom == eval; no env false-zeros after the fix.
- The pip-config bug is fixed durably in the arm setup.sh (full run uses it fresh - no recovery needed).
- The exactly-200 fix is applied (`harness/apply-200-fix.sh`): run-batch + stripe orchestrator now drop the
  testorg scaffold before slicing -> 200 real tasks, 10x20 stripes.
- Launch (after confirming docker login is still valid): same command as the pilot but `RUN_NAME=codex-pilot-2`,
  **OMIT `PB_MAX_TASKS`**, keep STRIPE_SIZE=20. See `plans/codex-pilot-2-LAUNCH.md`.

### Minor pre-full-run considerations (not blockers)
- Eyeball the wrapping detector on a couple of js/ts submissions (it may over-flag).
- Budget eval wall-time for the hang-task cluster at 200-task scale; keep the disk watchdog running.
- The hang/broken tasks (chroma/srgn/i3-style/oranda/hwatch/zoxide) score ~0 uniformly - neutral, per n=200 convention.
