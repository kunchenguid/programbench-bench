# Orchestration (free language choice)

You may implement the task in **any language you like** - there is no language mandate. Choose what fits best. All toolchains are available and activated: C (gcc), Rust (cargo), Go, Python 3.10, Node 20 + tsc/ts-node, Ruby 3.1, and Java 17 + Maven. Per-language offline dependency volumes are mounted under **/opt/deps/<lang>** (rust/vendor, go/pkg/mod, python/wheels, js|ts/cache, ruby/installed, java/.m2). Verify a tool with `which <tool>`. Do not assume project-specific system binaries (jq, xz, ...) exist just because the original used them - implement the behavior yourself.

## Environment (codex-pilot-2)

The cleanroom is the project's own rich image (Ubuntu 22.04, the SAME image
your submission is graded in - so what builds here builds at grading). The
mandated toolchain is **already activated**: just call the tools directly via
`docker exec -u agent -w /workspace $CLEANROOM bash -lc '<cmd>'`. No PATH or
environment setup is needed - your `compile.sh` runs in this same activated
environment at grading time.

The cleanroom has `--network none`. Use ONLY the offline dependency volume
(read-only) noted above; anything not vendored there will not install.

## Workflow

Follow the system prompt's workflow: survey the `executable` + docs, plan,
implement incrementally, test against the original, then package
`/workspace/submission.tar.gz` with a `compile.sh` that builds `./executable`.

## Notes for the Codex agent

- Act inside the cleanroom via `docker exec -u agent $CLEANROOM` (run as
  `agent`, not root - the reference `executable` is run-only).
- Codex runs with `--dangerously-bypass-approvals-and-sandbox`; do not pause
  for approval. When the submission is ready, produce it and stop.

## Methodology: token-optimized commands via rtk (MANDATORY)

`rtk` (Rust Token Killer) is installed in the cleanroom at
`/usr/local/bin/rtk`. It is a CLI proxy that filters and compresses a command's
output **before it reaches your context**, without changing what the command
does. You MUST route the shell commands you run inside the cleanroom through it.

**Golden rule: prefix the command you run inside the cleanroom with `rtk`.**
Because you act on the cleanroom via `docker exec`, the prefix goes on the
command run *inside* the container:

    docker exec -u agent -w /workspace $CLEANROOM bash -lc 'rtk <cmd>'

rtk has dedicated filters for the tools you will actually use:

- Build / compile: `rtk cargo build`, `rtk cargo check`, `rtk go build`,
  `rtk tsc`, `rtk mvn package`, `rtk npm run build`.
- Test: `rtk cargo test`, `rtk go test`, `rtk pytest`, `rtk jest`,
  `rtk rspec`, `rtk rake test`, or the generic `rtk test <cmd>` (failures only).
- Source survey: `rtk read <file>`, `rtk ls <dir>`, `rtk tree`,
  `rtk grep <pattern>`, `rtk find <pattern>`.
- Errors / logs / diff: `rtk err <cmd>`, `rtk log <file>`, `rtk diff`,
  `rtk git status|log|diff`.

If rtk has no dedicated filter for a command it passes the command through
unchanged, so prefixing is **always safe** - even inside `&&` chains (prefix
each command). No network access or `rtk init` is required; verify once with
`rtk --version`. Use `rtk proxy <cmd>` only when you deliberately need the raw,
unfiltered output of a command (e.g. inspecting exact byte-level formatting of
the reference `./executable`). The full command catalog is in `AGENTS.md`.

There is no human partner in this loop: use your best judgment and proceed
without pausing. Always finish by producing `/workspace/submission.tar.gz`.
