#!/usr/bin/env python3
"""Re-inject an arm's current compile-prelude.sh into already-built submissions.

The compile-prelude is normally baked into submission.tar.gz at agent-run
time by run-codex.sh, sandwiched between marker lines. When we fix an arm's
eval-env prelude AFTER the agents have run (the 2026-05-25 env-confound A
fixes), existing submissions still carry the OLD prelude. This rewrites the
block between the markers with the arm's current prelude, leaving the
shebang and the agent's original compile.sh untouched.

Usage:
  reinject-prelude.py <arm> <task> [<task> ...]
  reinject-prelude.py <arm> --all        # every task dir under the arm

Idempotent: re-running replaces the block again with the same content.
"""
import os, sys, tarfile, tempfile, shutil, io

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BEGIN = "# ===== compile-prelude (auto-injected by harness/run-codex.sh) ====="
END = "# ===== end compile-prelude ====="


def rewrite_compile_sh(text: str, prelude: str) -> str:
    lines = text.splitlines()
    shebang = lines[0] if lines and lines[0].startswith("#!") else "#!/bin/bash"
    body = text[len(lines[0]) + 1:] if lines and lines[0].startswith("#!") else text
    if BEGIN in body and END in body:
        pre = body.split(BEGIN, 1)[0]
        post = body.split(END, 1)[1]
        rest = pre + post  # agent's original compile.sh, prelude stripped
    else:
        rest = body  # no prior prelude; just prepend
    rest = rest.lstrip("\n")
    out = [shebang, BEGIN, prelude.rstrip("\n"), END, rest]
    return "\n".join(out) + "\n"


def process(arm: str, task: str, prelude: str, run: str = "codex-pilot-1") -> str:
    sub = os.path.join(REPO, "runs", run, arm, task, "submission.tar.gz")
    if not os.path.exists(sub) or os.path.getsize(sub) < 200:
        return f"SKIP {task}: no valid submission"
    tmp = tempfile.mkdtemp(prefix="reinject-")
    try:
        with tarfile.open(sub) as tf:
            members = tf.getmembers()
            tf.extractall(tmp)
        # find compile.sh (top-level or under ./)
        csh = None
        for cand in ("compile.sh", "./compile.sh"):
            p = os.path.join(tmp, cand)
            if os.path.exists(p):
                csh = p; break
        if csh is None:
            return f"SKIP {task}: no compile.sh"
        with open(csh) as f:
            new = rewrite_compile_sh(f.read(), prelude)
        with open(csh, "w") as f:
            f.write(new)
        os.chmod(csh, 0o755)
        # re-tar preserving the original arcnames + modes
        with tarfile.open(sub, "w:gz") as tf:
            for m in members:
                full = os.path.join(tmp, m.name)
                if m.isfile():
                    tf.add(full, arcname=m.name, recursive=False)
                elif m.isdir():
                    tf.add(full, arcname=m.name, recursive=False)
        return f"OK   {task}"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    # Usage: reinject-prelude.py [--run NAME] <arm> (--all | <task> ...)
    # pilot-2 (--run codex-pilot-2*) injects arms/<arm>/setup.sh; pilot-1 uses
    # arms/<arm>/compile-prelude.sh. Both share the same marker block.
    args = sys.argv[1:]
    run = "codex-pilot-1"
    if "--run" in args:
        i = args.index("--run"); run = args[i + 1]; del args[i:i + 2]
    if len(args) < 2:
        print(__doc__); sys.exit(2)
    arm = args[0]
    setup_p = os.path.join(REPO, "arms", arm, "setup.sh")
    prelude_p = os.path.join(REPO, "arms", arm, "compile-prelude.sh")
    prelude_path = prelude_p if run == "codex-pilot-1" else (
        setup_p if os.path.exists(setup_p) else prelude_p)
    if not os.path.exists(prelude_path):
        print(f"no prelude/setup for arm {arm}"); sys.exit(2)
    prelude = open(prelude_path).read()
    if args[1] == "--all":
        arm_dir = os.path.join(REPO, "runs", run, arm)
        tasks = sorted(d for d in os.listdir(arm_dir)
                       if os.path.isdir(os.path.join(arm_dir, d)))
    else:
        tasks = args[1:]
    print(f"[reinject] run={run} arm={arm} prelude={os.path.relpath(prelude_path, REPO)} n={len(tasks)}")
    for t in tasks:
        print(process(arm, t, prelude, run))


if __name__ == "__main__":
    main()
