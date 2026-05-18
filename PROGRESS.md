# Run progress

Tracks the state of long-running batch runs so they're not lost across pauses, session restarts, or quota windows.

## pilot-2 (Claude Opus 4.7, arm: `vanilla`)

**Status: PAUSED** — manually killed at 2026-05-18 ~08:13 PDT to free Anthropic quota for other work.

### On-disk state at pause

| | Count |
|---|---|
| Valid submissions (>= 200 bytes) | 154 |
| Sentinels (29-byte empty-tar fallback) | 46 |
| **Total** | **200** |

Resume scan (`harness/run-batch.sh:108-118`) will treat the 46 sentinels as not-done and re-queue them.

Note: total is 200 (not 201) because `testorg__calculator.abc1234` is now in `EXCLUDED_TASKS` in `run-batch.sh` - it's a synthetic scaffold task without a published cleanroom image, so it never produced a real submission for either arm.
The `chroma` task (known `results_read_failed` eval pipeline bug, see `CLAUDE.md` "Known gotchas") submitted successfully but will score 0 at report time - both arms hit it; neutral to the comparison.

### History of sentinel sources (so we know why each task was retried)

The 46 sentinels at pause come from three distinct events earlier in pilot-2's life:

1. **API outage 2026-05-16 11:02-11:15 PDT** — 48 tasks hit `API Error: 500 Internal server error`, alphabetically from `drew-alleman__datasurgeon` to `konradsz__igrep`. ~$17.18 / 79 min wasted. See `~/.claude/projects/.../memory/project_pilot-2-api-outage.md` for the post-mortem. Most were retried successfully when pilot-2 resumed.
2. **Quota exhaustion 2026-05-17 02:31-07:51 PDT** — 87 tasks hit `You've hit your org's monthly usage limit` (67) or `You're out of extra usage` (20) before the user's quota refilled. ~$0 wasted (these bailed in <1s). Most were retried successfully on subsequent resume.
3. **In-flight kill 2026-05-18 ~08:13 PDT** — `sharkdp__hyperfine.327d5f4` was 3 min into its task when this pause was triggered. Will be retried on resume.

If anything looks suspicious at scoring time, suspect overlap between (1), (2), (3) and tasks that legitimately produced poor submissions.

### Resume command

When quota is back:

```sh
cd /Users/kunchen/github/kunchenguid/programbench-bench
nohup ./harness/run-batch.sh \
  --arms vanilla --slice 0:201 \
  --run-name pilot-2 --parallel 1 \
  >> /tmp/pilot-2-full.log 2>&1 &
echo $! > /tmp/pilot-2-full.pid
```

Then re-arm the dual-batch health-check cron (see `CLAUDE.md`) if codex-pilot-1 is still running, or the pilot-2-only cron if codex has finished.

### Files of interest

- Submissions: `runs/pilot-2/vanilla/<task>/submission.tar.gz`
- Transcripts: `logs/pilot-2/vanilla/<task>/transcript.jsonl`
- Per-task runner logs: `logs/pilot-2/_batch/vanilla__<task>.log`
- Batch driver log (append-mode, survives resumes): `/tmp/pilot-2-full.log`

## codex-pilot-1 (OpenAI gpt-5.5, arm: `codex-vanilla`)

**Status: COMPLETE** - finished naturally on 2026-05-18.
Final batch line: `[batch] done in 56534s.  total=201  completed=200  failed=1  skipped=0`
Wall time: ~15h 42m.

### On-disk state

| | Count |
|---|---|
| Valid submissions (>= 200 bytes) | 200 |
| Sentinels (29-byte empty-tar fallback) | 0 |
| **Total** | **200** |

Notably cleaner than pilot-2 (no sentinels). The original `failed=1` in the batch line was `testorg__calculator.abc1234` (no published cleanroom image); that task has since been added to `EXCLUDED_TASKS` in `run-batch.sh` and its empty artifact dirs removed, so the effective denominator is 200.

### Next step

Score the run when ready:

```sh
cd /Users/kunchen/github/kunchenguid/programbench-bench
./harness/score-and-report.sh --run codex-pilot-1 --arms codex-vanilla
```

Cross-arm comparison vs pilot-2 (Claude vanilla) is gated on pilot-2 finishing the remaining 46 sentinels once Anthropic quota is back.

### Files of interest

- Submissions: `runs/codex-pilot-1/codex-vanilla/<task>/submission.tar.gz`
- Transcripts: `logs/codex-pilot-1/codex-vanilla/<task>/transcript.jsonl`
- Per-task runner logs: `logs/codex-pilot-1/_batch/codex-vanilla__<task>.log`
- Batch driver log: `/tmp/codex-pilot-1-full.log` (ephemeral - copy to `logs/codex-pilot-1/batch.log` if you want it durable; see `plans/persist-batch-log.md`)
