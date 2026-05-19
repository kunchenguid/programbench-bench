#!/usr/bin/env python3
"""Deterministic analyzer for programbench-bench runs.

Walks runs/<run-name>/<arm>/<task>/<task>.eval.json and the matching
logs/<run-name>/<arm>/<task>/transcript.jsonl. Produces:

- Per-arm summary table (mean %, threshold ladder, compile %, cost, turns,
  skill invocation rate)
- Paired comparison table when 2+ arms are present (Δ mean with bootstrap CI,
  Wilcoxon p-value on per-task deltas, McNemar at each ladder threshold,
  win/loss/tie counts)
- Per-task CSV at runs/<run-name>/per-task.csv
- Threshold ladder histogram

Usage:
    ./harness/analyze.py --run smoke-1 --arms vanilla,gstack-curated

Determinism: pure function of the input files. No clock, no network. Bootstrap
uses np.random.default_rng(42); scipy.stats are deterministic. Re-running on
the same inputs produces byte-identical output.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import tarfile
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy import stats

from programbench.eval.eval import EvaluationResult
from programbench.utils.load_data import (
    get_active_branches,
    get_ignored_tests,
    load_all_instances,
)

THRESHOLDS = [25, 50, 80, 95]  # the ≥X buckets we report (in addition to >0 and =100)
RNG_SEED = 42

# Per-million-token pricing for codex models (USD). Source: openai.com/api/pricing
# (looked up 2026-05-19). reasoning_output_tokens are billed at the same rate as
# output_tokens.
CODEX_PRICING = {
    "gpt-5.5": {"input": 5.00, "cached_input": 0.50, "output": 30.00},
    "gpt-5.5-pro": {"input": 30.00, "cached_input": 30.00, "output": 180.00},
}


@dataclass
class TaskRow:
    arm: str
    task: str
    pct: float           # % tests passed over ALL non-ignored tests (0-100) - primary/raw metric
    compile_ok: bool
    n_total: int
    n_passed: int
    # codex-pilot-2 dual metric: pass-rate over tests that actually RAN (exclude
    # not_run). Separates correctness from the branch-level not_run/timeout
    # cascade. pct <= pct_ran always; the gap quantifies the runtime-robustness
    # artifact. n_ran = non-ignored tests with a real status (not not_run).
    n_ran: int
    pct_ran: float
    language: str        # detected implementation language of the submission ("?" if unknown)
    wraps_tool: bool     # submission appears to shell out to the tool-under-test / a system binary
    cost_usd: float
    turns: int
    duration_min: float
    skills_invoked: tuple[str, ...]   # which skills the agent called via the Skill tool


# ---------------------------------------------------------------------------
# Submission inspection: language choice + reference-tool wrapping
# ---------------------------------------------------------------------------

# source-file extension -> language
_EXT_LANG = {
    ".rs": "rust", ".go": "go", ".c": "c", ".h": "c", ".cc": "c", ".cpp": "c",
    ".py": "python", ".js": "js", ".mjs": "js", ".cjs": "js",
    ".ts": "ts", ".tsx": "ts", ".rb": "ruby", ".java": "java",
}
# directories that are vendored deps / build output, not the agent's own source
_VENDOR_DIRS = ("vendor/", "node_modules/", "target/", ".cargo/", "/vendor/",
                "/node_modules/", "/target/", "dist/", "build/")
# compile.sh keyword -> language (tiebreaker / fallback)
_COMPILE_LANG = [
    ("cargo", "rust"), ("rustc", "rust"), ("go build", "go"), ("go install", "go"),
    ("tsc", "ts"), ("ts-node", "ts"), ("javac", "java"), ("mvn", "java"),
    ("ruby", "ruby"), ("gem ", "ruby"), ("node ", "js"), ("npm ", "js"),
    ("gcc", "c"), ("g++", "c"), ("make", "c"), ("python", "python"),
]


def inspect_submission(submission_path: Path, task: str) -> tuple[str, bool]:
    """Return (language, wraps_tool) by inspecting the submission tarball.

    language: dominant source language by file count (vendored/build dirs
    excluded), falling back to compile.sh keywords. "?" if undetectable.
    wraps_tool: heuristic - the submission contains a process-spawn primitive
    AND references the tool-under-test name (parsed from the task id) or a
    /usr/bin path. Reported as a robustness check (the plan's detect-only
    policy), not a gate.
    """
    if not submission_path.exists() or submission_path.stat().st_size < 200:
        return "?", False
    # tool name: "owner__tool.sha" -> "tool"
    tool = task.split("__", 1)[-1].split(".", 1)[0] if "__" in task else task
    ext_counts: dict[str, int] = defaultdict(int)
    compile_txt = ""
    src_blob: list[str] = []
    try:
        with tarfile.open(submission_path, "r:gz") as tf:
            members = [m for m in tf.getmembers() if m.isfile()]
            for m in members:
                name = m.name.lstrip("./")
                low = "/" + name.lower()
                if any(v in low for v in _VENDOR_DIRS):
                    continue
                base = name.rsplit("/", 1)[-1]
                if base.startswith("._"):  # macOS AppleDouble
                    continue
                ext = "." + base.rsplit(".", 1)[-1].lower() if "." in base else ""
                if ext in _EXT_LANG:
                    ext_counts[_EXT_LANG[ext]] += 1
                # read compile.sh + a bounded sample of source for wrap scan
                if base == "compile.sh" or (ext in _EXT_LANG and len("".join(src_blob)) < 400_000):
                    try:
                        data = tf.extractfile(m).read().decode("utf-8", "replace")
                    except Exception:
                        data = ""
                    if base == "compile.sh":
                        # Strip the harness-injected activation prelude (between
                        # the markers) - it contains exec/`/usr/bin`/process
                        # patterns that would false-positive the wrap scan.
                        compile_txt = re.sub(
                            r"# ===== compile-prelude.*?# ===== end compile-prelude[^\n]*\n",
                            "", data, flags=re.DOTALL)
                    else:
                        src_blob.append(data)
    except (tarfile.TarError, OSError):
        return "?", False

    if ext_counts:
        language = max(ext_counts.items(), key=lambda kv: (kv[1], kv[0]))[0]
    else:
        language = "?"
        for kw, lang in _COMPILE_LANG:
            if kw in compile_txt:
                language = lang
                break

    blob = compile_txt + "\n" + "\n".join(src_blob)
    tool_re = re.escape(tool)
    # Wrapping (detect-only robustness check). Conservative - favor false
    # negatives so the reported per-arm rate is meaningful. Three precise signals:
    #   (1) a process-spawn primitive directly invoking the tool-under-test,
    #   (2) a backtick / $( ) invocation of the tool,
    #   (3) compile.sh copying/linking a system binary AS the executable.
    # (Plain `exec ruby gron.rb` / a "gron" usage string do NOT match.)
    wrap_spawn = re.search(
        rf"(os\.system|subprocess\.\w+|popen|exec[lv]\w*|posix_spawn|"
        rf"spawn\w*|Command::new|child_process\.\w+|Open3\.\w+|%x|IO\.popen)"
        rf"\s*[(\[{{]?\s*[\"'`]?\s*(?:/usr/bin/|/bin/|/usr/local/bin/)?{tool_re}\b",
        blob)
    wrap_backtick = re.search(rf"[`]\s*(?:/usr/bin/|/bin/)?{tool_re}\b|"
                              rf"\$\(\s*(?:/usr/bin/|/bin/)?{tool_re}\b", blob)
    wrap_copy = re.search(
        r"\b(cp|ln|install|mv)\b[^\n]*(\$\(\s*which|`\s*which|/usr/bin/|/usr/local/bin/)"
        r"[^\n]*\bexecutable\b", compile_txt)
    return language, bool(wrap_spawn or wrap_backtick or wrap_copy)


# ---------------------------------------------------------------------------
# Per-task extraction
# ---------------------------------------------------------------------------

def load_task(eval_path: Path, transcript_path: Path, instance_meta: dict | None,
              arm: str, task: str, submission_path: Path | None = None) -> TaskRow:
    """Compute one TaskRow from an eval.json + matching transcript.jsonl."""
    result = EvaluationResult.model_validate_json(eval_path.read_text())
    if instance_meta is not None:
        active = get_active_branches(instance_meta)
        ignored_tests = get_ignored_tests(instance_meta)
        result = result.for_branches(active).without_ignored(ignored_tests)

    n_total = len(result.test_results)
    n_passed = sum(1 for t in result.test_results if t.status == "passed")
    n_ran = sum(1 for t in result.test_results if t.status != "not_run")
    pct = (100.0 * n_passed / n_total) if n_total > 0 else 0.0
    pct_ran = (100.0 * n_passed / n_ran) if n_ran > 0 else 0.0
    compile_ok = result.error_code != "compile_failed"

    language, wraps_tool = ("?", False)
    if submission_path is not None:
        language, wraps_tool = inspect_submission(submission_path, task)

    cost = 0.0
    turns = 0
    duration_ms = 0.0
    skills_invoked: list[str] = []
    if transcript_path.exists():
        # Format detection: codex emits `turn.completed` events with a usage
        # field; claude emits `result` events with total_cost_usd. We detect
        # which by scanning the first ~200 lines for either marker.
        text = transcript_path.read_text(errors="replace")
        is_codex = '"turn.completed"' in text[:200_000] and '"usage"' in text[:200_000]
        if is_codex:
            cost, turns, duration_ms = _parse_codex_transcript(
                text, transcript_path, arm)
        else:
            for line in text.splitlines():
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                t = e.get("type")
                if t == "result":
                    # Some runs emit multiple result events when claude -p does
                    # an internal session resume (post-result wrap-up turn).
                    # total_cost_usd is monotonic across those, so we take the
                    # max; num_turns and duration_ms are per-segment, summed.
                    seg_cost = float(e.get("total_cost_usd") or 0)
                    cost = max(cost, seg_cost)
                    turns += int(e.get("num_turns") or 0)
                    duration_ms += float(e.get("duration_ms") or 0)
                elif t == "assistant":
                    for c in e.get("message", {}).get("content", []):
                        if c.get("type") == "tool_use" and c.get("name") == "Skill":
                            sk = c.get("input", {}).get("skill")
                            if sk:
                                skills_invoked.append(sk)

    return TaskRow(
        arm=arm,
        task=task,
        pct=pct,
        compile_ok=compile_ok,
        n_total=n_total,
        n_passed=n_passed,
        n_ran=n_ran,
        pct_ran=pct_ran,
        language=language,
        wraps_tool=wraps_tool,
        cost_usd=cost,
        turns=turns,
        duration_min=duration_ms / 60000,
        skills_invoked=tuple(sorted(set(skills_invoked))),
    )


def _parse_codex_transcript(text: str, transcript_path: Path,
                            arm: str) -> tuple[float, int, float]:
    """Parse a codex `codex exec --json` transcript and return
    (cost_usd, turns_proxy, duration_ms).

    Codex's transcript schema (codex CLI 0.130.0):
    - `thread.started` / `turn.started` / `turn.completed` mark the run.
    - One `turn.completed` per run carries `usage` with:
        input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens
    - `item.completed` events tag the agent's actions (agent_message,
      command_execution, file_change). We use the count as a turns proxy
      since codex doesn't have claude's discrete `num_turns` concept.

    Duration: codex's events lack timestamps. We derive wall time from the
    transcript file's birth-to-mtime range, falling back to mtime alone if
    the FS doesn't expose creation time on macOS APFS (`st_birthtime`).

    Cost: looked up in CODEX_PRICING by model. The model name is parsed from
    the arm's run-codex.sh batch log (PB_MODEL=...) if available; otherwise
    we default to gpt-5.5.
    """
    usage = {"input_tokens": 0, "cached_input_tokens": 0,
             "output_tokens": 0, "reasoning_output_tokens": 0}
    item_count = 0
    for line in text.splitlines():
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        et = e.get("type")
        if et == "turn.completed":
            u = e.get("usage") or {}
            # multi-turn defensive: sum across all turn.completed events (in
            # practice there's only one, but don't lose data if codex ever
            # emits more).
            for k in usage:
                usage[k] += int(u.get(k) or 0)
        elif et == "item.completed":
            item_count += 1

    # Resolve model name. The run-codex.sh batch log writes
    # "task=... arm=... ... model=<MODEL>" on its first line.
    model = "gpt-5.5"
    repo = transcript_path.parents[3]  # logs/<run>/<arm>/<task>/transcript.jsonl → repo
    task = transcript_path.parent.name
    batch_log = repo / "logs" / transcript_path.parents[2].name / "_batch" / f"{arm}__{task}.log"
    if batch_log.exists():
        try:
            first = batch_log.read_text().splitlines()[0]
            if "model=" in first:
                model = first.split("model=", 1)[1].split()[0]
        except (OSError, IndexError):
            pass

    pricing = CODEX_PRICING.get(model)
    if pricing:
        non_cached_input = max(0, usage["input_tokens"] - usage["cached_input_tokens"])
        total_output = usage["output_tokens"] + usage["reasoning_output_tokens"]
        cost = (
            non_cached_input * pricing["input"]
            + usage["cached_input_tokens"] * pricing["cached_input"]
            + total_output * pricing["output"]
        ) / 1_000_000.0
    else:
        cost = 0.0  # unknown model; emit 0 rather than guess

    # Wall time from the transcript's filesystem timestamps. `submission.tar.gz`
    # is a more reliable end marker (codex commits it last), so prefer that.
    sub_path = repo / "runs" / transcript_path.parents[2].name / arm / task / "submission.tar.gz"
    try:
        ts_start = transcript_path.stat().st_birthtime  # macOS APFS
    except AttributeError:
        ts_start = transcript_path.stat().st_mtime  # Linux fallback (less precise)
    if sub_path.exists():
        ts_end = sub_path.stat().st_mtime
    else:
        ts_end = transcript_path.stat().st_mtime
    duration_ms = max(0.0, (ts_end - ts_start) * 1000.0)

    return cost, item_count, duration_ms


# Structurally-broken tasks BLOCKLISTED from reporting (codex-pilot-2,
# 2026-06-02). Their not_run is identical across every arm AND unchanged
# between the 300s and 6h eval, so it is a defect in the ProgramBench task
# (the test branch hangs/errors regardless of submission), not a capability
# or timeout signal. Dropped from the denominator and all metrics. Matched on
# the repo part of the task id (before the ".<sha>"). hyperfine is fully
# unrunnable (0 tests ever run); pixterm/silver_searcher hang on a fixed
# branch subset. See AGENTS.md "Scoring a finished run".
REPORT_BLOCKLIST = {
    # 3 structurally-broken (consistent not_run across arms, unchanged 300s->6h)
    "sharkdp__hyperfine",
    "eliukblau__pixterm",
    "ggreer__the_silver_searcher",
    # 4 disk-runaway tasks (fill Docker.raw + wedge the daemon; score ~0
    # everywhere). Folded into the blocklist 2026-06-02 (Kun's call) so all
    # 7 broken tasks are treated consistently -> reported denominator n=193.
    "tinycc__tinycc",
    "stathissideris__ditaa",
    "tarka__xcp",
    "alecthomas__chroma",
}


def collect_arm(repo: Path, run_name: str, arm: str,
                instances: dict[str, dict]) -> list[TaskRow]:
    arm_runs = repo / "runs" / run_name / arm
    arm_logs = repo / "logs" / run_name / arm
    if not arm_runs.exists():
        return []
    rows: list[TaskRow] = []
    for task_dir in sorted(arm_runs.iterdir()):
        if not task_dir.is_dir():
            continue
        task = task_dir.name
        if task.split(".")[0] in REPORT_BLOCKLIST:
            continue
        eval_path = task_dir / f"{task}.eval.json"
        if not eval_path.exists():
            print(f"[analyze] WARN: no eval.json for {arm}/{task}; skip "
                  "(run `programbench eval ...` first)", file=sys.stderr)
            continue
        transcript = arm_logs / task / "transcript.jsonl"
        submission = task_dir / "submission.tar.gz"
        rows.append(load_task(eval_path, transcript, instances.get(task), arm, task,
                              submission_path=submission))
    return rows


# ---------------------------------------------------------------------------
# Aggregation per arm
# ---------------------------------------------------------------------------

def arm_summary(rows: list[TaskRow]) -> dict:
    n = len(rows)
    if n == 0:
        return {}
    pcts = np.array([r.pct for r in rows])
    pcts_ran = np.array([r.pct_ran for r in rows])
    lang_counts: dict[str, int] = defaultdict(int)
    for r in rows:
        lang_counts[r.language] += 1
    return {
        "n": n,
        "mean_pct": float(pcts.mean()),
        "median_pct": float(np.median(pcts)),
        "mean_pct_ran": float(pcts_ran.mean()),
        "median_pct_ran": float(np.median(pcts_ran)),
        "wrap_pct": 100.0 * sum(r.wraps_tool for r in rows) / n,
        "lang_dist": dict(sorted(lang_counts.items(), key=lambda kv: (-kv[1], kv[0]))),
        # solve@X: fraction of tasks that passed >= X% of their non-ignored
        # tests (r.pct is already over non-ignored tests, same denominator as
        # mean%). PRIMARY = solve@75 (Kun, updated 2026-06-01); rank arms by
        # solve@75 first, mean% as tiebreaker. solve@60 is a wider discriminator;
        # solve@90/95 are statistically thin (1-7 tasks/arm) so report-not-rank.
        "solve60_pct": 100.0 * float((pcts >= 60).sum()) / n,
        "solve75_pct": 100.0 * float((pcts >= 75).sum()) / n,
        "solve90_pct": 100.0 * float((pcts >= 90).sum()) / n,
        "solve95_pct": 100.0 * float((pcts >= 95).sum()) / n,
        "compile_pct": 100.0 * sum(r.compile_ok for r in rows) / n,
        "any_pass_pct": 100.0 * float((pcts > 0).sum()) / n,
        "ge25_pct":  100.0 * float((pcts >= 25).sum()) / n,
        "ge50_pct":  100.0 * float((pcts >= 50).sum()) / n,
        "ge80_pct":  100.0 * float((pcts >= 80).sum()) / n,
        "ge95_pct":  100.0 * float((pcts >= 95).sum()) / n,
        "perfect_pct": 100.0 * float((pcts == 100).sum()) / n,
        "cost_per_task": float(np.mean([r.cost_usd for r in rows])),
        "turns_per_task": float(np.mean([r.turns for r in rows])),
        # Median, not mean: duration is derived from transcript-birthtime ->
        # submission-mtime, which is corrupted for tasks re-run in a later
        # session (the span covers the inter-session gap, not the agent run).
        # Such tasks show implausible >120min durations (the agent watchdog
        # hard-kills at 120min, so anything beyond is an artifact). Drop those
        # before taking the median so the reported per-task wall time is robust.
        "duration_per_task_min": float(np.median(
            [r.duration_min for r in rows if r.duration_min <= 120.0]
            or [r.duration_min for r in rows]
        )),
        "skills_invoked_pct": 100.0 * sum(len(r.skills_invoked) > 0 for r in rows) / n,
    }


# ---------------------------------------------------------------------------
# Paired comparison
# ---------------------------------------------------------------------------

def pair_compare(rows_a: list[TaskRow], rows_b: list[TaskRow],
                 name_a: str, name_b: str) -> dict:
    """Compute Δ (b - a) on per-task pct, with bootstrap CI, Wilcoxon, and
    McNemar at each ladder threshold. Operates only on tasks present in both."""
    a_by_task = {r.task: r for r in rows_a}
    b_by_task = {r.task: r for r in rows_b}
    common = sorted(set(a_by_task) & set(b_by_task))
    if not common:
        return {"common": 0}

    deltas = np.array([b_by_task[t].pct - a_by_task[t].pct for t in common])
    deltas_ran = np.array([b_by_task[t].pct_ran - a_by_task[t].pct_ran for t in common])

    rng = np.random.default_rng(RNG_SEED)
    n_boot = 10_000
    boots = np.array([
        rng.choice(deltas, size=len(deltas), replace=True).mean()
        for _ in range(n_boot)
    ])
    ci_lo, ci_hi = np.percentile(boots, [2.5, 97.5])

    nonzero = deltas[deltas != 0]
    if len(nonzero) > 0:
        w_res = stats.wilcoxon(nonzero, zero_method="wilcox", alternative="two-sided")
        w_p = float(w_res.pvalue)
    else:
        w_p = 1.0

    wins = int((deltas > 0).sum())
    losses = int((deltas < 0).sum())
    ties = int((deltas == 0).sum())

    # McNemar at each binarization threshold
    def thresh_pred(rows_dict, threshold, kind):
        if kind == "any_pass":
            return np.array([rows_dict[t].pct > 0 for t in common])
        if kind == "perfect":
            return np.array([rows_dict[t].pct == 100 for t in common])
        if kind == "compile":
            return np.array([rows_dict[t].compile_ok for t in common])
        return np.array([rows_dict[t].pct >= threshold for t in common])

    mcnemar_rows = []
    for label, kind, threshold in [
        ("compile",  "compile",  None),
        ("any_pass", "any_pass", None),
        ("≥25",     "ge",        25),
        ("≥50",     "ge",        50),
        ("≥80",     "ge",        80),
        ("≥95",     "ge",        95),
        ("=100",    "perfect",   None),
    ]:
        a_pred = thresh_pred(a_by_task, threshold, kind)
        b_pred = thresh_pred(b_by_task, threshold, kind)
        # 2x2 table:
        #          a_pred=T  a_pred=F
        # b_pred=T   n11        n01
        # b_pred=F   n10        n00
        n11 = int((a_pred & b_pred).sum())
        n01 = int((~a_pred & b_pred).sum())   # b only — gain by switching to b
        n10 = int((a_pred & ~b_pred).sum())   # a only — loss by switching to b
        n00 = int((~a_pred & ~b_pred).sum())
        # McNemar's test (exact binomial when n01+n10 small, chi-square otherwise).
        # scipy >=1.7: use scipy.stats.contingency.relative_risk? actually we use
        # statsmodels in normal life, but to keep deps small we implement it here.
        mp_n = n01 + n10
        if mp_n == 0:
            mc_p = 1.0
        elif mp_n < 25:
            # exact two-sided binomial
            k = min(n01, n10)
            mc_p = float(2 * stats.binom.cdf(k, mp_n, 0.5))
            if mc_p > 1: mc_p = 1.0
        else:
            chi2 = (abs(n01 - n10) - 1) ** 2 / mp_n  # continuity correction
            mc_p = float(stats.chi2.sf(chi2, df=1))
        mcnemar_rows.append({
            "bucket": label,
            "a_only": n10,
            "b_only": n01,
            "delta_count": n01 - n10,
            "p": mc_p,
        })

    return {
        "common": len(common),
        "delta_mean": float(deltas.mean()),
        "delta_median": float(np.median(deltas)),
        "delta_mean_ran": float(deltas_ran.mean()),
        "delta_median_ran": float(np.median(deltas_ran)),
        "ci_lo": float(ci_lo),
        "ci_hi": float(ci_hi),
        "wilcoxon_p": w_p,
        "wins": wins,
        "losses": losses,
        "ties": ties,
        "mcnemar": mcnemar_rows,
    }


def holm_adjust(pvals: list[float]) -> list[float]:
    """Holm-Bonferroni step-down adjusted p-values (preserves input order).
    Deterministic. Used for the codex-pilot-2 family of 8 comparisons
    (codex-free vs each mandated arm)."""
    m = len(pvals)
    order = sorted(range(m), key=lambda i: pvals[i])
    adj = [0.0] * m
    running = 0.0
    for rank, idx in enumerate(order):
        val = (m - rank) * pvals[idx]
        running = max(running, val)  # enforce monotonicity
        adj[idx] = min(1.0, running)
    return adj


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def fmt_pct(x: float, width: int = 5) -> str:
    return f"{x:>{width}.1f}"

def fmt_int(x, width: int = 4) -> str:
    return f"{x:>{width}}"

def render_summary_table(summaries: dict[str, dict]) -> str:
    arms = list(summaries.keys())
    if not arms:
        return "(no arms)"
    arm_w = max(len("arm"), max(len(a) for a in arms))
    fmt = (
        f"{{arm:<{arm_w}}}  {{n:>4}}  "
        f"{{solve75:>8}}  {{solve60:>8}}  {{solve90:>8}}  {{solve95:>8}}  "
        f"{{mean:>6}}  {{ran:>6}}  {{median:>7}}  "
        f"{{compile:>8}}  {{any_pass:>9}}  "
        f"{{ge25:>5}}  {{ge50:>5}}  {{ge80:>5}}  {{ge95:>5}}  {{perfect:>6}}  "
        f"{{cost:>6}}  {{turns:>5}}  {{dur:>5}}  "
        f"{{skills:>7}}"
    )
    header_line = fmt.format(
        arm="arm", n="n",
        solve75="solve@75", solve60="solve@60", solve90="solve@90", solve95="solve@95",
        mean="mean%", ran="ran%", median="median%",
        compile="compile%", any_pass="any_pass%",
        ge25="≥25%", ge50="≥50%", ge80="≥80%", ge95="≥95%", perfect="=100%",
        cost="$/task", turns="turns", dur="min",
        skills="skills%",
    )
    rows = [header_line, "-" * len(header_line)]
    for arm in arms:
        s = summaries[arm]
        rows.append(fmt.format(
            arm=arm, n=str(s["n"]),
            solve75=fmt_pct(s["solve75_pct"], 8),
            solve60=fmt_pct(s["solve60_pct"], 8),
            solve90=fmt_pct(s["solve90_pct"], 8),
            solve95=fmt_pct(s["solve95_pct"], 8),
            mean=fmt_pct(s["mean_pct"]), ran=fmt_pct(s["mean_pct_ran"]),
            median=fmt_pct(s["median_pct"], 7),
            compile=fmt_pct(s["compile_pct"], 8), any_pass=fmt_pct(s["any_pass_pct"], 9),
            ge25=fmt_pct(s["ge25_pct"]), ge50=fmt_pct(s["ge50_pct"]),
            ge80=fmt_pct(s["ge80_pct"]), ge95=fmt_pct(s["ge95_pct"]),
            perfect=fmt_pct(s["perfect_pct"], 6),
            cost=f"${s['cost_per_task']:.2f}",
            turns=f"{s['turns_per_task']:.0f}",
            dur=f"{s['duration_per_task_min']:.1f}",
            skills=fmt_pct(s["skills_invoked_pct"], 7),
        ))
    rows.append("")
    rows.append("solve@75 = % of tasks passing >=75% of their non-ignored tests "
                "(PRIMARY quality metric, Kun 2026-06-01; rank arms by solve@75, mean% as tiebreaker). "
                "solve@60 = wider discriminator; solve@90/95 = stricter cuts, statistically thin "
                "(1-7 tasks/arm on n=200) so report-not-rank. "
                "mean% = pass-rate over ALL non-ignored tests (headline continuous; feeds Wilcoxon/Holm). "
                "ran% = pass-rate over tests that actually ran (excl not_run); "
                "the mean%->ran% gap is the branch not_run/timeout cascade.")
    return "\n".join(rows)


def render_lang_wrap(summaries: dict[str, dict]) -> str:
    """Language-choice distribution + reference-tool wrapping rate per arm."""
    lines = ["arm                  wrap%   language distribution (by task count)"]
    lines.append("-" * len(lines[0]))
    for arm, s in summaries.items():
        dist = "  ".join(f"{k}:{v}" for k, v in s.get("lang_dist", {}).items())
        lines.append(f"{arm:<20} {s.get('wrap_pct', 0.0):>5.1f}   {dist}")
    return "\n".join(lines)


def render_pair_table(name_a: str, name_b: str, p: dict) -> str:
    if not p or p.get("common") == 0:
        return f"(no overlapping tasks between {name_a} and {name_b})"
    lines = [f"=== {name_b} vs {name_a}  (paired on {p['common']} tasks) ==="]
    holm = (f"  holm-adj p={p['holm_p']:.4f}" if "holm_p" in p else "")
    lines.append(
        f"  Δ mean %     {p['delta_mean']:+.2f}  "
        f"95% CI [{p['ci_lo']:+.2f}, {p['ci_hi']:+.2f}]   "
        f"wilcoxon p={p['wilcoxon_p']:.4f}{holm}"
    )
    lines.append(
        f"  Δ mean ran%  {p['delta_mean_ran']:+.2f}   "
        f"(dual metric: delta over tests that ran; vs Δ mean % isolates the cascade)"
    )
    lines.append(
        f"  Δ median %   {p['delta_median']:+.2f}"
    )
    lines.append(
        f"  wins / losses / ties: {p['wins']} / {p['losses']} / {p['ties']}"
    )
    lines.append("")
    lines.append("  bucket    a_only   b_only   Δcount   mcnemar p")
    for m in p["mcnemar"]:
        lines.append(
            f"  {m['bucket']:<8}  "
            f"{m['a_only']:>6}   {m['b_only']:>6}   "
            f"{m['delta_count']:>+6}   {m['p']:.4f}"
        )
    return "\n".join(lines)


def render_ladder(summaries: dict[str, dict], rows_by_arm: dict[str, list[TaskRow]]) -> str:
    """ASCII histogram of how many tasks fall into each score bucket."""
    buckets = [
        ("    0", lambda p: p == 0),
        ("  1-24", lambda p: 0 < p < 25),
        (" 25-49", lambda p: 25 <= p < 50),
        (" 50-79", lambda p: 50 <= p < 80),
        (" 80-94", lambda p: 80 <= p < 95),
        (" 95-99", lambda p: 95 <= p < 100),
        ("   100", lambda p: p == 100),
    ]
    arms = list(summaries.keys())
    counts = {arm: [sum(pred(r.pct) for r in rows_by_arm[arm]) for _, pred in buckets]
              for arm in arms}
    max_count = max((max(c) for c in counts.values()), default=1)
    bar_width = 30
    lines = ["score bucket   " + "  ".join(f"{a:<{bar_width}}" for a in arms)]
    lines.append("-" * len(lines[0]))
    for i, (label, _) in enumerate(buckets):
        cells = []
        for arm in arms:
            c = counts[arm][i]
            bar = "█" * int(round(c / max_count * bar_width)) if max_count > 0 else ""
            cells.append(f"{bar:<{bar_width-5}}{c:>4}")
        lines.append(f"{label:<14} " + "  ".join(cells))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Per-task CSV
# ---------------------------------------------------------------------------

def write_per_task_csv(out_path: Path, rows_by_arm: dict[str, list[TaskRow]]) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "arm", "task", "pct", "pct_ran", "compile_ok",
        "n_total_tests", "n_ran_tests", "n_passed_tests",
        "language", "wraps_tool",
        "cost_usd", "turns", "duration_min", "n_skills_invoked", "skills_invoked",
    ]
    with out_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for arm, rows in rows_by_arm.items():
            for r in sorted(rows, key=lambda x: x.task):
                w.writerow({
                    "arm": arm,
                    "task": r.task,
                    "pct": f"{r.pct:.4f}",
                    "pct_ran": f"{r.pct_ran:.4f}",
                    "compile_ok": int(r.compile_ok),
                    "n_total_tests": r.n_total,
                    "n_ran_tests": r.n_ran,
                    "n_passed_tests": r.n_passed,
                    "language": r.language,
                    "wraps_tool": int(r.wraps_tool),
                    "cost_usd": f"{r.cost_usd:.6f}",
                    "turns": r.turns,
                    "duration_min": f"{r.duration_min:.4f}",
                    "n_skills_invoked": len(r.skills_invoked),
                    "skills_invoked": ",".join(r.skills_invoked),
                })


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--run", required=True, help="Run name (under runs/)")
    ap.add_argument("--arms", required=True,
                    help="Comma-separated arm names. The first is the baseline; "
                         "others are compared against it.")
    args = ap.parse_args()

    repo = Path(__file__).resolve().parent.parent
    arms = [a.strip() for a in args.arms.split(",") if a.strip()]
    instances = {i["instance_id"]: i for i in load_all_instances(include_tests=True)}

    rows_by_arm: dict[str, list[TaskRow]] = {}
    for arm in arms:
        rows_by_arm[arm] = collect_arm(repo, args.run, arm, instances)

    # Drop arms with no data, but keep order
    arms_with_data = [a for a in arms if rows_by_arm[a]]
    if not arms_with_data:
        print(f"[analyze] no eval.json files found under runs/{args.run}/", file=sys.stderr)
        return 1

    summaries = {a: arm_summary(rows_by_arm[a]) for a in arms_with_data}

    out_dir = repo / "runs" / args.run
    out_dir.mkdir(parents=True, exist_ok=True)

    # 1. Summary table
    summary_text = render_summary_table(summaries)

    # 2. Threshold ladder
    ladder_text = render_ladder(summaries, rows_by_arm)

    # 3. Pair comparisons (every non-baseline arm vs the baseline), with a
    #    Holm-Bonferroni correction across the family of comparisons (pilot-2:
    #    codex-free vs each of the 8 mandated arms).
    pair_texts: list[str] = []
    if len(arms_with_data) >= 2:
        baseline = arms_with_data[0]
        cmps = [pair_compare(rows_by_arm[baseline], rows_by_arm[arm], baseline, arm)
                for arm in arms_with_data[1:]]
        raw_ps = [c.get("wilcoxon_p", 1.0) for c in cmps]
        holm_ps = holm_adjust(raw_ps)
        for arm, cmp, hp in zip(arms_with_data[1:], cmps, holm_ps):
            if cmp and cmp.get("common"):
                cmp["holm_p"] = hp
            pair_texts.append(render_pair_table(baseline, arm, cmp))

    # 4. Language choice + reference-tool wrapping (pilot-2 robustness checks)
    lang_wrap_text = render_lang_wrap(summaries)

    full_report = "\n\n".join([
        f"# programbench-bench report  (run: {args.run})",
        "## Per-arm summary",
        summary_text,
        "## Score distribution (threshold ladder)",
        ladder_text,
        "## Language choice + reference-tool wrapping",
        lang_wrap_text,
        *(["## Paired comparisons (Holm-corrected across the family)", *pair_texts] if pair_texts else []),
        "(per-task CSV: runs/{}/per-task.csv)".format(args.run),
    ])
    print(full_report)

    (out_dir / "summary.txt").write_text(full_report + "\n")
    write_per_task_csv(out_dir / "per-task.csv", rows_by_arm)
    return 0


if __name__ == "__main__":
    sys.exit(main())
