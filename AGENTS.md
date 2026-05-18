# AGENTS.md

Notes for any agent (Claude or otherwise) working in this repo.
Read this file before taking actions that change long-running state.

## What this repo is

Harness comparison study on ProgramBench, holding the model constant (Claude Opus 4.7) and varying the agent harness across arms (`vanilla`, `gstack-curated`).
See `README.md` for the experimental framing.
The eval is expensive in API quota and wall time, so operational mistakes are costly.

## Long-running evaluations: always supervise

Eval batches run detached via `nohup ./harness/run-batch.sh ... &`.
At parallel=1 a full pilot of 402 task-arm pairs takes roughly 4 days (2.3 tasks/hr observed historically).
Because the agent's REPL session is the only thing watching the batch, **you must arm a periodic health monitor whenever you launch or resume a run**.

### How to launch (or resume) a batch

The same command kicks off a fresh run and resumes a paused one - resume logic is driven by what's on disk, not by flags.
Pick a `<run-name>` (e.g. `pilot-2`); it determines the paths under `runs/`, `logs/`, and `/tmp/`.

```sh
cd /Users/kunchen/github/kunchenguid/programbench-bench
RUN_NAME=<run-name>

nohup ./harness/run-batch.sh \
  --arms vanilla,gstack-curated \
  --slice 0:201 \
  --run-name "$RUN_NAME" \
  --parallel 1 \
  > "/tmp/${RUN_NAME}-full.log" 2>&1 &
echo $! > "/tmp/${RUN_NAME}-full.pid"
```

Resume semantics: any task with a `submission.tar.gz` >= 200 bytes is skipped on the next run.
Below 200 bytes (the 29-byte empty-tar sentinel from killed tasks) is treated as not-done and retried.

### Required: arm a periodic health check after launching a batch

Right after kicking off `run-batch.sh`, schedule a cron job firing roughly every 25 minutes.
Use an off-herd minute pattern such as `7,32,57 * * * *` rather than `*/25 * * * *` (which lands on :00).

Each fire should run these checks against the current `<run-name>` and report a 4-6 line `OK / WARN / FAIL` status:

1. **Batch alive** — `cat /tmp/<run-name>-full.pid && ps -p $(cat /tmp/<run-name>-full.pid) -o pid,etime,pcpu,pmem,command`.
   If the process is dead, surface loudly and **do not auto-restart** - ask the user.
2. **Progress** — `tail -n 5 /tmp/<run-name>-full.log` to see the latest task and running done/failed/remaining counts.
3. **System resources** — `top -l 1 -n 0 | head -n 10` plus `df -h /`.
   Flag memory pressure, load avg > number of cores, or disk < 10% free under `runs/`.
4. **Docker** — `docker ps --format 'table {{.Names}}\t{{.Status}}' | head -n 5`.
   At parallel=1 there should be at most one task container live at a time.

### Caveats to tell the user when arming the monitor

- `CronCreate` defaults to session-only; if the Claude session closes, the monitor dies (the nohup'd batch keeps running, just unsupervised). Offer `durable: true` if they want it to survive across sessions.
- Recurring cron jobs auto-expire after 7 days.
  A parallel=1 pilot needs ~4 days, so one arming usually covers it - re-arm if it runs long.

## Tunables

In `harness/run.sh` (all overridable via env vars):

| Var                      | Default | Meaning                                                                 |
| ------------------------ | ------- | ----------------------------------------------------------------------- |
| `PB_BUDGET_USD`          | 50      | API budget per task                                                     |
| `PB_TIMEOUT_SEC`         | 7200    | Hard kill at 120 min                                                    |
| `PB_IDLE_KILL_SEC`       | 180     | Kill if idle 3 min after a result                                       |
| `PB_PRERESULT_IDLE_SEC`  | 900     | Kill if idle 15 min, no result yet                                      |
| `PB_AUTO_COMPACT_WINDOW` | 400000  | `claude -p` auto-compacts at this token cap (saves quota on long tasks) |

## Scoring a finished run

```sh
./harness/score-and-report.sh --run <run-name> --arms vanilla,gstack-curated
```

Writes the report to stdout and `runs/<run-name>/per-task.csv`.

## Things to never do without asking

- Restart a batch that has died mid-run.
  Ask the user first - there may be a quota, billing, or resource reason it died.
- Change `--parallel` upward.
  The user has specifically asked for parallel=1 to control resource and cost.
- Delete files under `runs/<run-name>/` or `logs/<run-name>/`.
  These are the durable submissions and transcripts the score script reads.
- Force-kill the batch process to "clean up" - prefer letting in-flight tasks finish, since killed tasks waste API spend.

## codex-vanilla arm (prototype)

The `codex-vanilla` arm runs OpenAI Codex CLI (`@openai/codex`) against
the same cleanroom topology, holding "frontier reasoning model" roughly
constant.
See `SMOKE.md` at the repo root for status, known limitations, and the
first-time smoke checklist.

- Model: `gpt-5.5` (literal id accepted by Codex CLI 0.130.0).
- Auth: host's `~/.codex/auth.json` is bind-mounted read-only into the
  agent container at `/home/node/.codex/auth.json`.
  Run `codex login` once on the host before launching.
- Per-task runner: `harness/run-codex.sh` (sibling of `run.sh`).
- Batch routing: arm names prefixed with `codex-` are dispatched to
  `run-codex.sh` automatically by `run-batch.sh`.
- Proxy: new whitelist entries cover `api.openai.com`, `auth.openai.com`,
  `chatgpt.com`, and `ab.chatgpt.com`.
  See `harness/sandbox/filter`.
- Launch (single task):
  `./harness/run-codex.sh --arm codex-vanilla --task <id> --run-name codex-smoke --budget 1`
- Launch (batch): same as Claude arms; just pass `--arms codex-vanilla`.

Known caveats specific to this arm:

- Codex CLI 0.130.0 has no `--max-budget-usd` / `--max-turns` flag.
  `--budget` to `run-codex.sh` is informational.
  Wall-clock watchdog is the only ceiling.
- The watchdog uses the pre-result idle threshold uniformly (Codex's
  event stream doesn't have a `type:"result"` marker the way Claude
  does).
- `auth.json` is mounted read-only; any token refresh write-back will
  fail silently.
  In-memory refreshed tokens still work for the run's duration.

## Known gotchas

- **chroma** (`alecthomas__chroma.8d04def`): programbench's eval pipeline can time out reading test results for this task (`results_read_failed`) regardless of our submission. Both arms hit this and score 0 - neutral to the comparison.
- Reboots are safe: durable submissions on disk are all the resume logic needs; no in-memory state.
- `OPENCLAW_SESSION=1` (set in `harness/run.sh`) makes gstack skills auto-decide on AskUserQuestion, so the in-container agent never blocks on a prompt.

## Files of interest

- `harness/run-batch.sh` - the batch driver (routes `codex-*` arms to `run-codex.sh`)
- `harness/run.sh` - single-task runner (Claude Code arms)
- `harness/run-codex.sh` - single-task runner (OpenAI Codex CLI arms)
- `harness/sandbox/Dockerfile.codex` - Codex agent container image
- `harness/sandbox/entrypoint-codex.sh` - in-container entrypoint for the codex arm
- `harness/score-and-report.sh` - score a finished run
- `/tmp/<run-name>-full.log` - append-mode batch log (survives across resumes)
- `/tmp/<run-name>-full.pid` - current batch PID
- `runs/<run-name>/<arm>/<task>/submission.tar.gz` - durable per-task submissions
- `logs/<run-name>/<arm>/<task>/transcript.jsonl` - per-task agent transcripts
- `logs/<run-name>/_batch/<arm>__<task>.log` - per-task runner logs
