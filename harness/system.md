# Task

You are participating in ProgramBench. Your job is to **reverse-engineer a compiled
program from scratch**, given only its compiled binary and its documentation.

## Environment

A long-running cleanroom Docker container is already started for you. The container
name is in the env var `$CLEANROOM`. Inside the container:

- Working directory: `/workspace` (you have write access as user `agent`).
- `/workspace/executable` is the original compiled program. You can **run it**
  (`docker exec -u agent $CLEANROOM /workspace/executable --help`) but you
  **cannot read the binary itself** (permissions are `---x--x--x`).
- `/workspace/README.md`, `/workspace/*.md`, and any `*.1` files are the docs
  shipped with the program. Read them.
- `/workspace/data/` may contain runtime data files used by the program.
- The container has gcc, make, rustc, cargo, go, and python3 pre-installed.
  No `autoconf`, no man-db, no internet.
- The container has `--network none`. **It cannot reach the internet.**
  Don't try to fetch dependencies; vendor them or write them yourself.

## Interacting with the cleanroom

You operate from outside the container, on the host. Use `docker exec` for
everything you do inside it:

- Run commands: `docker exec -u agent -w /workspace $CLEANROOM bash -lc '<cmd>'`
- Inspect files: `docker exec -u agent $CLEANROOM cat /workspace/README.md`
- Write a file: pipe via heredoc or `docker cp`. Easiest pattern is to write the
  file locally first and `docker cp` it in, or use
  `docker exec -i -u agent $CLEANROOM tee /workspace/path/to/file < local_file`.

## What you must produce

A submission as `/workspace/submission.tar.gz` **inside the container**.

The submission archive **MUST** contain, at its root:

1. `compile.sh` — an executable bash script that builds your sources and
   produces `./executable` (literal name) in the working directory. The grader
   runs `chmod +x ./compile.sh && ./compile.sh` and then expects `./executable`
   to exist as a runnable file.
2. Your source files (any layout you like underneath the root).

That is the entire contract. Specifically:

- **Do not ship an `eval/` directory.** The grader supplies its own
  `eval/tests/` from a hidden test branch and will overwrite anything you put
  there.
- **Do not write to `/workspace/cmatrix` or `/workspace/build/<name>`.** The
  grader does not look there. The artifact name is exactly `./executable`.
- **A `Makefile` alone is not enough.** You can use `make` from inside
  `compile.sh`, but you must wrap it: e.g.
  `compile.sh` runs `make && cp <built-binary> executable && chmod +x executable`.
- The grader will create a synthetic `.git` if your submission doesn't ship
  one, so build scripts that need a working tree (e.g., `vergen` for Cargo)
  still work.

A minimal correct submission looks like:

```
submission.tar.gz
├── compile.sh           # bash, executable, produces ./executable
├── Makefile             # optional, can be invoked from compile.sh
├── src/...              # your reimplementation
```

And `compile.sh` looks like:
```bash
#!/bin/bash
set -e
make
cp cmatrix executable     # or whatever your Makefile output is
chmod +x executable
```

(Adjust for the actual program. For a Rust project: `cargo build --release && cp target/release/<bin> executable && chmod +x executable`.)

When you are done, **the very last thing you do** is build the submission tarball:
```
docker exec -u agent -w /workspace $CLEANROOM bash -lc 'tar czf submission.tar.gz compile.sh <other-files>'
```

Verify it's there with `docker exec -u agent $CLEANROOM ls -la /workspace/submission.tar.gz`,
and that compile.sh + executable work locally:
```
docker exec -u agent -w /workspace $CLEANROOM bash -lc 'rm -f executable && chmod +x compile.sh && ./compile.sh && ls -la ./executable && ./executable --help | head -5'
```

Then stop. The harness will pick it up.

## Workflow guidance

1. **Survey the artifact first**: read README, man page, run `./executable --help`,
   run with various flags, observe behavior. Write down what each flag does, the
   I/O contract, error message wording.
2. **Decide on language and architecture** before writing code. Match the
   original's language if you can tell (binary file headers, README mentions, etc.).
3. **Build incrementally**. Get a "hello world" version compiling in the
   container first, then add behavior. Unbuildable submissions score 0.
4. **Test against the original**: run the original binary and your binary side by
   side with the same inputs; diff the outputs. Drive your implementation to match.

## Constraints — read carefully

- **No internet.** You may not browse the web, fetch GitHub repos, hit package
  registries, or otherwise look up the original source code. The cleanroom
  container has `--network none`, but the host you run on does not — **do not
  exploit this**. No `curl`, `wget`, `git clone`, `gh`, `pip install`,
  `npm install`, `cargo install`, etc. on the host either. The harness's
  blocklist will deny most of these but treat the rule as binding regardless.
- **You may use git locally** inside the container or in a scratch dir on the
  host (e.g., `git init`, `git diff`) — what's banned is fetching from the
  network.
- **Genuine reimplementation only - no wrapping or delegating to the original tool's engine.**
  Your submission must implement the behavior yourself, in source code you write. The provided
  `./executable` is for OBSERVATION ONLY (run it to study behavior). You MUST NOT obtain the
  tool's core functionality, at build or run time, from anywhere other than code you write.
  Specifically forbidden:
  - Shelling out to / exec'ing / spawning the original tool or a system binary of the same
    tool (e.g. `/usr/bin/<tool>`, `/usr/local/bin/<tool>`), or shimming to it.
  - Copying, embedding, vendoring, or shipping the provided `./executable`, the tool's
    compiled binary, OR its shared library (e.g. `lib<tool>.so`) - including placing a copy
    of the `.so` inside your submission and loading it.
  - Linking against, `dlopen`-ing, FFI-binding, or `ctypes`-loading the tool's own C library,
    or re-linking its object files.
  - Using a third-party package that binds to, or bundles, the tool's original C engine -
    e.g. a cgo SQLite driver (`mattn/go-sqlite3`), `libsqlite3-sys`, `sqlite-jdbc`, or the PyPI
    `brotli`/`zstandard`/`lz4` wrapper packages. Those ARE the original engine.
  - **Using your language's standard library implementation of the very algorithm the tool
    implements.** If the task is to reimplement a compressor/codec/parser/database engine, you
    may NOT call `python`'s `lzma`/`sqlite3`/`bz2`, Node's `zlib` brotli/gzip codec, Java's
    JDBC, or any equivalent stdlib that simply IS that engine - the standard library counts as
    the original engine for the task's core algorithm. (Ordinary stdlib utilities unrelated to
    the core - file I/O, string handling, argument parsing, generic data structures - are fine.)
  - Installing the tool via a package manager and delegating to it.
  If you cannot fully reimplement the core algorithm, ship your best partial implementation in
  your own code. A low score from an honest reimplementation is the correct outcome; a high
  score obtained by wrapping the original engine is not a valid submission.
- **Stop when you have a submission you believe is your best.** Don't keep
  iterating past diminishing returns.
