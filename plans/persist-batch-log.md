# Persist the batch driver log under `logs/<run>/`

Status: not yet implemented.
Scope: small change in `harness/run-batch.sh` only.

## Problem

The batch driver (`harness/run-batch.sh`) writes its `[batch] >>> ...`, `[batch] OK ...`, `[batch] FAIL ...`, and `[batch] done in Xs` lines to whatever stdout the launching shell hands it.
Every invocation in `CLAUDE.md` and in practice redirects that to `/tmp/<run-name>-full.log`.
`/tmp` is volatile on macOS - a reboot wipes it.

What you lose if `/tmp` is wiped:

1. **The exact order tasks were dispatched.**
   The per-task runner logs under `logs/<run>/_batch/<arm>__<task>.log` still exist, but they don't form a single chronological stream across tasks.
2. **Batch-level running counts** (the `(N done, M failed, K remaining)` snapshots).
   These let you reconstruct progress over time without re-deriving from filesystem timestamps.

These are pure forensic value, not load-bearing for resume.
The resume scan only reads `submission.tar.gz` sizes on disk, which live under `runs/<run>/` and are already durable.

## Goal

Tee the batch driver's stdout to a durable file at `logs/<run>/batch.log` alongside the existing per-task runner logs.
Keep the existing `/tmp/<run-name>-full.log` redirect working unchanged (useful for `tail -f` and the periodic health-check cron, which both expect that path).

End state per run:

- `logs/<run>/batch.log` - durable, append-mode, every batch invocation against this run appends.
- `/tmp/<run-name>-full.log` - ephemeral, redundant copy, exactly the same content for tail convenience.

## Implementation

One edit in `harness/run-batch.sh`.
After the `mkdir -p "$REPO/logs/$RUN_NAME/_batch"` at line 135 (or wherever `LOG_DIR` is established), add:

```bash
# Persist batch driver output under logs/<run>/ so it survives /tmp wipes / reboots.
# The caller's stdout redirect (typically /tmp/<run>-full.log) keeps working
# unchanged because we pipe through tee, which writes to BOTH the file and stdout.
exec > >(tee -a "$REPO/logs/$RUN_NAME/batch.log") 2>&1
```

That's it.
Verify by running a tiny smoke (e.g. `--tasks <one-id> --run-name persist-smoke`) and confirming `logs/persist-smoke/batch.log` ends up with the same content as `/tmp/persist-smoke-full.log`.

### Edge cases

- The `exec > >(tee ...)` pattern uses bash process substitution.
  Process substitution can produce out-of-order output relative to spawning subprocesses (the tee process may keep running briefly after the script exits).
  For a long-running batch this is fine; for very short invocations the final `[batch] done in ...` line may not flush before exit.
  Mitigation: `wait` at end of script, or accept the trailing-line risk.
  For our use the trailing-line risk is acceptable - the per-task `OK` lines are the load-bearing ones, and they fire long before script exit.
- `set -e` interacts oddly with failures inside process substitution.
  The `tee` here is benign; failure would only happen if the disk is full, in which case the rest of the run is dead anyway.
- The append (`-a`) lets multiple invocations against the same run-name (e.g. resume) keep adding to the same `batch.log`.
  Same semantics as the existing `>> /tmp/<run>-full.log` redirect in current launch commands.

## Backfilling in-flight batches

In-flight batches are bash processes that already parsed `run-batch.sh` at launch.
Bash caches function definitions and `exec` redirects, so editing the script does not retroactively change a running batch's stdout target.

If a batch is in flight when this change lands, do a one-shot snapshot:

```sh
RUN=codex-pilot-1  # or pilot-2, etc.
mkdir -p "logs/$RUN"
cp "/tmp/${RUN}-full.log" "logs/${RUN}/batch.log"
```

Re-snapshot once the batch finishes, since `/tmp` keeps growing while the new file is frozen at copy time.

## Documentation updates

Once shipped, add a line to `CLAUDE.md` "Long-running evaluations" section noting that `logs/<run>/batch.log` is the durable log and `/tmp/<run>-full.log` is the convenience copy.
Update `PROGRESS.md` reconstruction recipe (the "What we did NOT save" section that lists dispatch order and batch counts as ⚠️) to remove those caveats.

## Out of scope

- Moving the PID file out of `/tmp`.
  It's trivially regeneratable via `ps` and not load-bearing for anything except quick health-checks.
- Changing the launch command convention.
  Existing commands keep working; this is purely additive durability.
- Persisting the `programbench eval` per-test logs.
  Separate concern, separate fix; documented in `PROGRESS.md` under "What we did NOT save".
