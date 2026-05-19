# Plan: codex-pilot-2 (clean-slate per-language study)

Status: PROPOSAL (2026-05-26). Supersedes the topology in `per-language-evaluation.md`.
Model held constant: OpenAI gpt-5.5 (record exact id + date at run time).
Question (unchanged): does *mandating* an implementation language cost the model vs letting it choose freely?

This is a clean restart, not a patch of codex-pilot-1.
codex-pilot-1 reached a directionally-correct headline but accumulated too many caveats (env confound, a scoring-metric artifact, cross-session wall-time corruption, residual false-zeros) to be conclusive.
pilot-2 removes those at the source.

## What changes from codex-pilot-1

- **Drop the unfair `codex-vanilla` (rich) arm.** Keep only the fair free-choice arm, renamed `codex-vanilla-clean` -> **`codex-free`**.
- **9 arms total:** `codex-free` + 8 mandated `codex-lang-{c,go,rust,java,js,ts,python,ruby}`.
- **Consistent base, done right:** the cleanroom IS the per-task eval image (see below). The separate `clean-lang-base` / `clean-lang-*` images are retired.
- **Rich, realistic, common environment** shared identically by all arms (jq/sqlite/dev-libs present), instead of the stripped sandbox.
- **ProgramBench upgraded 1.0.1 -> 1.0.2** (investigated; low-risk - see below).
- **Conclusiveness upgrades:** dual scoring metric, branch-cascade fix, first-class language-choice logging, pre-registration, full provenance.

## 1. The core architecture: the cleanroom IS the eval image

codex-pilot-1's entire env-confound class came from one choice: the cleanroom was a separate fixed base (`debian:12`) that diverged from the per-task eval image (`programbench/<task>:task` = Ubuntu 22.04 / Python 3.10).
Every false-zero we chased (python 3.11->3.10, ruby libyaml, C headers, the deb-force-install hacks) is a symptom of that divergence.

The fix is not "pick a better fixed base."
It is to derive each arm's cleanroom FROM that task's own `programbench/<task>:task` image - the exact image eval runs in - and layer the language toolchain on top from the toolkit volume (which eval already mounts too).

Consequences:

- **cleanroom == eval, by construction.** The env-mismatch class is gone for every language, with no preludes papering over differences. The python/ruby/java patches made for pilot-1 become unnecessary in pilot-2 (keep them only for any pilot-1 re-eval).
- **Rich and realistic** ("closer to the original vanilla"): jq/sqlite/dev-libs are simply present because the task image has them.
- **Fair:** the original `codex-vanilla` was only "unfair" because *it* got the rich image while mandated arms got the stripped one. Giving the same rich image to all 9 arms dissolves the asymmetry.
- This is the original-vanilla topology, applied uniformly to all arms. The divergence that clean-lang-base introduced was the bug.

### Toolchain normalization (required)

Task images carry the tool's *native* toolchain (e.g. the chroma image ships Go because chroma is Go).
Left as-is this would (a) bias `codex-free` toward whatever language was pre-installed and (b) leak a toolchain into a mandated arm.
So toolchains are normalized uniformly, independent of what the task image happened to bake in:

- `codex-free`: mount ALL language toolchains (free choice is genuinely free, not steered by pre-installs).
- `codex-lang-X`: mount ONLY toolchain X, and strip any other-language toolchain the task image included.

Toolchains come from the existing toolkit volumes, mounted identically at cleanroom and eval, so both sides are byte-identical.

## 2. The common environment + the reference-tool / wrapping policy (DECIDED)

The environment IS the stock `programbench/<task>:task` image - which is already rich (it carries the tool's own build deps plus general utils like jq/gcc/make).
This is, by construction, the environment the original `codex-vanilla` arm used, so "closer to the original vanilla" is satisfied by the cleanroom = task-image decision itself; no synthetic "common dev layer" is required.
If Phase 0 finds a common building-block util materially missing across many task images, add a thin uniform layer (applied identically at cleanroom and eval) - but default to pure stock for maximum fidelity.

**Stock programbench behavior re: the tool-under-test (investigated 2026-05-26).**
Pulling the xz task's `:task_cleanroom` (agent workspace) and `:task` (eval) images, BOTH contain the real `/usr/bin/xz` on PATH plus gcc/make/jq.
So stock programbench does NOT strip the tool-under-test; wrapping a system copy is an available strategy off the shelf.
The benchmark's anti-cheat is the **black-box golden** `/workspace/executable` (mode 111, run-only, unreadable; the eval stashes it to `/opt/programbench-stashed-executable-do-not-modify`, hashes it, and restores+verifies) - NOT tool-stripping.
For the large majority of the 200 tasks (niche GitHub tools with no distro package) there is no system copy at all - only the run-only golden - so genuine reverse-engineering is forced there regardless.

Policy (confirmed with Kun, 2026-05-26): **match stock - do NOT strip - and detect-only.**

1. Keep the environment exactly as programbench ships it: no PATH surgery, no removing the tool-under-test. Rationale: faithful to the benchmark (results stay comparable to other programbench runs); simpler (no per-task surgery); wrapping is uniform across all 9 arms so it does not bias the *language* comparison, which is the actual question; pilot-1 found wrapping minor and roughly uniform.
2. Detect and report wrapping as a robustness check: scan submissions for `exec`/`Command`/`subprocess` of the reference binary or the system tool-under-test, and report a per-arm wrapping rate. If it turns out non-uniform across arms, flag it.

(This supersedes an earlier draft that proposed stripping the reference tool for self-referential tasks; once stock behavior was confirmed, matching stock is the cleaner, more faithful choice.)

## 3. ProgramBench upgrade 1.0.1 -> 1.0.2 (INVESTIGATED 2026-05-26)

Latest on PyPI is 1.0.2 (2026-05-11), a 4-day patch bump over 1.0.1.
Diffed the 1.0.2 wheel against a pristine 1.0.1 wheel:

- **Zero code changes.** Every `.py` is byte-identical, so our 5 vendored patches re-apply cleanly with no re-port, and the eval base/OS is unchanged (Ubuntu 22.04 / Python 3.10). The deps volumes do NOT need an OS-driven rebuild.
- **Same 200-task set** (201 task dirs both, identical names).
- **Only change: enriched `slow_or_hang`/`hung` test annotations** in `tests.json` for 8 tasks: chroma (18), codesnap (262), hashcards (264), xplr (88), bore (24), amber (4), silver_searcher (4), bat (4). These flag the slow/hung tests behind several pilot-1 caveats (chroma `results_read_failed`, bat). Net positive.

Open item for Phase 0: confirm whether the eval consumes these annotations to auto-EXCLUDE flagged tests from scoring, or merely records them.
If auto-excluded, several pilot-1 broken/hang caveats clear for free.

Install path: `uv pip install programbench==1.0.2` into a fresh `cache/pb-venv`, then re-run `harness/patches/apply-disk-cleanup-patches.sh` (idempotent) and re-pull task images (record digests).

## 4. Making the conclusions conclusive

These target the interpretive caveats that made pilot-1's headline shaky.

- **Dual metric: raw `pct` AND "pass-rate over tests that actually ran"** (exclude `not_run`).
  pilot-1's biggest finding was that much of the "mandated penalty" was the branch-level `not_run`/timeout cascade, not worse logic - mandated-python was per-test essentially tied with free choice.
  Reporting both separates *correctness* from *runtime-robustness*; the gap between them quantifies the artifact.
- **Fix the branch cascade.** Investigate programbench's branch semantics so one slow/crashing test fails *that test*, not the whole branch's hundreds of tests. This alone shrinks several gaps.
- **Log language choice as first-class data** (for `codex-free`), so M1 (selection) vs M2 (same-language) is measured by design, not reverse-engineered from file extensions.
- **K=1** per (arm, task) (confirmed with Kun, 2026-05-26). No multi-sample variance estimate this run; report paired per-task deltas, not per-arm error bars from resampling.
- **Pre-register** before running: primary metric, the paired test (Wilcoxon, `codex-free` vs each mandated), multiple-comparison correction (8 comparisons -> Holm), and the decision rule. Prevents post-hoc reinterpretation.
- **Provenance / determinism:** pin programbench 1.0.2 + task-image digests + all toolchain versions + exact model id and date + budget/turn caps. Snapshot so the run is reproducible.
- **Clean single-pass execution:** stripe mode + `docker login` from the start; real-time disk watchdog; blocklist or fix the disk-runaway tasks (tinycc/ditaa/tarka-xcp - NOT fixed by 1.0.2) up front; assert full n=200 per arm at the end. Avoids the cross-session wall-time corruption and the 429 cascades.
- **Denominator:** report full n=200 (Kun's standing preference); no clean-cut subset.

## 5. Execution plan (phased, with gates)

- **Phase 0 - Foundation.**
  Upgrade to programbench 1.0.2; re-apply patches; re-pull + digest-pin task images.
  Build the "cleanroom = stock task image + toolchain overlay" topology and the toolchain-normalization.
  Check whether any common building-block util is materially missing across task images (add a uniform layer only if so; default pure stock).
  Rebuild toolkit/deps volumes only as needed (base unchanged, so minimal).
  **Gate:** 1 task x 9 arms smoke; verify cleanroom == eval; zero env false-zeros; confirm 1.0.2 hang-annotation handling.
- **Phase 1 - Harness & pre-registration.**
  Dual-metric scoring; language-choice logging; wrapping detection; branch-cascade fix; disk watchdog.
  Write and freeze the analysis plan.
- **Phase 2 - Pilot.**
  ~20 tasks x 9 arms, end-to-end, to validate the pipeline and project cost.
- **Phase 3 - Full run.**
  200 x 9, stripe mode. ~$2.6k at K=1 (vs pilot-1's ~$2.9k for 10 arms).
- **Phase 4 - Analysis** per the frozen plan: dual metrics, paired deltas with Holm correction, M1/M2 decomposition, wrapping rates, cost-efficiency.

## 6. Arms summary

| Arm | Toolchain(s) in cleanroom | Mandate |
| --- | --- | --- |
| `codex-free` | all 8 | free choice |
| `codex-lang-c` | C only | must write C |
| `codex-lang-go` | Go only | must write Go |
| `codex-lang-rust` | Rust only | must write Rust |
| `codex-lang-java` | JDK only | must write Java |
| `codex-lang-js` | Node only | must write JS |
| `codex-lang-ts` | Node only | must write TS |
| `codex-lang-python` | Python only | must write Python |
| `codex-lang-ruby` | Ruby only | must write Ruby |

All 9 share the identical per-task base (the eval image) + common dev layer; they differ only in toolchain presence and the orchestration mandate.

## Open decisions / TODO before Phase 3

- Confirm 1.0.2 hang-annotation consumption (Phase 0 gate).
- Confirm no common building-block util is materially missing across task images (else add a thin uniform layer); implement wrapping detection/reporting.
- Pre-registration doc signed off.
