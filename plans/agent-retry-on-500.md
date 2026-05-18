# Agent-level retry on Anthropic API 500 errors

Status: not yet implemented.
Scope: harness change only — `harness/sandbox/entrypoint.sh` and `harness/run.sh`.
No arm or evaluation changes.

## Problem

When the agent (`claude -p`, launched from `harness/sandbox/entrypoint.sh`) hits a persistent Anthropic API 500, it does no effective internal retry — it surfaces the error in a `result` event and exits within seconds.
The task then falls through to the empty-tar fallback at `harness/run.sh:177-178` and produces a 29-byte sentinel submission.

Today's only recovery mechanism is the **batch-level resume scan** (`harness/run-batch.sh:108-117`), which on the next batch invocation detects submissions smaller than `MIN_VALID_BYTES=200` and re-queues those tasks from scratch.
That works, but it's coarse: each retry pays the full setup cost again (image pull, container build, agent spin-up, fresh chat history, fresh budget) and loses any partial work the agent did before the outage.

### Evidence from pilot-2 (`run-name=pilot-2`, vanilla arm, 2026-05-16)

A ~13-minute Anthropic API outage between 11:02 and 11:15 PDT produced **48 sentinel submissions** (every one exactly 29 bytes), all with the same end-of-transcript signature:

```
"type": "result"
"subtype": "success"
"is_error": true
"result": "API Error: 500 Internal server error. This is a server-side issue, usually temporary…"
```

Detail per task type:

- Tasks that had been running before the outage hit (e.g. `ducaale__xh.4a6e44f`) burned ~27 minutes and a couple dollars before bailing.
- Tasks dispatched during the outage (e.g. `htop-dev__htop.523600b`) exited in **6 seconds with $0.001 spent** — `claude -p` made one attempt, got the 500, and quit.
- Aggregate waste across the cluster: **$17.18 in API cost, 79 min of wall time**.

When the batch resumed two hours later (API was healthy by then), all 48 sentinels were re-queued and most succeeded — but each retry was a full re-run, not a continuation.

### Why this matters

1. **Cost**: an in-process retry that reuses the existing chat history costs only cache-read tokens to continue, not a fresh build-up of context.
2. **Quality**: the result of a continued session is a single coherent run; a from-scratch retry can produce different code, different test choices, different submissions. For a comparison study, narrower variance per task is better.
3. **Throughput**: re-running long-tail tasks (e.g. xh's 27 min prefix) wastes wall time that's already in short supply at parallel=1 or 2.

## Goal

When `claude -p` exits because of a transient 500, the entrypoint should detect this, sleep briefly with exponential backoff, then resume **the same Claude session** with a continuation prompt — without leaving the agent container.
The cleanroom workspace already survives across attempts because it's a separate container that the agent only touches via `docker exec`, so any partial work the agent had already done is still on disk under `/workspace` and visible to the resumed session.

The resume mechanism is already in Claude Code (`claude --resume <session-id>`), but it requires session persistence, which `entrypoint.sh:96` currently disables via `--no-session-persistence`.

This feature is **opt-in** behind `PB_AGENT_500_RETRY=1` so it can be merged and rolled out gradually without disturbing arms that are mid-run.

## Implementation outline

All changes live in two files:

### 1. `harness/sandbox/entrypoint.sh`

Currently the file makes one `claude -p` call (line 90) with `--no-session-persistence` and redirects output to `$LOG_OUT/transcript.jsonl` with `>` (overwrite).

Replace that single call with a retry loop, gated on `PB_AGENT_500_RETRY=1`. Behavior when disabled is identical to today.

Pseudocode:

```bash
RETRY_ENABLED="${PB_AGENT_500_RETRY:-0}"
MAX_ATTEMPTS="${PB_AGENT_500_MAX_ATTEMPTS:-5}"
BACKOFFS=(30 60 90 120 180)        # seconds, indexed by retry count (attempt 0 = first try, no sleep)
SESSION_ID="$(uuidgen)"
REMAINING_BUDGET="$BUDGET"
ATTEMPT=0
ELAPSED_RETRY_SLEEP_S=0

# First attempt: original prompt, --session-id, NO --no-session-persistence
# Retry attempts: --resume "$SESSION_ID", short continuation prompt, --max-budget-usd "$REMAINING_BUDGET"

while (( ATTEMPT < MAX_ATTEMPTS )); do
  if (( ATTEMPT == 0 )); then
    PROMPT="$TASK_PROMPT"
    EXTRA_FLAGS=(--session-id "$SESSION_ID")
  else
    PROMPT="Your previous attempt was interrupted by a transient API error. The cleanroom container (\$CLEANROOM) and your workspace are intact. Continue where you stopped; do not restart from scratch."
    EXTRA_FLAGS=(--resume "$SESSION_ID")
  fi

  CLEANROOM="$CONTAINER" claude -p \
    --setting-sources "$SETTING_SOURCES" \
    --strict-mcp-config --mcp-config "$MCP_PATH" \
    --settings "$RENDERED_SETTINGS" \
    --model "$MODEL" \
    --max-budget-usd "$REMAINING_BUDGET" \
    --output-format stream-json \
    --include-partial-messages \
    --verbose \
    --append-system-prompt "$SYSTEM_PROMPT" \
    --disallowed-tools $DISALLOWED_FLAT \
    --permission-mode bypassPermissions \
    "${EXTRA_FLAGS[@]}" \
    "$PROMPT" \
    >> "$LOG_OUT/transcript.jsonl" 2>> "$LOG_OUT/claude.stderr" \
    || true                # don't trip set -e on agent non-zero exit

  # Success path: submission produced in the cleanroom → break out, run.sh extracts it
  if docker exec -u agent "$CONTAINER" test -f /workspace/submission.tar.gz; then break; fi

  # Inspect the last result event in transcript.jsonl
  LAST_RESULT="$(grep '"type":"result"' "$LOG_OUT/transcript.jsonl" | tail -n 1 || true)"

  # Spend tracking: subtract this attempt's cost from REMAINING_BUDGET
  ATTEMPT_COST="$(jq -r '.total_cost_usd // 0' <<<"$LAST_RESULT")"
  REMAINING_BUDGET="$(awk -v r="$REMAINING_BUDGET" -v c="$ATTEMPT_COST" 'BEGIN{printf "%.4f", r-c}')"
  awk -v r="$REMAINING_BUDGET" 'BEGIN{exit (r > 0.50) ? 0 : 1}' || break    # under $0.50 left → not worth retrying

  # Retry only if (a) opt-in enabled, (b) this looks like a 500, (c) no submission landed
  IS_500=0
  if [[ "$RETRY_ENABLED" == "1" ]] && jq -e 'select(.is_error==true) | .result | tostring | test("API Error.*5[0-9][0-9]|Internal server error")' <<<"$LAST_RESULT" >/dev/null 2>&1; then
    IS_500=1
  fi
  (( IS_500 == 1 )) || break

  SLEEP="${BACKOFFS[$ATTEMPT]:-300}"
  echo "[entrypoint] API 500 detected; sleeping ${SLEEP}s before retry $((ATTEMPT+1))/$MAX_ATTEMPTS (remaining budget=\$$REMAINING_BUDGET)" >&2
  ELAPSED_RETRY_SLEEP_S=$(( ELAPSED_RETRY_SLEEP_S + SLEEP ))
  echo "$ELAPSED_RETRY_SLEEP_S" > "$LOG_OUT/.retry-sleep-seconds"      # see "Pause-time exclusion" below
  # Heartbeat so the run.sh watchdog doesn't think the agent is idle (see below)
  ( while (( SLEEP > 0 )); do
      printf '{"type":"heartbeat","reason":"retry-backoff","ts":"%s"}\n' "$(date -u +%FT%TZ)" >> "$LOG_OUT/transcript.jsonl"
      sleep 20
      SLEEP=$((SLEEP - 20))
    done )
  ATTEMPT=$((ATTEMPT + 1))
done
```

Notes:

- `uuidgen` is available in the agent image (POSIX util). If not, generate via `python3 -c 'import uuid; print(uuid.uuid4())'`.
- `jq` is used to read JSON from the transcript. If not in the agent image already, add it via `Dockerfile.agent` (one apt line). Don't fall back to grep+sed; the regex bugs aren't worth it.
- `>>` not `>` for transcript: the file must accumulate events from all attempts so it reads as one continuous run.
- The heartbeat subshell writes a benign line every 20s while sleeping. It uses a custom `"type":"heartbeat"` so it never matches the watchdog's `"type":"result"` grep and so the scoring code (if it ever parses the transcript) can ignore the line.

### 2. `harness/run.sh` — watchdog adjustments

The watchdog at `harness/run.sh:139-169` uses wall time for both `TIMEOUT_SEC` (absolute) and `LAST_GROW_TS` (transcript-idle). During retry sleeps:

- **Idle check (`IDLE_KILL_SEC`, `PRERESULT_IDLE_SEC`)** — already addressed by the heartbeat lines above. The watchdog re-reads `wc -c` of the transcript each iteration; heartbeat writes will keep `LAST_GROW_TS` fresh.
- **Absolute timeout (`TIMEOUT_SEC=7200`)** — *not* addressed by heartbeat. The wall clock keeps moving during sleep, and the watchdog kills the agent unconditionally once `ELAPSED >= TIMEOUT_SEC`. If a task is 90% of the way through `TIMEOUT_SEC` when the API outage hits, 3 minutes of backoff sleep could push it over.

Fix: each iteration of the watchdog loop reads an optional `${LOG_OUT}/.retry-sleep-seconds` file (entrypoint writes the cumulative retry-sleep count there). The effective elapsed wall time becomes:

```bash
RETRY_SLEEP=0
[[ -f "$LOG_OUT/.retry-sleep-seconds" ]] && RETRY_SLEEP=$(cat "$LOG_OUT/.retry-sleep-seconds" 2>/dev/null || echo 0)
ELAPSED=$(( NOW - START_TS - RETRY_SLEEP ))
```

This means the wall-clock budget the agent has for productive work is preserved across retries.
The total runtime of the task (host POV) can still go to `TIMEOUT_SEC + sum(backoffs)` ≈ `7200 + 480 = 7680s` in the worst case, which is acceptable.

The same `RETRY_SLEEP` correction does **not** need to be applied to the per-attempt idle checks, since those reset whenever the transcript grows.

## Files to modify

| File | Change |
|---|---|
| `harness/sandbox/entrypoint.sh` | Replace single `claude -p` call (line 90 area) with retry loop; remove `--no-session-persistence`; switch `>` to `>>` on transcript redirection; write `$LOG_OUT/.retry-sleep-seconds`; emit heartbeat lines during backoff. |
| `harness/run.sh` | In the watchdog loop (`run.sh:139-169`), subtract `RETRY_SLEEP` from `ELAPSED` before comparing to `TIMEOUT_SEC`. |
| `harness/sandbox/Dockerfile.agent` | Add `jq` if not already installed. Verify `uuidgen` is present (it's part of `util-linux`). |
| `AGENTS.md` (top-level) | Document `PB_AGENT_500_RETRY` and `PB_AGENT_500_MAX_ATTEMPTS` env vars under the "Tunables" table. |

## Acceptance criteria

1. With `PB_AGENT_500_RETRY=0` (default), behavior matches today exactly. Existing pilot runs are unaffected.
2. With `PB_AGENT_500_RETRY=1`:
   - When the agent hits a 500-class API error and no submission has been produced, entrypoint sleeps with backoff and re-invokes `claude -p --resume`.
   - The resumed Claude session continues from prior chat state (test by injecting a non-500 conversational turn before triggering 500: the second attempt should reference the earlier turn).
   - The transcript file is a single concatenation of all attempts with no truncation.
   - Total cost across all attempts is bounded by the original `--budget`, not N × budget. Verify by summing `total_cost_usd` across `result` events in the multi-attempt transcript: sum ≤ `$BUDGET`.
   - `${LOG_OUT}/.retry-sleep-seconds` exists and reflects cumulative backoff after retries.
3. The `run.sh` watchdog does not fire `TIMEOUT_SEC` or idle kills purely because of retry sleeps.

## Testing plan

A real 500 is hard to provoke on demand. Three options ordered by realism:

1. **Synthetic 500 injection via the proxy** *(recommended)*. The agent's outbound HTTPS goes through `pb/proxy` (`harness/sandbox/Dockerfile.proxy`, `tinyproxy.conf`). Add a one-shot "return 500 for the next N requests" mode controllable via env var, e.g. `PB_PROXY_INJECT_500_COUNT=3`. The proxy intercepts the first 3 requests with a synthetic 500 response, then forwards normally. Run a quick smoke task and verify:
   - First 3 turns in the agent's session each surface a 500 in the transcript.
   - Each is followed by a `[entrypoint] API 500 detected` log line.
   - After the 3rd retry the proxy serves real traffic and the agent completes.
   - Submission lands successfully.
2. **Live smoke without injection** — run two arms (with retry on and off) against the same small set of tasks during a quiet period. Compare submission quality and total cost. No 500s expected, so this only validates that the retry code path doesn't regress the happy path.
3. **Post-hoc replay** — keep the pilot-2 original-attempt transcripts (the ones written 11:02-11:15) somewhere. After implementing, simulate by replaying the same transcript prefix and verifying the retry decision logic fires on the recorded 500.

Path 1 is the only one that exercises the full feature. The proxy change is small (~20 lines in `tinyproxy.conf` filter or a small reverse proxy script).

## Risks and edge cases

- **Continuation prompt quality.** If the retry prompt doesn't successfully redirect the agent to look at `/workspace`, it might re-start from zero. Manual review of the first few retries in real runs is needed. Worst case is no different from today: empty submission → batch-level retry on resume.
- **Session file location inside container.** Claude Code stores sessions at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Verify that path is writable for the `node` user (entrypoint drops to `node` at line 27) and that `RUN_CWD` doesn't get destroyed mid-flight. It's a `mktemp -d` directory under `/tmp` so it should persist for the lifetime of the agent container.
- **Cache-read pricing on resume.** A long session resumed many times pays cache-read tokens each turn. Quantify on the first real run: compare `cache_read_input_tokens` across attempts.
- **Concurrent retries at parallel ≥ 2.** No shared state between concurrent tasks (each has its own session id, cleanroom, agent container, log dir), so no interaction expected. Confirm by running 2-task parallel smoke with injected 500s in both.
- **Non-500 errors.** The retry decision matches on `API Error.*5[0-9][0-9]|Internal server error`. Don't retry on `overloaded_error` (429), `permission_denied`, `invalid_request_error`, or `model_not_found` — these are not transient. The implementation must check the error class, not just `is_error==true`. The current jq regex only matches 5xx-style messages; verify against actual error message formats Claude Code emits.
- **uuidgen availability.** If `uuidgen` is missing in the agent image, the first attempt will fail before claude is even invoked. Use a Python fallback or add `util-linux` to `Dockerfile.agent`.
- **Budget edge case.** If `REMAINING_BUDGET` drops below `--max-budget-usd`'s minimum-supported value, the next `claude -p` call may error on flag parsing. Floor at $0.50 (the early-exit check) and abort retries below that.

## Out of scope

- Making `claude -p` itself retry 500s internally — that's an upstream Claude Code change.
- Retrying on 429 / rate limiting — separate problem, separate fix (probably a sleep without `--resume`).
- Reattempting after a `TIMEOUT_SEC` or `IDLE_KILL` kill — those mean the agent went bad in ways resuming won't fix.
- Cross-process resume (e.g. resuming after `run.sh` itself was killed). The session files live inside the agent container, which is torn down at end of run; this design is intentional and not changed here.

## Reference

- Original sentinel cluster: `runs/pilot-2/vanilla/<task>/submission.tar.gz` size 29 bytes, mtimes 2026-05-16 11:02-11:15 PDT.
- Memory entry: see `pilot-2-api-outage.md` in `~/.claude/projects/-Users-kunchen-github-kunchenguid-programbench-bench/memory/` for the post-mortem context.
- Claude Code session flags: `claude -p --help` documents `--session-id`, `--resume`, `--no-session-persistence`.
- Empty-tar fallback: `harness/run.sh:177-178`.
- Batch-level resume threshold: `harness/run-batch.sh:40` (`MIN_VALID_BYTES=200`).
