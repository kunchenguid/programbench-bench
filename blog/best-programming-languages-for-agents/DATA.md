# Data for "Best programming languages for agents"

This directory holds the post (`index.md`), its charts (`cost-quality-{hard,med,easy}.svg`), and the data those rest on.
The shared eval harness lives at the repo root under `harness/` and is reused across posts, so it is not co-located here.

## What is here

```
index.md                     the post
cost-quality-{hard,med,easy}.svg   the three charts (regenerated from data/per-task.csv)
data/
  per-task.csv               per-task results for all 9 arms (the keystone artifact)
  submissions/<arm>/<task>.tar.gz   the code gpt-5.5 actually wrote, per arm per task
```

## The study

One model (gpt-5.5), held fixed, reverse-engineered the same tasks once per arm across **9 arms**: `codex-free` (free language choice) plus 8 mandated languages (`codex-lang-{python,ts,rust,go,js,ruby,c,java}`).
Each arm worked in an identical network-free sandbox; the grader runs a hidden test branch against the submission.

## `data/per-task.csv`

One row per (arm, task). Columns:

- `arm`, `task`
- `pct` - test pass-rate over all non-ignored tests (the headline metric; mean of this per arm is the score in the post)
- `pct_ran` - pass-rate over only tests that actually ran (excludes `not_run`)
- `compile_ok`, `n_total_tests`, `n_ran_tests`, `n_passed_tests`
- `language` - the language the submission used (for `codex-free`, the one it chose)
- `wraps_tool` - heuristic wrap flag (unreliable; the real de-pollution was a code-read audit, see below)
- `cost_usd`, `turns`, `duration_min` - token cost and effort
- `n_skills_invoked`, `skills_invoked`

**Denominator.** The post reports **n = 192**. The CSV ships all 200 rows per arm for transparency; reproduce n = 192 by dropping these 8 blocklisted tasks - 7 structurally broken (4 disk-runaways + 3 hang/broken suites that score identically across every arm) plus `multiprocessio__dsq` (only satisfiable by an unstrippable runtime-bundled SQL engine):
`sharkdp__hyperfine`, `eliukblau__pixterm`, `ggreer__the_silver_searcher`, `tinycc__tinycc`, `stathissideris__ditaa`, `tarka__xcp`, `alecthomas__chroma`, `multiprocessio__dsq`.

**This is the de-polluted, timeout-fixed snapshot.** Two corrections are already baked into these numbers (see the post's Caveats):
1. **De-pollution** - tasks where an arm wrapped the reference tool (linking `lib<tool>.so`, exec'ing `/usr/bin/<tool>`, copying the provided binary, etc.) were re-run in stripped cleanrooms with an anti-wrap prompt, and the clean scores spliced in. The submissions in `data/submissions/` are the clean ones.
2. **Timeout fix** - the JavaScript arm was re-scored at the same 6h test timeout as every other arm, removing an asymmetry that had depressed it.

## `data/submissions/`

The actual reimplementations, as `<arm>/<task>.tar.gz`.
Each archive contains the `compile.sh` and source files the agent submitted.
This is the most interesting thing to read: the same tool, written from scratch nine different ways.

## Reproduce

From the repo root, with the harness venv:

- **Recompute the charts** from the snapshot:
  `cache/pb-venv/bin/python harness/make-cost-quality-charts.py blog/best-programming-languages-for-agents`
- **Recompute the per-arm tables, paired Wilcoxon, terciles**: `harness/analyze.py` reads the raw run tree; the per-arm aggregates and difficulty terciles in the post are all derivable from `data/per-task.csv` (group by arm, apply the blocklist, tercile by cross-arm mean `pct`).
- **Re-run the de-pollution** (the part most worth a second pair of eyes): the per-task strip scripts are `harness/strip-ref/*.sh`, gated by `PB_STRIP_REF=1` in `harness/run-codex.sh`, with the anti-wrap prohibition in `harness/system.md`; `harness/consolidate-depollution.sh` splices clean cells back in (backup-first). Re-strip, re-run, and if the rankings shift, that is exactly the result to surface.

## Not included here (size)

The raw per-test eval JSON (~11 GB) and the full agent transcripts (~176 MB) are too large for the repo.
`data/per-task.csv` already carries the per-task aggregate (`n_total/n_ran/n_passed`).
The full per-test detail and transcripts are available on request.
