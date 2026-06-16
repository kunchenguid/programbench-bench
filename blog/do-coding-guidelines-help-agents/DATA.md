# Data for "Do 'reduce LLM coding mistakes' guidelines help a coding agent?"

This directory holds the post (`index.md`), its chart (`cost-vs-quality.svg`), and the data behind them.
The shared eval harness lives at the repo root under `harness/` and is reused across posts, so it is not co-located here.

## The experiment

One model (gpt-5.5), held fixed, reverse-engineered the same ProgramBench tasks twice:
- `codex-free` (**control**) - free choice of approach, no guidelines.
- `codex-free-karpathy` (**guidelines**) - the same setup plus the `multica-ai/andrej-karpathy-skills` `CLAUDE.md` ("behavioral guidelines to reduce common LLM coding mistakes": Think Before Coding, Simplicity First, Surgical Changes, Goal-Driven Execution).

The guidelines are delivered the way the file is meant to be used: as an auto-loaded instruction file (`AGENTS.md`, the agent's native equivalent of `CLAUDE.md`), reproduced verbatim plus a one-line note that there is no human in the loop. The file is at `arms/codex-free-karpathy/AGENTS.md` at the repo root; `orchestration.md` and `setup.sh` are byte-identical to `codex-free`, so the auto-loaded guidelines are the only variable.

Everything else (model, tasks, sandbox, grader) is identical.

## What is here

```
index.md                  the post (thread)
cost-vs-quality.svg        the chart (regenerated from data/per-task.csv)
data/
  per-task.csv             per-task results: control, guidelines, + the 8 mandated language arms
  submissions/<arm>/<task>.tar.gz   the code each arm actually wrote, per task
```

## `data/per-task.csv`

One row per (arm, task). Key columns: `arm`, `task`, `pct` (test pass-rate, the headline metric), `pct_ran`, `cost_usd`, `turns`, `duration_min`, `language`, `wraps_tool`, `n_total_tests`, `n_passed_tests`.

The CSV carries **ten** arms: the two compared here (`codex-free`, `codex-free-karpathy`) plus the eight `codex-lang-*` arms. The eight are included only to define **task difficulty** (their cross-arm mean pass-rate, split into equal-count terciles) so that both compared arms are out-of-sample in the difficulty breakdown - they are not otherwise part of this comparison.

**Denominator: n = 192.** Reproduce it by dropping these 8 blocklisted tasks (7 structurally-broken + 1 unscoreable-by-wrapping):
`sharkdp__hyperfine`, `eliukblau__pixterm`, `ggreer__the_silver_searcher`, `tinycc__tinycc`, `stathissideris__ditaa`, `tarka__xcp`, `alecthomas__chroma`, and `multiprocessio__dsq`.

## Why the scores here are trustworthy (audit + de-confound)

Before computing any number, both arms went through a cell-by-cell audit and a fairness de-confound:

- **No cheating.** Every task where the guidelines arm beat the control by a suspicious margin was code-read for reference-tool wrapping (linking/execing the original binary, `dlopen`, importing a bundled engine). **Zero wrapping inflation was found** - all wins are genuine reimplementations, verified against the scored executable's hash.
- **Per-task harness defects fixed and re-run.** A handful of tasks were mis-scored by eval-harness artifacts (out-of-memory kills, CPU-spin timeouts, a stale per-test timeout). Each was diagnosed; genuine harness artifacts were re-run at low concurrency to recover a clean score, and genuine model bugs (an implementation that itself hangs or OOMs) were kept at their real low score. The distinction was decided by mechanism, not by which number was flattering.
- **Baseline-vintage de-confound (the important one).** The control arm had been scored earlier under an old 300-second per-test timeout, while the guidelines arm was scored fresh at a 6-hour cap. That asymmetry under-scored the control on 12 long-running tasks and *spuriously favored the guidelines arm*. All 12 control tasks were re-evaluated at the matching 6-hour cap before any comparison. Fixing it is what moves the headline slightly back toward the control.

Faulty pre-fix results were replaced in place by the clean re-runs; the originals were moved out of the results tree so they cannot pollute future analysis. The submissions in `data/submissions/` are the clean ones.

## Reproduce

From the repo root, with the harness venv:

- **Chart**: `cache/pb-venv/bin/python harness/make-arm-chart.py blog/do-coding-guidelines-help-agents codex-free-karpathy "with karpathy guidelines" "Coding guidelines: less quality, no cost savings"`
- **Headline + paired test**: `cache/pb-venv/bin/python harness/analyze.py --run codex-pilot-2 --arms codex-free,codex-free-karpathy` (reports mean%, solve@75, paired Wilcoxon/Holm, win/lose/tie; the per-arm aggregates are all derivable from `data/per-task.csv` after applying the blocklist).
- **Difficulty + cost breakdown**: group `data/per-task.csv` by arm, tercile tasks by the 8-mandated-arm cross-mean `pct`, and average `pct` / `cost_usd` / `turns` per tercile.

## Not included here (size)

The raw per-test eval JSON (~GBs) and the full agent transcripts are too large for the repo.
`data/per-task.csv` carries the per-task aggregate; the full per-test detail and trajectories are available on request.
