# codex-vanilla

OpenAI Codex CLI arm, holding the model approximately constant against the
Claude `vanilla` arm. The point of comparison is "same model class, different
harness": we vary the agent harness (Codex vs. Claude Code) and the model
(`gpt-5.5` vs. `claude-opus-4-7`) drops out as a confound — the comparison is
really "Codex CLI harness" vs. "Claude Code harness" for a frontier reasoning
model.

## Configuration choices

- Model: `gpt-5.5` (the literal model ID Codex CLI 0.130.0 accepts in
  `config.toml`; same as the user's host default).
- Reasoning effort: Codex CLI default (no `model_reasoning_effort` override).
  The Claude arm does not pass `--effort` to `claude -p` either; leaving both
  at CLI default is the most faithful "harness held constant" comparison.
- Fast mode: explicitly **not** enabled (Codex has a `fast_mode` feature flag;
  we leave it unset so the agent uses the default deliberation depth).
- Sandboxing: `--dangerously-bypass-approvals-and-sandbox`. The container is
  the sandbox; Codex's in-process sandbox would conflict with `docker exec`
  into the cleanroom.
- MCP: empty (no MCP servers wired in, matching the Claude `vanilla` arm).

## Auth

Codex CLI's ChatGPT-mode OAuth credentials live in `~/.codex/auth.json` on
the host. The harness bind-mounts them read-only at `/home/node/.codex/`
inside the agent container. Token refresh happens via `auth.openai.com`,
which is whitelisted in the proxy.
