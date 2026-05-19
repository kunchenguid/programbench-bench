# codex-pilot-2 pre-registration

Frozen analysis plan, written BEFORE the full run (Phase 1), to prevent post-hoc
reinterpretation. Date: 2026-05-26. Model held constant: OpenAI gpt-5.5 (exact id
recorded in each run's batch logs + provenance file at run time).

## Question

Does *mandating* an implementation language cost the model vs letting it choose
freely, on ProgramBench (reverse-engineer a CLI tool from its docs + a run-only
golden binary)?

## Design

- **Arms (9):** `codex-free` (free language choice) + 8 mandated
  `codex-lang-{c,go,rust,java,js,ts,python,ruby}`. `codex-free` is the baseline.
- **Tasks:** the full ProgramBench 1.0.2 set, n=200 per arm. K=1 per (arm, task).
- **Environment (de-confounded):** every arm's cleanroom IS the per-task `:task`
  eval image (Ubuntu 22.04) + a uniform toolchain overlay. cleanroom == eval by
  construction, so the pilot-1 cleanroom-vs-eval env-mismatch false-zero class
  cannot occur. Mandated arms get only their language's toolchain (others
  stripped); `codex-free` gets all. See `plans/codex-pilot-2.md`.

## Metrics

- **Primary:** per-task `pct` = % of non-ignored tests passed (0-100), where
  `ignored_tests`/`ignored` branches from the task's `tests.json` are excluded
  (programbench 1.0.2 `EvaluationResult.without_ignored()` / `for_branches`).
  This is the official programbench score.
- **Secondary (dual metric):** `pct_ran` = % passed over tests that actually RAN
  (exclude `not_run`). `pct <= pct_ran`; the gap quantifies the branch-level
  not_run/timeout cascade (a runtime-robustness artifact, not a logic deficit).
  Reporting both separates *correctness* from *runtime-robustness*.
- **Supporting (descriptive, not hypothesis-tested):** compile%, threshold ladder
  (>0, >=25/50/80/95, =100), $/task, turns, median wall-time (per-task median;
  summed/mean wall time is unreliable - see analyze.py caveat).

## Hypothesis tests

- **Per-arm comparison:** paired per-task delta `codex-free - mandated_i` on the
  primary metric `pct`, tested with the **Wilcoxon signed-rank test** (two-sided,
  zero-method=wilcox) over the tasks present in both arms.
- **Family:** 8 comparisons (codex-free vs each mandated arm).
- **Multiple-comparison correction:** **Holm-Bonferroni** across the 8 Wilcoxon
  p-values. Report both raw and Holm-adjusted p.
- **Effect size:** paired Δ mean % with a 10k-resample bootstrap 95% CI
  (`np.random.default_rng(42)`), plus Δ median %, plus the same on `pct_ran`.

## Decision rule (frozen)

For each mandated language i, conclude "mandating language i has a non-zero cost
vs free choice" iff the Holm-adjusted Wilcoxon p < 0.05 AND the bootstrap 95% CI
on Δ mean `pct` excludes 0. Direction read from the sign of Δ mean (codex-free -
mandated_i): positive => mandate costs. Magnitude is reported on BOTH `pct` and
`pct_ran`; if a language's `pct` gap largely vanishes on `pct_ran`, the cost is
attributed to the runtime-robustness cascade rather than worse logic.

## Denominator

Full **n=200 per arm** always (Kun's standing preference). No "clean n=196"
subset is computed, cited, or reported. Disk-runaway/broken tasks
(tinycc/ditaa/tarka-xcp/chroma) score ~0 for every arm so they are neutral;
1.0.2's enriched `ignored_tests` annotations auto-exclude several previously-hung
tests from the score.

## Robustness checks (reported, not hypothesis-tested)

- **Language-choice distribution** for `codex-free` (first-class: detected from
  the submission's source extensions + compile.sh). Enables M1 (selection) vs M2
  (same-language) reasoning by design.
- **Reference-tool wrapping rate** per arm (detect-only policy): fraction of
  submissions that shell out to the tool-under-test / a system binary. If
  non-uniform across arms, flag it; pilot-1 found it minor and ~uniform.

## Provenance / determinism

Pin and record: programbench 1.0.2 + the 5 vendored patches; task-image digests;
toolchain versions (rust/go/python/perl native in `:task`; node/jdk/maven/ruby
from `pb-toolkit2`); exact model id + date; budget/timeout/idle caps; K=1.
analyze.py is a pure function of the input files (seeded bootstrap, deterministic
scipy) - re-running yields byte-identical output.

## Execution discipline

Stripe mode + `docker login` from the start; real-time disk watchdog
(`harness/disk-watchdog.sh`); blocklist the disk-runaway tasks before their
stripe; assert full n=200 `*.eval.json` per arm at the end.
