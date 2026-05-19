# Orchestration (free language choice)

You may implement the task in **any language you like** - there is no language mandate. Choose what fits best. All toolchains are available and activated: C (gcc), Rust (cargo), Go, Python 3.10, Node 20 + tsc/ts-node, Ruby 3.1, and Java 17 + Maven. Per-language offline dependency volumes are mounted under **/opt/deps/<lang>** (rust/vendor, go/pkg/mod, python/wheels, js|ts/cache, ruby/installed, java/.m2). Verify a tool with `which <tool>`. Do not assume project-specific system binaries (jq, xz, ...) exist just because the original used them - implement the behavior yourself.

## Environment (claude-pilot-2)

The cleanroom is the project's own rich image (Ubuntu 22.04, the SAME image
your submission is graded in - so what builds here builds at grading). The
toolchains are **already activated**: just call the tools directly via
`docker exec -u agent -w /workspace $CLEANROOM bash -lc '<cmd>'`. No PATH or
environment setup is needed - your `compile.sh` runs in this same activated
environment at grading time.

The cleanroom has `--network none`. Use ONLY the offline dependency volumes
(read-only) noted above; anything not vendored there will not install.

## Workflow

Follow the system prompt's workflow: survey the `executable` + docs, plan,
implement incrementally, test against the original, then package
`/workspace/submission.tar.gz` with a `compile.sh` that builds `./executable`.

## Notes for the agent

- The running cleanroom container's name is in the `CLEANROOM` env var. Act
  inside it via `docker exec -u agent -w /workspace $CLEANROOM bash -lc '<cmd>'`
  (run as `agent`, not root - the reference `executable` is run-only).
- Permissions are pre-approved (`--permission-mode bypassPermissions`); do not
  pause to ask. When the submission is ready, produce it and stop.
