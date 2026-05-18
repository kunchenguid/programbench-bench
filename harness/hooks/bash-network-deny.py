#!/usr/bin/env python3
"""PreToolUse hook: deny any Bash command that contains an internet-touching token.

Reads a JSON payload from stdin (Claude Code's hook format), checks the
``tool_input.command`` against a substring/regex blocklist, and exits with
code 2 (deny) on a hit. Anything else exits 0 (allow).

This complements ``--disallowed-tools Bash(prefix*)`` patterns, which only
match command prefixes. A hook sees the full command string, so it catches
chains like ``cd /tmp && curl ...``, ``bash -c "wget ..."``, etc.

The hook is conservative: when in doubt, allow. False negatives are caught
by ``--network none`` on the cleanroom container and (optionally) by the
sandbox-mode whitelist proxy.
"""

from __future__ import annotations

import json
import re
import sys

# Substring patterns. The full command is normalized to lowercase before
# checking, so patterns are written in lowercase. Pure substrings, not regex,
# unless the entry is a (re.compile(...)) Pattern.
DENY_SUBSTRINGS = (
    # url schemes / hosts
    "http://",
    "https://",
    "ftp://",
    "github.com",
    "gitlab.com",
    "raw.githubusercontent.com",
    "crates.io",
    "pypi.org",
    "registry.npmjs.org",
    "go.googlesource.com",
    "proxy.golang.org",
    # network clients
    "curl ",
    "wget ",
    "httpie ",
    " http ",   # python httpie aliased "http"
    "telnet ",
    "ftp ",
    "sftp ",
    "tftp ",
    "rsync ",
    "scp ",
    "ssh ",
    " nc ",
    "netcat ",
    # package fetches
    "pip install",
    "pip3 install",
    "pip download",
    "uv add",
    "uv pip install",
    "npm install",
    "npm i ",
    "yarn add",
    "yarn install",
    "pnpm add",
    "pnpm install",
    "bun add",
    "bun install",
    "cargo install",
    "cargo fetch",
    "cargo update",
    "cargo download",
    "cargo search",
    "go get",
    "go install",
    "go mod download",
    "brew install",
    "brew tap",
    "apt install",
    "apt-get install",
    "apk add",
    "dnf install",
    "yum install",
    # vcs network ops
    "git clone",
    "git fetch",
    "git pull",
    "git push",
    "git remote add",
    "git ls-remote",
    "gh repo",
    "gh pr",
    "gh issue",
    "gh api",
    "gh auth",
    "gh release",
    # docker network ops we don't want the agent doing
    "docker pull",
    "docker run",
    "docker login",
    "docker build",
    "docker push",
    # cloud tooling
    " aws ",
    " gcloud ",
    " az ",
)

# Full-command regex patterns for shapes that bypass the substring check.
# E.g., base64-decoded curl, eval-ed remote scripts.
DENY_REGEX = (
    re.compile(r"\b(curl|wget)\b"),                  # leading curl/wget anywhere
    re.compile(r"base64\s+(-d|--decode)"),           # base64 decode then exec is suspect
    re.compile(r"python3?\s+-c\s+['\"].*urllib"),    # python -c "import urllib..."
    re.compile(r"python3?\s+-c\s+['\"].*requests"),
    re.compile(r"python3?\s+-c\s+['\"].*socket"),
    re.compile(r"python3?\s+-c\s+['\"].*http\.client"),
    re.compile(r"\beval\s+\$\("),                    # eval $(curl ...) etc.
)


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        return 0
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return 0

    if payload.get("tool_name") != "Bash":
        return 0

    command = payload.get("tool_input", {}).get("command", "")
    if not isinstance(command, str) or not command:
        return 0

    needle = command.lower()
    # Pad with spaces so patterns like " nc " match at boundaries.
    padded = f" {needle} "

    for sub in DENY_SUBSTRINGS:
        if sub in padded:
            print(
                f"BLOCKED by network-deny hook: command contains forbidden token "
                f"'{sub.strip()}'. The benchmark forbids host-side internet access. "
                f"Use --network none cleanroom container for any work that touches the artifact.",
                file=sys.stderr,
            )
            return 2

    for pat in DENY_REGEX:
        if pat.search(needle):
            print(
                f"BLOCKED by network-deny hook: command matches forbidden pattern "
                f"/{pat.pattern}/.",
                file=sys.stderr,
            )
            return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
