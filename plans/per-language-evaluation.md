# Per-language evaluation

## Question

Holding the model constant (Claude Opus 4.7), how much does the choice of implementation language affect ProgramBench outcomes?

This is more granular than the ProgramBench paper's §4.1 ablation, which only asked "when forbidden the natural choice, can the agent still do the job?".
That ablation is one bit (constrained vs not) and lets the agent pick the alternative language freely.
We instead want to mandate a specific language per arm and compare outcomes side by side.

## What the paper found (for context)

- Baseline: agents choose any language freely; Python is picked in 36% of runs.
- Constraint: agent must use a non-reference language (their pick); Python share rises to 51%.
- Result: "the constraint does not uniformly decrease scores. Claude Opus 4.7 and 4.6 see meaningful drops, all three GPT models surprisingly each improve by 4.2%."
- Authors' interpretation: models may be steered toward a language they're better at when forced to switch.

The paper does **not** quantify per-language capability directly — they leave that as the implied explanation for the GPT result without measuring it.

## Proposed arms

Each arm mandates a specific implementation language via its `orchestration.md`.
The harness needs no changes; arms drop into `arms/` like any other.

- `lang-c` — C with gcc + glibc + libtinfo.
- `lang-rust` — Rust with full crate access (see deps section).
- `lang-go` — Go with stdlib + vendored modules from the deps volume.
- `lang-python` — Python 3 stdlib + curated wheel cache.
- `lang-js` — Node.js + curated npm cache.
- (optional) `lang-free` — agent picks; matches the paper's baseline. Acts as the control.

Five mandated languages plus the control = six arms.
Subset is fine for a first pass (e.g., C, Python, Rust as the most pedagogically interesting trio).

## Confounds to design around

1. **Cleanroom dep asymmetry.** Rust without crates is brutal; Python's stdlib is rich; C/Go are middle-of-the-road. Without controlling for this, the experiment measures network policy more than language capability. **Mitigation: pre-vendored deps volume (see below).**
2. **Task language fit.** `cmatrix` is C-shaped (termios, ANSI escapes). `chroma` is parser-shaped (any language fits). Some tasks are effectively impossible in some languages because of native-library needs (audio, graphics, GMP). **Mitigation: stratify post-hoc by task's reference language; also expect some 0-scores per language as legitimate signal.**
3. **Model native skill.** Opus is presumably stronger in some languages than others. This is exactly what the experiment measures, so it's not a confound to remove — but it should be acknowledged as a result interpretation and not a property of the language itself.
4. **Behavioral tests are language-agnostic.** Tests compare the rebuilt binary's output against the reference. Language doesn't directly cost points; only indirectly via implementation correctness. This is good — it means we're measuring implementation success, not test-writing skill.

## Dep strategy (Path A: pre-vendored read-only volume)

Why not open the proxy to package registries:

- `cargo install --git`, `go get`, `pip install git+https://` all bypass registry-only whitelists.
- Registries serve full source tarballs — opens a memorization vector.
- Removing `--network none` from the cleanroom punctures the kernel-level guarantee that's the strongest property of the current harness.
- Violates ProgramBench's "no internet during inference" rule, breaks comparability with the paper.

Instead, pre-stage a `deps/` Docker volume mounted read-only into each cleanroom:

- `crates.io` top N crates (snapshot pinned by date), populated into `~/.cargo/registry/`.
- `pypi` top N wheels (snapshot pinned), populated into a local wheelhouse.
- `npm` top N packages, populated into a local registry cache.
- `go` modules — populate `GOMODCACHE` for any tasks where the original was a Go module.

Snapshot the volume once, ship its hash with the harness for reproducibility.
Document `snapshot version: <hash>` in every run name so future replications can pin to it.
This is upfront work but it's the only path that gives a clean per-language answer without breaking hermeticity.

## Cost & scale

- Five mandated languages × 201 tasks × 1 seed ≈ 1,005 runs ≈ \$4-6k at current ~\$5/task.
- Pilot first: 3 languages (C, Python, Rust) × 10 tasks ≈ 30 runs ≈ \$150.
- Decide whether to scale based on the pilot's variance and effect sizes.

## Analysis additions

`harness/analyze.py` would need a stratification dimension to be useful here.

- Group ProgramBench tasks by reference language (`task.yaml`'s `language:` field).
- Per-arm × per-reference-language cells in the report table.
- Gives "how does Rust→Python compare to Rust→C?" answers.

The existing per-task CSV already has all the metrics; the stratification is purely a reporting concern.

## Relationship to the gstack experiment

Independent. Different research question, different arms.
The harness supports both because arms are pluggable directories.
Don't combine them in a single sweep — keep each arm one-dimensional or analysis becomes a mess.

If you want the full 2D matrix (language × scaffolding) eventually, that's `2 × 5 × 201 = 2,010` runs ≈ $10k.
Defer until both 1D experiments produce useful results.

## Sequencing

1. Wait until the gstack pilot + full sweep finishes and we know the harness is solid at scale.
2. Build the deps snapshot tooling: `harness/build-deps-volume.sh`.
3. Add language arms with mandated-language orchestration prompts.
4. Add reference-language stratification to `analyze.py`.
5. Pilot 3 languages × 10 tasks.
6. Decide whether to scale to 5 × 201 based on pilot.

## Open questions

- Which N to pick for each registry's top-N snapshot? Probably N=200-500 based on download counts, biased toward what ProgramBench reference repos use.
- Is `lang-free` worth running given the paper already published numbers for that condition with mini-swe-agent? Maybe yes for direct comparison with our other arms; maybe no if we just cite the paper.
- For tasks where the reference repo is itself an obscure language (e.g., C++, Lua, Zig), do we exclude or accept that some mandated arms will trivially fail? Probably exclude from the per-arm comparison and report them separately.
