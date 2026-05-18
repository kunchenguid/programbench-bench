<h1 align="center">programbench-bench</h1>

<p align="center">
  <a href="https://arxiv.org/abs/2605.03546"
    ><img
      alt="ProgramBench paper"
      src="https://img.shields.io/badge/paper-2605.03546-b31b1b?style=flat-square"
  /></a>
  <a href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://img.shields.io/badge/model-Claude%20Opus%204.7-8a4ce0?style=flat-square"
    ><img
      alt="Model"
      src="https://img.shields.io/badge/model-Claude%20Opus%204.7-8a4ce0?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
</p>

<h3 align="center">ProgramBench measures models. This measures harnesses.</h3>

The [ProgramBench paper](https://arxiv.org/abs/2605.03546) evaluates nine LLMs on 201 reverse-engineering tasks. Every model runs through the same agent (mini-swe-agent), and the authors say so explicitly:

> _"We use mini-SWE-agent because it is ... deliberately minimal in its scaffolding, reducing confounds between model capability and harness design."_

That choice was _justified_ in the paper. But **does different agent harness behaviors move the score?** Nobody published the answer.

This repo runs the inverse experiment. We hold the model constant (**Claude Opus 4.7**) and vary the harness:

- **vanilla** — stock Claude Code, no skills, no MCP, blank settings.
- **gstack-curated** — same Claude Code, plus five [gstack](https://github.com/garrytan/gstack) skills (`plan-eng-review`, `investigate`, `review`, `health`, `careful`) and an orchestration prompt that mandates invocation at named phases.

Each arm runs against the full ProgramBench suite. We compare them paired, per task. **Either outcome is informative**: a meaningful effect would be a real harness signal; a null result would corroborate the paper's "minimal is fine" premise.

- **Hermetic by construction** — the agent's tools cannot reach the internet. Cleanroom Docker container is `--network none`; agent runs in a separate container whose only egress is a tinyproxy whitelist (`api.anthropic.com` + Anthropic feature-flag endpoints).
- **Reproducible by anyone** — only operator-side dependencies are Docker, `uv`, and a `claude setup-token` OAuth token. No keychain, no local Claude config bleed-through.
- **Pluggable evaluation targets** — an "arm" is a directory under `arms/`. New comparisons (with-MCP-X, with-codex, gpt-5.5) drop in as new directories with no harness changes.

## Quick Start

```sh
$ uv venv cache/pb-venv && source cache/pb-venv/bin/activate
$ uv pip install programbench scipy numpy

$ claude setup-token                 # interactive browser flow, one-time
$ echo "<token>" > .claude-oauth-token

$ ./harness/run-batch.sh \
    --arms vanilla,gstack-curated \
    --slice 0:10 \
    --run-name pilot-1 \
    --parallel 3 \
    --budget 8
[batch] arms=vanilla gstack-curated  tasks=10  parallel=3  run=pilot-1
[batch] resume: skipping 0 already-complete jobs; 20 to run
[batch] >>> vanilla/abishekvashok__cmatrix.5c082c6 (pid 94791)
...
[batch] done in 7341s.  total=20  completed=20  failed=0  skipped=0

$ programbench eval runs/pilot-1/vanilla
$ programbench eval runs/pilot-1/gstack-curated

$ ./harness/analyze.py --run pilot-1 --arms vanilla,gstack-curated
# programbench-bench report  (run: pilot-1)
## Per-arm summary
arm                n   mean%  ...
vanilla           10    42.1  ...
gstack-curated    10    48.7  ...
## Paired comparisons
=== gstack-curated vs vanilla  (paired on 10 tasks) ===
  Δ mean %     +6.6   95% CI [+1.1, +12.0]   wilcoxon p=0.04
  ...
```

## Install

**macOS (Apple Silicon)** — Docker Desktop must use Apple Virtualization framework + Rosetta x86*64 emulation. Verify in \_Settings → General*.

**Linux x86_64** — works natively, no special config.

```sh
git clone https://github.com/kunchenguid/programbench-bench
cd programbench-bench
uv venv cache/pb-venv && source cache/pb-venv/bin/activate
uv pip install programbench scipy numpy
```

ProgramBench cleanroom images are ~1-3 GB each. The harness prunes them after each task by default; allow ~5 GB free disk per concurrent task slot.

## How It Works

Each task runs three Docker containers on a network-isolated topology:

```
                    Anthropic API
                        ▲
                        │ HTTPS (whitelisted)
                        │
              ┌─────────┴──────────┐
              │   pb/proxy         │  tinyproxy
              │   (bridge ←→ int)  │  allow: api.anthropic.com
              └─────────┬──────────┘
                        │
              ┌─────────┴──────────┐         ┌────────────────────┐
              │   pb/agent         │         │   cleanroom        │
              │   claude -p        │ docker  │   (--network none) │
              │   HTTPS_PROXY=...  │ exec  ► │   /workspace/      │
              │   OAUTH_TOKEN      │ via     │   ├─ executable    │
              │   (--internal net) │ socket  │   ├─ README.md     │
              └────────────────────┘         │   └─ ...docs       │
                                             └────────────────────┘
```

- **The agent never reaches the internet directly.** Its container is on a Docker `--internal` network. Outbound goes through the proxy, which has a hard domain whitelist.
- **The cleanroom is fully air-gapped.** `--network none` is kernel-enforced. The agent talks to it via `docker exec` (mounted Unix socket), not networking.
- **Auth lives in an env var.** `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` — bills against the Claude subscription, not API credits, and works without macOS Keychain access.
- **Per-arm config is purely declarative.** Arms drop SKILL.md files into a planted `.claude/skills/` directory; the harness uses `--setting-sources project,local --strict-mcp-config` to keep the operator's own Claude Code config from leaking in.

### Methodology

| Layer            | What we measure                                                                                                                                                 |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Per-task         | `% tests passed` (matches `programbench info`'s mean score) — linear, sensitive to partial progress, not subject to ProgramBench's near-zero `% Resolved` floor |
| Threshold ladder | `>0`, `≥25`, `≥50`, `≥80`, `≥95`, `=100` task counts — surfaces _where_ the effect lives                                                                        |
| Comparison       | paired Δ on per-task scores, with bootstrap CI and Wilcoxon signed-rank; McNemar at each ladder threshold for win/loss bookkeeping                              |

`% Resolved` (the paper's primary) is degenerate at our scale — the best published model resolves only 3% of tasks. We report it as a footnote for leaderboard comparability but it carries almost no signal between two arms.

## CLI Reference

| Command                                           | Description                                                                                   |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `harness/run.sh --arm <a> --task <t>`             | Run one (arm, task) end-to-end inside the sandbox topology.                                   |
| `harness/run-batch.sh --arms <a,b> --slice <i:j>` | Iterate a batch with parallelism, resume from existing submissions, retry transient failures. |
| `harness/analyze.py --run <name> --arms <a,b>`    | Deterministic report: per-arm summary, threshold ladder, paired stats, per-task CSV.          |
| `programbench eval runs/<run>/<arm>`              | Score submissions (third-party — provided by the `programbench` package).                     |

### Flags

| Command                   | Flag                | Description                                                                       |
| ------------------------- | ------------------- | --------------------------------------------------------------------------------- |
| `run.sh` / `run-batch.sh` | `--budget <USD>`    | Per-task spend cap. Default `$10`.                                                |
| `run.sh` / `run-batch.sh` | `--model <id>`      | Model id. Default `claude-opus-4-7`.                                              |
| `run.sh` / `run-batch.sh` | `--keep-image`      | Don't `docker rmi` the cleanroom image after the task (faster reruns; more disk). |
| `run-batch.sh`            | `--parallel <N>`    | Concurrent agent containers. Pick conservatively for your CPU count.              |
| `run-batch.sh`            | `--slice <a:b>`     | Sorted task list, slice [a:b).                                                    |
| `run-batch.sh`            | `--filter <regex>`  | Posix regex on task ids.                                                          |
| `run-batch.sh`            | `--max-retries <N>` | Retry transient failures. Default `1`.                                            |

## Adding a new arm

An arm is a directory under `arms/`. See [`arms/README.md`](arms/README.md) for the full convention. To compare "with MCP server X" vs the existing arms, create `arms/with-mcp-x/` with an `mcp.json` and an `orchestration.md`. The harness needs no changes.

## Development

```sh
bash -n harness/run.sh           # syntax-check the harness scripts
./harness/analyze.py --help      # confirm the analyzer is wired up
```

## Status

Sandbox topology and analyzer are validated end-to-end on the cmatrix task. Both arms scored 98% on cmatrix in early smoke runs (`plan-eng-review` and `review` invoked correctly in the gstack arm; no `AskUserQuestion` blocking with `OPENCLAW_SESSION=1`). A 10-task pilot is in flight; the full 201-task sweep follows once the pilot validates the harness across mixed languages.
