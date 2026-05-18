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
import sys
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


@dataclass
class TaskRow:
    arm: str
    task: str
    pct: float           # % tests passed (0-100)
    compile_ok: bool
    n_total: int
    n_passed: int
    cost_usd: float
    turns: int
    duration_min: float
    skills_invoked: tuple[str, ...]   # which skills the agent called via the Skill tool


# ---------------------------------------------------------------------------
# Per-task extraction
# ---------------------------------------------------------------------------

def load_task(eval_path: Path, transcript_path: Path, instance_meta: dict | None,
              arm: str, task: str) -> TaskRow:
    """Compute one TaskRow from an eval.json + matching transcript.jsonl."""
    result = EvaluationResult.model_validate_json(eval_path.read_text())
    if instance_meta is not None:
        active = get_active_branches(instance_meta)
        ignored_tests = get_ignored_tests(instance_meta)
        result = result.for_branches(active).without_ignored(ignored_tests)

    n_total = len(result.test_results)
    n_passed = sum(1 for t in result.test_results if t.status == "passed")
    pct = (100.0 * n_passed / n_total) if n_total > 0 else 0.0
    compile_ok = result.error_code != "compile_failed"

    cost = 0.0
    turns = 0
    duration_ms = 0.0
    skills_invoked: list[str] = []
    if transcript_path.exists():
        for line in transcript_path.read_text().splitlines():
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = e.get("type")
            if t == "result":
                # Some runs emit multiple result events when claude -p does an
                # internal session resume (we've seen this triggered by a
                # post-result wrap-up turn). total_cost_usd is monotonic across
                # those, so we take the max; num_turns and duration_ms are
                # per-segment, so we sum.
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
        cost_usd=cost,
        turns=turns,
        duration_min=duration_ms / 60000,
        skills_invoked=tuple(sorted(set(skills_invoked))),
    )


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
        eval_path = task_dir / f"{task}.eval.json"
        if not eval_path.exists():
            print(f"[analyze] WARN: no eval.json for {arm}/{task}; skip "
                  "(run `programbench eval ...` first)", file=sys.stderr)
            continue
        transcript = arm_logs / task / "transcript.jsonl"
        rows.append(load_task(eval_path, transcript, instances.get(task), arm, task))
    return rows


# ---------------------------------------------------------------------------
# Aggregation per arm
# ---------------------------------------------------------------------------

def arm_summary(rows: list[TaskRow]) -> dict:
    n = len(rows)
    if n == 0:
        return {}
    pcts = np.array([r.pct for r in rows])
    return {
        "n": n,
        "mean_pct": float(pcts.mean()),
        "median_pct": float(np.median(pcts)),
        "compile_pct": 100.0 * sum(r.compile_ok for r in rows) / n,
        "any_pass_pct": 100.0 * float((pcts > 0).sum()) / n,
        "ge25_pct":  100.0 * float((pcts >= 25).sum()) / n,
        "ge50_pct":  100.0 * float((pcts >= 50).sum()) / n,
        "ge80_pct":  100.0 * float((pcts >= 80).sum()) / n,
        "ge95_pct":  100.0 * float((pcts >= 95).sum()) / n,
        "perfect_pct": 100.0 * float((pcts == 100).sum()) / n,
        "cost_per_task": float(np.mean([r.cost_usd for r in rows])),
        "turns_per_task": float(np.mean([r.turns for r in rows])),
        "duration_per_task_min": float(np.mean([r.duration_min for r in rows])),
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
        "ci_lo": float(ci_lo),
        "ci_hi": float(ci_hi),
        "wilcoxon_p": w_p,
        "wins": wins,
        "losses": losses,
        "ties": ties,
        "mcnemar": mcnemar_rows,
    }


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
    headers = [
        "arm", "n",
        "mean%", "median%",
        "compile%", "any_pass%",
        "≥25%", "≥50%", "≥80%", "≥95%", "=100%",
        "$/task", "turns", "min",
        "skills%",
    ]
    arm_w = max(len("arm"), max(len(a) for a in arms))
    fmt = (
        f"{{arm:<{arm_w}}}  {{n:>4}}  "
        f"{{mean:>6}}  {{median:>7}}  "
        f"{{compile:>8}}  {{any_pass:>9}}  "
        f"{{ge25:>5}}  {{ge50:>5}}  {{ge80:>5}}  {{ge95:>5}}  {{perfect:>6}}  "
        f"{{cost:>6}}  {{turns:>5}}  {{dur:>5}}  "
        f"{{skills:>7}}"
    )
    header_line = fmt.format(
        arm="arm", n="n",
        mean="mean%", median="median%",
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
            mean=fmt_pct(s["mean_pct"]), median=fmt_pct(s["median_pct"], 7),
            compile=fmt_pct(s["compile_pct"], 8), any_pass=fmt_pct(s["any_pass_pct"], 9),
            ge25=fmt_pct(s["ge25_pct"]), ge50=fmt_pct(s["ge50_pct"]),
            ge80=fmt_pct(s["ge80_pct"]), ge95=fmt_pct(s["ge95_pct"]),
            perfect=fmt_pct(s["perfect_pct"], 6),
            cost=f"${s['cost_per_task']:.2f}",
            turns=f"{s['turns_per_task']:.0f}",
            dur=f"{s['duration_per_task_min']:.1f}",
            skills=fmt_pct(s["skills_invoked_pct"], 7),
        ))
    return "\n".join(rows)


def render_pair_table(name_a: str, name_b: str, p: dict) -> str:
    if not p or p.get("common") == 0:
        return f"(no overlapping tasks between {name_a} and {name_b})"
    lines = [f"=== {name_b} vs {name_a}  (paired on {p['common']} tasks) ==="]
    lines.append(
        f"  Δ mean %     {p['delta_mean']:+.2f}  "
        f"95% CI [{p['ci_lo']:+.2f}, {p['ci_hi']:+.2f}]   "
        f"wilcoxon p={p['wilcoxon_p']:.4f}"
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
        "arm", "task", "pct", "compile_ok", "n_total_tests", "n_passed_tests",
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
                    "compile_ok": int(r.compile_ok),
                    "n_total_tests": r.n_total,
                    "n_passed_tests": r.n_passed,
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

    # 3. Pair comparisons (every non-baseline arm vs the baseline)
    pair_texts: list[str] = []
    if len(arms_with_data) >= 2:
        baseline = arms_with_data[0]
        for arm in arms_with_data[1:]:
            cmp = pair_compare(rows_by_arm[baseline], rows_by_arm[arm], baseline, arm)
            pair_texts.append(render_pair_table(baseline, arm, cmp))

    full_report = "\n\n".join([
        f"# programbench-bench report  (run: {args.run})",
        "## Per-arm summary",
        summary_text,
        "## Score distribution (threshold ladder)",
        ladder_text,
        *(["## Paired comparisons", *pair_texts] if pair_texts else []),
        "(per-task CSV: runs/{}/per-task.csv)".format(args.run),
    ])
    print(full_report)

    (out_dir / "summary.txt").write_text(full_report + "\n")
    write_per_task_csv(out_dir / "per-task.csv", rows_by_arm)
    return 0


if __name__ == "__main__":
    sys.exit(main())
