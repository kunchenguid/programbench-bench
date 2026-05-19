# Orchestration: free language choice, stripped sandbox

This is the **fair free-choice control** arm. You may implement the task in
**any language you like** - there is no language mandate. Choose whatever
fits the task best.

The difference from a normal run is the environment: you are in a *clean*
multi-language sandbox, not the original project's image. Concretely:

- **No original-project dependencies are installed.** The cleanroom does
  not carry the upstream repo's apt/pip/npm/gem packages or its build
  artifacts. `/workspace` contains only the task spec, the tests' view of
  the CLI, and a run-only reference `executable` (mode `--x--x--x`, not
  readable).
- **No project-specific system binaries to wrap.** Do not assume tools
  like `jq`, `xz`, `ffmpeg`, etc. are present just because the original
  tool is built on them - implement the behavior yourself.
- **All major toolchains ARE installed**: gcc/g++/make/cmake, rustc/cargo,
  go, node/npm + tsc/ts-node, python3, ruby + bundler, and openjdk-17 +
  maven. Verify with `which <tool>`.
- **Offline dependency volumes are mounted per language** (read-only):
  - Rust: vendored crates at `/opt/deps/rust/vendor` (cargo offline config
    is pre-installed).
  - Go: module cache at `/opt/deps/go/pkg/mod` (`GOPROXY=off`).
  - Python: pip wheelhouse at `/opt/deps/python/wheels` (`PIP_NO_INDEX=1`,
    `PIP_FIND_LINKS` set). `ls /opt/deps/python/wheels | head`.
  - JS/TS: npm offline cache at `/opt/deps/js/cache` and `/opt/deps/ts/cache`.
  - Ruby: installed gem tree at `/opt/deps/ruby/installed` (`GEM_PATH` set).
  - Java: local Maven repo at `/opt/deps/java/.m2/repository` (`mvn -o`).

Reaching for a well-known library that's in the offline volume is usually
better than rolling your own - but a library not present offline will not
install, so prefer the standard library when unsure.

## Workflow

Follow the system prompt's general workflow: survey, plan, implement
incrementally, test against the original `executable`, package as
`/workspace/submission.tar.gz` (with a `compile.sh` that builds/sets up
your chosen language). Use a clear shebang + `chmod +x` on the entry point.

## Notes for the Codex agent

- You are running inside an externally-sandboxed Docker container. Act
  inside the isolated cleanroom via `docker exec $CLEANROOM`.
- Codex CLI runs with `--dangerously-bypass-approvals-and-sandbox`; do not
  stop to ask for permission. The user is not present.
- The cleanroom has `--network none`; `curl`, `pip install` from the
  internet, etc. will fail. Use the offline deps volumes only.
- When the submission is complete, produce `/workspace/submission.tar.gz`
  and stop.
