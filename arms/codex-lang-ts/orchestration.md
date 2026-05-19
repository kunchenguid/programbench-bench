# Orchestration (mandate: TypeScript)

Your implementation language is **TypeScript (Node 20 + tsc 5.5 / ts-node)**. Compile with `tsc` (or run via `ts-node`) and have `./executable` run the result with node. The npm offline cache is at **/opt/deps/ts/cache**. You MUST write TypeScript.

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
