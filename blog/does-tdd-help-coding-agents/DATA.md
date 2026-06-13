# Data for "Does test-driven development help a coding agent?"

This directory holds the post (`index.md`), its chart (`cost-vs-quality.svg`), and the data behind them.
The shared eval harness lives at the repo root under `harness/` and is reused across posts, so it is not co-located here.

## The experiment

One model (gpt-5.5), held fixed, reverse-engineered the same ProgramBench tasks twice:
- `codex-free` (**control**) - free choice of approach.
- `codex-free-tdd` (**tdd**) - the same setup plus a mandated test-driven-development skill (write a failing test first, minimum code to pass, repeat). The skill is in `arms/codex-free-tdd/` at the repo root.

Everything else (model, tasks, sandbox, grader) is identical, so the only variable is the workflow.

A follow-up reproduction adds one more arm:
- `codex-free-tdd-will` (**alternate tdd**) - Will Hampson's behavior-focused, vertical-slice TDD skill, run on the same tasks and denominator.

## What is here

```
index.md                 the post
cost-vs-quality.svg       the chart (regenerated from data/per-task.csv)
data/
  per-task.csv            per-task results: control, tdd, alternate tdd, + the 8 mandated language arms
  submissions/<arm>/<task>.tar.gz   the code each arm actually wrote, per task
```

## `data/per-task.csv`

One row per (arm, task). Key columns: `arm`, `task`, `pct` (test pass-rate, the headline metric), `pct_ran`, `cost_usd`, `turns`, `duration_min`, `language`, `wraps_tool`, `n_total_tests`, `n_passed_tests`.

The CSV carries **eleven** arms: the two originally compared here (`codex-free`, `codex-free-tdd`), the reproduction arm (`codex-free-tdd-will`), plus the eight `codex-lang-*` arms. The eight language arms are included only to define **task difficulty** (cross-arm mean pass-rate, split into equal-count terciles) so that the compared TDD/control arms are out-of-sample in the difficulty breakdown - they are not otherwise part of this comparison.

**Denominator: n = 192.** Reproduce it by dropping these 8 blocklisted tasks (7 structurally-broken + 1 unscoreable-by-wrapping):
`sharkdp__hyperfine`, `eliukblau__pixterm`, `ggreer__the_silver_searcher`, `tinycc__tinycc`, `stathissideris__ditaa`, `tarka__xcp`, `alecthomas__chroma`, and `multiprocessio__dsq`.
`dsq` is dropped because it can be satisfied only by delegating to an embedded SQL engine bundled in a language runtime, which no cleanroom strip can remove - so it cannot be scored cleanly.

## De-pollution (why the scores here are trustworthy)

A few tasks let the agent reuse the reference tool's own engine instead of reimplementing it (linking `libbrotli`, `import sqlite3`, a Go sqlite driver, etc.), which inflates the score.
For this comparison, both arms were audited cell-by-cell (code-read) on every at-risk task, and any working wrap in either arm was stripped and re-run, or - where the engine is baked into a language runtime and cannot be stripped (`dsq`) - the task was blocklisted.
The submissions in `data/submissions/` are the clean ones.
This is stricter than the original benchmark, which blocks the network but does not prevent runtime-bundled-engine reuse.

## Reproduce

From the repo root, with the harness venv:

- **Chart**: `cache/pb-venv/bin/python harness/make-tdd-chart.py blog/does-tdd-help-coding-agents`
- **Headline + paired test**: `cache/pb-venv/bin/python harness/analyze.py --run codex-pilot-2 --arms codex-free,codex-free-tdd` (reports mean%, solve@75, paired Wilcoxon/Holm, win/lose/tie; the per-arm aggregates are all derivable from `data/per-task.csv` after applying the blocklist).
- **Alternate TDD reproduction**: see `will-tdd-reproduction.md`; it uses the same blocklist and difficulty split.
- **Difficulty + cost breakdown**: group `data/per-task.csv` by arm, tercile tasks by the 8-mandated-arm cross-mean `pct`, and average `pct` / `cost_usd` / `turns` per tercile.

## Not included here (size)

The raw per-test eval JSON (~GBs) and the full agent transcripts are too large for the repo.
`data/per-task.csv` carries the per-task aggregate; the full per-test detail and trajectories are available on request.
