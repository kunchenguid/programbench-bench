# Arms

An **arm** is one configuration of the Claude Code agent under test.
The harness (`harness/run.sh --arm <name>`) loads the arm directory and
applies whatever well-known files it contains. Convention over configuration:
nothing required except `orchestration.md`.

## Recognized files

| File / dir          | Effect                                                                           |
|---------------------|----------------------------------------------------------------------------------|
| `orchestration.md`  | Appended to the task-agnostic system prompt (`harness/system.md`). Required.     |
| `setting-sources`   | Value for `--setting-sources`. One line, e.g. `project,local`. Default: empty.   |
| `settings.json`     | Passed via `--settings`. Default: empty `{}`.                                    |
| `mcp.json`          | Passed via `--mcp-config` (with `--strict-mcp-config`). Default: no servers.     |
| `skills/`           | Each subdir copied into `<run_cwd>/.claude/skills/`. Discovered when `setting-sources` includes `project` or `local`. |
| `disallowed-extra`  | Extra entries for `--disallowed-tools`, one per line. Merged with the default network blocklist. |

The default network blocklist (always applied) is in `harness/disallowed-default`.

## Existing arms

- `vanilla/` — stock Claude Code, no skills, no MCP. Baseline.
- `gstack-curated/` — five gstack skills planted (`plan-eng-review`,
  `investigate`, `review`, `health`, `careful`) with an orchestration prompt
  describing when to invoke each.

## Adding a new arm

1. `mkdir arms/<name>`
2. Drop in whatever files are relevant from the table above.
3. Always include an `orchestration.md` (even if empty / "no extra guidance").
4. `harness/run.sh --arm <name> --task <task_id>` will pick it up.

## What does NOT vary across arms

These are held constant by the harness regardless of arm:

- Model (`PB_MODEL`, default `claude-opus-4-7`)
- Budget cap (`PB_BUDGET_USD`)
- Cleanroom container image, network policy (`--network none`), CPU limits
- The task-agnostic system prompt (`prompts/system.md`)
- The default network blocklist (`harness/disallowed-default`)
- The Claude Code CLI version
