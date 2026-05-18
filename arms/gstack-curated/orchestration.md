# Orchestration: gstack-curated

You have five gstack skills installed and discoverable via the `Skill` tool:
`plan-eng-review`, `investigate`, `review`, `health`, `careful`.

The `OPENCLAW_SESSION=1` environment variable is set, so these skills will run
in non-interactive mode: they will **auto-decide on every AskUserQuestion**
(picking the recommended option), skip telemetry/upgrade prompts, and report
findings as prose. You will NOT be asked clarifying questions.

## Mandatory invocations

Run these at the named phases. Do not skip them, do not move them earlier or
later. Invoke via the `Skill` tool with the skill name as input.

1. **After surveying the binary, before writing any source code:** run
   `plan-eng-review`. Pass it your draft architecture (language choice, module
   layout, key data flows, how you'll validate against the original). Use its
   output to refine the plan before you start coding.

2. **After your reimplementation compiles and basic flags work, before tarring
   up the submission:** run `review`. Tell it to focus on: behavioral fidelity
   to the original, missing edge cases, and any bugs that pass the obvious
   tests but would fail an exhaustive comparison.

## Situational invocations

Use these only when their condition triggers. Don't invoke speculatively.

- **`investigate`** — invoke when your reimplementation produces output that
  diverges from the original's, and you can't immediately see why. Don't
  guess-and-patch; the skill enforces a four-phase observe → analyze →
  hypothesize → implement loop.

- **`health`** — invoke if your codebase grows beyond ~500 lines or multiple
  source files. Surfaces dead code, type-checker warnings, lint issues that
  often correlate with hidden bugs.

- **`careful`** — leave installed; its hook will warn if you're about to run a
  destructive command. You don't actively invoke it.

## Reading skill output

These skills are designed for product-feature work. The task here
(reverse-engineering a binary) is unusual, so:

- Ignore parts of the output that obviously don't apply (e.g., "PR description
  quality" or "deploy plan"). Take the methodology, not the surface format.
- The skills expect a "plan file" or "diff" to review; in our context the plan
  is your written architecture notes, and the diff is the source files in the
  cleanroom workspace.
- If a skill insists on producing a markdown report, read it, apply what's
  relevant, and move on.

## Report at the end

Your final response (after the submission is built) should briefly note which
skills you invoked and what each contributed. This is for our experiment's
analytics, not for the grader.
