# Orchestration

No additional skills are available. Work directly from the system prompt.
Follow the workflow described there: survey, plan, implement incrementally,
test against the original, package as `submission.tar.gz`.

## Notes for the Codex agent

- You are running inside an externally-sandboxed Docker container. Your file
  edits are confined to the agent container, but `docker exec` against
  `$CLEANROOM` is your way to act inside the isolated cleanroom container
  where the actual build/test must happen.
- The Codex CLI process was invoked with
  `--dangerously-bypass-approvals-and-sandbox`; do not stop to ask the user
  for permission before running shell commands. The user is not present.
- The cleanroom container has `--network none`. The agent container has
  network egress only to api.anthropic.com / chatgpt.com / api.openai.com
  via a whitelist proxy; assume `curl`, `wget`, `pip install`, etc. will
  fail and do not waste turns trying.
- When you believe the submission is complete, produce
  `/workspace/submission.tar.gz` inside the cleanroom and stop.
