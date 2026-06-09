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
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
</p>

<h3 align="center">ProgramBench measures models. We use it to measure the agent harness.</h3>

The [ProgramBench paper](https://arxiv.org/abs/2605.03546) evaluates LLMs on ~200 reverse-engineering tasks, deliberately running every model through a minimal agent to "reduce confounds between model capability and harness design."

We run the **inverse** experiment. We **hold the model constant and vary one thing about the agent harness**, so the benchmark stops measuring the model and starts measuring the harness decision. The goal is to bring statistical rigor to the questions about agent design that are usually settled by anecdote and vibes:

- Does **mandating a programming language** help or hurt versus letting the agent choose?
- Does a **test-driven-development workflow** make an agent better, or just slower and more expensive?
- Do a particular set of **skills**, an **MCP server**, or an **orchestration prompt** actually move the needle?

Each such question becomes a controlled A/B: same model, same tasks, same sandbox, one harness variable changed. We compare the arms **paired, per task**, and report with the rigor the question deserves (see [Methodology](#methodology)). **Either outcome is informative** - a real effect is a harness signal worth knowing; a null result is worth knowing too.

The model is whatever a given study holds fixed (studies so far have used Claude Code on Claude, and OpenAI Codex on gpt-5.5); the point is never which model, but which harness choice.

## What's an "arm"?

An **arm** is one configuration of the harness, defined entirely by a directory under `arms/` (an orchestration prompt, optional skills, optional MCP config). A study is a set of arms compared over the same task slice. Adding a new comparison is adding a directory - the harness itself needs no changes. This is what makes the repo a reusable instrument rather than a single experiment.

Design principles:

- **Hermetic by construction** - the agent's tools cannot reach the internet. The cleanroom Docker container is `--network none`; the agent runs in a separate container whose only egress is a proxy with a hard domain whitelist (the model API and nothing else).
- **Reproducible by anyone** - operator-side dependencies are just Docker, `uv`, and an auth token. No keychain or local config bleed-through.
- **Model- and harness-agnostic** - Claude Code arms route through `harness/run.sh`, OpenAI Codex arms through `harness/run-codex.sh`; both share the same isolation topology and analysis.

## Studies

Each study is a self-contained write-up with its data co-located beside it under `blog/<study>/data/` (per-task results + the code each arm actually produced), so any result is inspectable and recomputable:

- [`blog/best-programming-languages-for-agents/`](blog/best-programming-languages-for-agents/) - holding the model fixed and mandating each of 8 languages vs free choice.
- [`blog/does-tdd-help-coding-agents/`](blog/does-tdd-help-coding-agents/) - free choice vs a mandated test-first workflow.

## Quick Start

```sh
$ uv venv cache/pb-venv && source cache/pb-venv/bin/activate
$ uv pip install programbench scipy numpy

# auth once (Claude Code arms): browser flow -> token file
$ claude setup-token && echo "<token>" > .claude-oauth-token

# run two arms over a task slice, paired
$ ./harness/run-batch.sh --arms <arm-a>,<arm-b> --slice 0:10 --run-name <study> --parallel 3

# score each arm's submissions (third-party programbench package)
$ programbench eval runs/<study>/<arm-a>
$ programbench eval runs/<study>/<arm-b>

# deterministic paired report
$ ./harness/analyze.py --run <study> --arms <arm-a>,<arm-b>
```

`run-batch.sh` resumes from existing submissions, retries transient failures, and routes `codex-*` arms to the Codex runner automatically. See [`AGENTS.md`](AGENTS.md) for operational guidance on long-running batches (health monitoring, disk/memory watchdogs, multi-arm stripe scheduling).

## Install

**macOS (Apple Silicon)** - Docker Desktop must use the Apple Virtualization framework + Rosetta x86_64 emulation (_Settings → General_).

**Linux x86_64** - works natively.

```sh
git clone git@github.com:kunchenguid/programbench-bench.git
cd programbench-bench
uv venv cache/pb-venv && source cache/pb-venv/bin/activate
uv pip install programbench scipy numpy
```

ProgramBench cleanroom images are ~1-3 GB each; allow a few GB of free disk per concurrent task slot.

## How It Works

Each task runs on a network-isolated three-container topology (shown for a Claude arm; Codex arms are identical with the OpenAI endpoint):

```
                    Model API (whitelisted)
                        ▲
                        │ HTTPS
              ┌─────────┴──────────┐
              │   pb/proxy         │  tinyproxy, hard domain allow-list
              └─────────┬──────────┘
                        │
              ┌─────────┴──────────┐         ┌────────────────────┐
              │   agent container  │         │   cleanroom        │
              │   claude -p / codex│ docker  │   (--network none) │
              │   HTTPS_PROXY=...  │ exec  ► │   /workspace/      │
              │   (--internal net) │ via     │   ├─ executable    │
              └────────────────────┘ socket  │   └─ ...docs       │
                                             └────────────────────┘
```

- **The agent never reaches the internet directly.** Its container is on a Docker `--internal` network; outbound goes through the proxy's hard whitelist.
- **The cleanroom is fully air-gapped.** `--network none` is kernel-enforced; the agent talks to it via `docker exec`, not networking.
- **Per-arm config is declarative.** An arm plants its skills / prompt / MCP config; the harness keeps the operator's own config from leaking in.

### Methodology

We hold ourselves to a standing set of reporting practices (documented in full in [`AGENTS.md`](AGENTS.md)), because the questions are ambiguous and easy to answer dishonestly:

| Practice | What it means |
| --- | --- |
| **Continuous metric** | Report mean test pass-rate (sensitive to partial progress), not a binarized "resolved" cut that is degenerate at this benchmark's difficulty. |
| **Threshold-free inference** | "Better/worse" claims come from a paired Wilcoxon signed-rank test (tasks matched across arms), Holm-corrected, never from ranking on an arbitrary cutoff. |
| **Difficulty stratification** | Break results down by task difficulty - a pooled mean conflates "did well on trivial tasks" with "made progress on hard ones." |
| **Confirmatory vs exploratory** | Every result is labeled; post-hoc analyses carry the forking-paths caveat and are never presented with pre-registered credibility. |
| **No method chosen for its result** | Reporting choices are justified a priori, by the structure of the task set and the metrics - not by the answer they happen to produce. |

### Anti-wrapping (reimplementation integrity)

Because tasks ask the agent to **reimplement** a tool from scratch, a submission that secretly delegates to the original tool's engine (links its `.so`, shells out to its binary, or uses a language-runtime/stdlib build of the same codec/engine) inflates the score. The harness strips the reference tool from the cleanroom (`harness/strip-ref/`, gated by `PB_STRIP_REF=1`), the system prompt forbids delegation explicitly, and submissions are code-read audited; tasks that can only be satisfied by an unstrippable runtime-bundled engine are blocklisted from reporting. See [`AGENTS.md`](AGENTS.md).

## CLI Reference

| Command | Description |
| --- | --- |
| `harness/run.sh --arm <a> --task <t>` | Run one (arm, task) end-to-end (Claude arms). |
| `harness/run-codex.sh --arm <a> --task <t>` | Same, for OpenAI Codex arms. |
| `harness/run-batch.sh --arms <a,b> --slice <i:j>` | Batch with parallelism, resume, retry; routes `codex-*` arms automatically. |
| `harness/reeval.sh <arm> [timeout]` | Re-score an arm's existing submissions (e.g. at a longer timeout), skipping blocklisted tasks. |
| `harness/analyze.py --run <name> --arms <a,b>` | Deterministic report: per-arm summary, threshold ladder, paired stats, per-task CSV. |
| `programbench eval runs/<run>/<arm>` | Score submissions (third-party `programbench` package). |

## Adding a new arm

An arm is a directory under `arms/`. See [`arms/README.md`](arms/README.md) for the convention. To compare "with MCP server X" vs an existing arm, create `arms/with-mcp-x/` with an `mcp.json` and an `orchestration.md` - the harness needs no changes.

## Development

```sh
bash -n harness/run.sh           # syntax-check the harness scripts
./harness/analyze.py --help      # confirm the analyzer is wired up
```
