#!/usr/bin/env python3
"""Extract per-trajectory metrics from codex-pilot-2 transcripts.

EXPLORATORY analysis (post-hoc, shaped after seeing run results): quantifies
the "language flexibility vs long-horizon coherence" tradeoff question:
  - local-gotcha tax: failed build commands, repeated-identical-error loops,
    position of first green build;
  - deferred errors: static (compile/type) vs runtime (traceback/exception)
    error events seen by the agent during the trajectory;
  - churn: file_change re-edit patterns (late rework on already-written files);
  - submission size: source files + LOC from submission.tar.gz.

Output: analysis/trajectory_metrics.csv, one row per (arm, task).
Blocklist is NOT applied here (raw extraction); the analysis layer applies
analyze.py's REPORT_BLOCKLIST for the reported n=192.
"""
import csv
import glob
import hashlib
import io
import json
import os
import re
import sys
import tarfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN = "codex-pilot-2"
ARMS = [
    "codex-free",
    "codex-lang-c", "codex-lang-go", "codex-lang-java", "codex-lang-js",
    "codex-lang-python", "codex-lang-ruby", "codex-lang-rust", "codex-lang-ts",
]

# --- error signatures -------------------------------------------------------
# "static" = compile/type/syntax errors surfaced before the program runs
# (the hypothesized "local gotchas" of strict/compiled languages).
# "runtime" = errors surfaced only by executing the program (the hypothesized
# deferred-error mode of flexible languages).
STATIC_SIGS = {
    "rust":   [r"error\[E\d+\]", r"^error: .*", r"cannot find .* in this scope",
               r"mismatched types", r"borrow", r"does not live long enough"],
    "go":     [r"\.go:\d+:\d+: .*(undefined|cannot use|missing|too many|unknown field|mismatch|undeclared)",
               r"# command-line-arguments"],
    "c":      [r"\.[ch]:\d+:\d+: (fatal )?error", r"undefined reference to",
               r"implicit declaration of function"],
    "java":   [r"\.java:\d+: error:", r"cannot find symbol", r"incompatible types"],
    "ts":     [r"error TS\d+"],
    "js":     [r"SyntaxError:"],
    "python": [r"SyntaxError:", r"IndentationError:"],
    "ruby":   [r"syntax error,"],
}
RUNTIME_SIGS = {
    "rust":   [r"thread '.*' panicked", r"^error: process didn't exit successfully"],
    "go":     [r"panic: ", r"runtime error:"],
    "c":      [r"Segmentation fault", r"core dumped", r"AddressSanitizer"],
    "java":   [r"Exception in thread", r"\w+Exception(:| at )", r"Error: Main method not found"],
    "ts":     [r"TypeError:", r"ReferenceError:", r"RangeError:", r"UnhandledPromiseRejection"],
    "js":     [r"TypeError:", r"ReferenceError:", r"RangeError:", r"UnhandledPromiseRejection"],
    "python": [r"Traceback \(most recent call last\)", r"TypeError:", r"AttributeError:",
               r"NameError:", r"KeyError:", r"ImportError:", r"ModuleNotFoundError:",
               r"ValueError:"],
    "ruby":   [r"NoMethodError", r"NameError", r"undefined method", r"ArgumentError",
               r"\(LoadError\)"],
}
STATIC_RE = {k: re.compile("|".join(v), re.M) for k, v in STATIC_SIGS.items()}
RUNTIME_RE = {k: re.compile("|".join(v), re.M) for k, v in RUNTIME_SIGS.items()}

BUILD_CMD = {
    "rust":   re.compile(r"cargo +(build|check|run|test)|rustc "),
    "go":     re.compile(r"go +(build|vet|run|test)"),
    "c":      re.compile(r"\b(gcc|cc|clang|make|cmake)\b"),
    "java":   re.compile(r"\b(javac|mvn|gradle)\b"),
    "ts":     re.compile(r"\b(tsc|npx tsc|npm run build|esbuild)\b"),
    "js":     re.compile(r"\bnode (--check|-c)\b|npm run build"),
    "python": re.compile(r"py_compile|python3? -m compileall"),
    "ruby":   re.compile(r"ruby +-c\b"),
}

SRC_EXT = {
    "rust": {".rs"}, "go": {".go"}, "c": {".c", ".h"}, "java": {".java"},
    "ts": {".ts", ".tsx"}, "js": {".js", ".mjs", ".cjs"},
    "python": {".py"}, "ruby": {".rb"},
}
ALL_SRC_EXT = set().union(*SRC_EXT.values())

ERRLINE = re.compile(
    r"(error\[E\d+\]|error TS\d+|\.java:\d+: error:.*|\.[ch]:\d+:\d+:.*error.*|"
    r"\.go:\d+:\d+:.*|^error(\[|:).*|SyntaxError:.*|Traceback.*|"
    r"\w+Error:.*|\w+Exception.*|NoMethodError.*|undefined method.*|panic: .*|"
    r"thread '.*' panicked.*|cannot find symbol.*)", re.M)
NUMS = re.compile(r"\d+")


def err_fingerprint(output: str) -> str:
    """Stable fingerprint of the error content of a command output, so we can
    detect the agent re-running into the *same* error (a stuck loop)."""
    hits = ERRLINE.findall(output or "")
    if not hits:
        return ""
    lines = sorted({NUMS.sub("#", (h if isinstance(h, str) else h[0]).strip())[:160]
                    for h in hits})
    return hashlib.md5("\n".join(lines).encode()).hexdigest()[:12]


def submission_size(tar_path: str):
    """(n_source_files, total_source_LOC, n_all_files) from submission.tar.gz."""
    n_src = loc = n_all = 0
    try:
        with tarfile.open(tar_path, "r:gz") as tf:
            for m in tf:
                if not m.isfile():
                    continue
                base = os.path.basename(m.name)
                if base.startswith("._"):
                    continue  # AppleDouble
                n_all += 1
                ext = os.path.splitext(base)[1].lower()
                if ext in ALL_SRC_EXT and m.size < 5_000_000:
                    n_src += 1
                    f = tf.extractfile(m)
                    if f:
                        loc += f.read().count(b"\n")
    except Exception:
        return None, None, None
    return n_src, loc, n_all


def load_languages():
    """task -> chosen language for codex-free, from per-task.csv."""
    langs = {}
    with open(os.path.join(REPO, "runs", RUN, "per-task.csv")) as f:
        for row in csv.DictReader(f):
            if row["arm"] == "codex-free":
                langs[row["task"]] = row["language"]
    return langs


def analyze_transcript(path: str, lang: str):
    cmds = []          # (command, output, exit_code) in completion order
    n_filechange = 0
    files_changed = []  # ordered list of changed paths (per file_change item)
    n_msgs = 0
    out_tokens = 0
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = d.get("type")
            if t == "item.completed":
                it = d["item"]
                k = it.get("type")
                if k == "command_execution":
                    cmds.append((it.get("command") or "",
                                 it.get("aggregated_output") or "",
                                 it.get("exit_code")))
                elif k == "file_change":
                    n_filechange += 1
                    for ch in it.get("changes") or []:
                        p = ch.get("path")
                        if p:
                            files_changed.append(p)
                elif k == "agent_message":
                    n_msgs += 1
            elif t == "turn.completed":
                out_tokens += (d.get("usage") or {}).get("output_tokens") or 0

    static_re = STATIC_RE.get(lang)
    runtime_re = RUNTIME_RE.get(lang)
    build_re = BUILD_CMD.get(lang)

    n = len(cmds)
    n_failed = 0
    n_build = n_build_fail = 0
    n_static = n_runtime = 0          # commands whose output shows each class
    first_green_build = None          # index of first successful build cmd
    fail_idx = []                     # indices of failed commands
    static_idx = []                   # indices of static-error commands
    fps = []                          # (idx, fingerprint) of failing cmds
    for i, (cmd, out, code) in enumerate(cmds):
        failed = code not in (0, None)
        if failed:
            n_failed += 1
            fail_idx.append(i)
        is_build = bool(build_re and build_re.search(cmd))
        if is_build:
            n_build += 1
            if failed:
                n_build_fail += 1
            elif first_green_build is None:
                first_green_build = i
        if static_re and static_re.search(out):
            n_static += 1
            static_idx.append(i)
        if runtime_re and runtime_re.search(out):
            n_runtime += 1
        if failed or (static_re and static_re.search(out)):
            fp = err_fingerprint(out)
            if fp:
                fps.append((i, fp))

    # stuck loops: longest run of consecutive error-fingerprinted commands
    # sharing the same fingerprint (allowing interleaved non-error commands
    # would overcount; we require consecutiveness in the error sequence).
    max_loop = cur = 1 if fps else 0
    n_loop_cmds = 0  # error cmds that repeat the immediately previous error fp
    for j in range(1, len(fps)):
        if fps[j][1] == fps[j - 1][1]:
            cur += 1
            n_loop_cmds += 1
        else:
            cur = 1
        max_loop = max(max_loop, cur)

    # churn: re-edits of files already edited
    seen = set()
    re_edits = 0
    late_re_edits = 0  # re-edit happening in the last third of file_change seq
    for j, p in enumerate(files_changed):
        if p in seen:
            re_edits += 1
            if len(files_changed) >= 3 and j >= 2 * len(files_changed) / 3:
                late_re_edits += 1
        seen.add(p)

    def frac(a, b):
        return round(a / b, 4) if b else ""

    third = max(1, n // 3)
    early_fails = sum(1 for i in fail_idx if i < third)
    late_fails = sum(1 for i in fail_idx if i >= n - third)
    late_static = sum(1 for i in static_idx if i >= n - third)

    return {
        "n_cmds": n,
        "n_failed_cmds": n_failed,
        "fail_rate": frac(n_failed, n),
        "n_build_cmds": n_build,
        "n_build_failures": n_build_fail,
        "build_fail_rate": frac(n_build_fail, n_build),
        "first_green_build_pos": frac(first_green_build, n) if first_green_build is not None else "",
        "n_static_err_cmds": n_static,
        "n_runtime_err_cmds": n_runtime,
        "static_share": frac(n_static, n_static + n_runtime),
        "max_same_err_loop": max_loop,
        "n_loop_cmds": n_loop_cmds,
        "early_fail_frac": frac(early_fails, n_failed),
        "late_fail_frac": frac(late_fails, n_failed),
        "late_static_errs": late_static,
        "n_file_changes": n_filechange,
        "n_unique_files": len(seen),
        "n_re_edits": re_edits,
        "n_late_re_edits": late_re_edits,
        "churn": frac(re_edits, len(seen)),
        "n_agent_msgs": n_msgs,
        "output_tokens": out_tokens,
    }


def main():
    free_langs = load_languages()
    out_path = os.path.join(REPO, "analysis", "trajectory_metrics.csv")
    rows = []
    for arm in ARMS:
        tdirs = sorted(glob.glob(os.path.join(REPO, "logs", RUN, arm, "*")))
        for td in tdirs:
            task = os.path.basename(td)
            tpath = os.path.join(td, "transcript.jsonl")
            if not os.path.exists(tpath):
                continue
            if arm == "codex-free":
                lang = free_langs.get(task, "")
            else:
                lang = arm.replace("codex-lang-", "")
            row = {"arm": arm, "task": task, "lang": lang}
            row.update(analyze_transcript(tpath, lang))
            sub = os.path.join(REPO, "runs", RUN, arm, task, "submission.tar.gz")
            n_src, loc, n_all = submission_size(sub) if os.path.exists(sub) else (None, None, None)
            row["sub_src_files"] = n_src if n_src is not None else ""
            row["sub_loc"] = loc if loc is not None else ""
            row["sub_all_files"] = n_all if n_all is not None else ""
            rows.append(row)
        print(f"{arm}: {sum(1 for r in rows if r['arm']==arm)} tasks", file=sys.stderr)

    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {len(rows)} rows -> {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
