#!/usr/bin/env python3
"""Flexibility-vs-long-horizon-coherence analysis over codex-pilot-2.

EXPLORATORY (post-hoc; shaped after seeing the data). Question (Kun, 2026-06-10):
do flexible languages (python-like) trade fewer "local gotchas" (compile/type
errors stalling the agent) for worse long-horizon coherence (degradation as
project scale grows), and vice versa for strictly-typed languages?

Operationalization:
  gotcha tax   = build failures, static-error commands, same-error loops,
                 position of first green build (from transcripts).
  deferred err = static vs runtime error share at agent time; not_run share
                 at eval time (errors that survived to scoring).
  coherence    = pass-rate slope vs task scale (n_total_tests; cross-arm
                 median submission LOC as a second proxy), leave-one-out
                 difficulty terciles, paired dyn-vs-static deltas by stratum.

Denominator: n=192 (analyze.py REPORT_BLOCKLIST applied).
Outputs: printed report + analysis/flexibility_results.json for the viz.
"""
import json
import sys
import numpy as np
import pandas as pd
from scipy import stats

REPO = "/Users/kunchen/github/kunchenguid/programbench-bench"
BLOCKLIST = {
    "sharkdp__hyperfine", "eliukblau__pixterm", "ggreer__the_silver_searcher",
    "tinycc__tinycc", "stathissideris__ditaa", "tarka__xcp",
    "alecthomas__chroma", "multiprocessio__dsq",
}
MANDATED = ["c", "go", "java", "js", "python", "ruby", "rust", "ts"]
STATIC_LANGS = {"rust", "go", "java", "c", "ts"}
DYNAMIC_LANGS = {"python", "ruby", "js"}

traj = pd.read_csv(f"{REPO}/analysis/trajectory_metrics.csv")
res = pd.read_csv(f"{REPO}/runs/codex-pilot-2/per-task.csv")

for df in (traj, res):
    df["repo"] = df["task"].str.split(".").str[0]
df = res.merge(traj.drop(columns=["lang"]), on=["arm", "task"], how="left",
               suffixes=("", "_traj"))
df = df[~df["repo"].isin(BLOCKLIST)].copy()
df["not_run"] = df["n_total_tests"] - df["n_ran_tests"]
df["not_run_frac"] = df["not_run"] / df["n_total_tests"]
df["failed_frac_of_ran"] = np.where(
    df["n_ran_tests"] > 0,
    (df["n_ran_tests"] - df["n_passed_tests"]) / df["n_ran_tests"], np.nan)

m = df[df["arm"] != "codex-free"].copy()           # 8 mandated arms
m["lang"] = m["arm"].str.replace("codex-lang-", "", regex=False)
free = df[df["arm"] == "codex-free"].copy()

ntasks = m.groupby("lang")["task"].nunique()
assert ntasks.min() == ntasks.max() == 192, ntasks
out = {"n": 192}

# ---------------------------------------------------------------- gotcha tax
def loop3(s):  # share of tasks with a >=3-long identical-error loop
    return (s >= 3).mean()

g = m.groupby("lang").agg(
    pct=("pct", "mean"),
    solve75=("pct", lambda s: (s >= 75).mean() * 100),
    failed_cmds=("n_failed_cmds", "mean"),
    fail_rate=("fail_rate", "mean"),
    build_fail_rate=("build_fail_rate", "mean"),
    static_errs=("n_static_err_cmds", "mean"),
    runtime_errs=("n_runtime_err_cmds", "mean"),
    static_share=("static_share", "mean"),
    loop_max=("max_same_err_loop", "mean"),
    loop3_share=("max_same_err_loop", loop3),
    first_green=("first_green_build_pos", "mean"),
    late_fail_frac=("late_fail_frac", "mean"),
    re_edits=("n_re_edits", "mean"),
    late_re_edits=("n_late_re_edits", "mean"),
    churn=("churn", "mean"),
    loc=("sub_loc", "mean"),
    src_files=("sub_src_files", "mean"),
    turns=("turns", "mean"),
    duration=("duration_min", "median"),
    compile_ok=("compile_ok", "mean"),
    not_run_frac=("not_run_frac", "mean"),
    failed_of_ran=("failed_frac_of_ran", "mean"),
).round(3)
g["group"] = ["static" if l in STATIC_LANGS else "dynamic" for l in g.index]
print("=" * 100)
print("PER-LANGUAGE TRAJECTORY PROFILE (mandated arms, n=192) -- EXPLORATORY")
print(g.to_string())
out["per_lang"] = g.reset_index().to_dict("records")

grp = m.copy()
grp["group"] = grp["lang"].map(lambda l: "static" if l in STATIC_LANGS else "dynamic")
gg = grp.groupby("group")[["fail_rate", "n_static_err_cmds", "n_runtime_err_cmds",
                           "max_same_err_loop", "n_late_re_edits", "churn",
                           "not_run_frac", "failed_frac_of_ran", "pct"]].mean().round(3)
print("\nSTATIC vs DYNAMIC group means:")
print(gg.to_string())
out["group_means"] = gg.reset_index().to_dict("records")

# Mann-Whitney static vs dynamic on key trajectory metrics (task-level pooled)
print("\nstatic-vs-dynamic tests (Mann-Whitney, pooled tasks):")
out["group_tests"] = {}
for col in ["n_static_err_cmds", "n_runtime_err_cmds", "max_same_err_loop",
            "not_run_frac", "failed_frac_of_ran", "n_late_re_edits"]:
    a = grp.loc[grp.group == "static", col].dropna()
    b = grp.loc[grp.group == "dynamic", col].dropna()
    u, p = stats.mannwhitneyu(a, b)
    print(f"  {col:24s} static={a.mean():7.3f} dynamic={b.mean():7.3f} p={p:.2e}")
    out["group_tests"][col] = {"static": a.mean(), "dynamic": b.mean(), "p": p}

# ------------------------------------------------- does the gotcha tax bite?
# Within-language: tasks where the agent hit a >=3 same-error loop vs not.
print("\n" + "=" * 100)
print("DOES GETTING STUCK COST OUTCOME? pct on loop>=3 tasks vs others, per language")
rows = []
for lang, sub in m.groupby("lang"):
    stuck = sub[sub.max_same_err_loop >= 3]
    ok = sub[sub.max_same_err_loop < 3]
    if len(stuck) >= 5:
        u, p = stats.mannwhitneyu(stuck.pct, ok.pct)
        rows.append({"lang": lang, "n_stuck": len(stuck),
                     "pct_stuck": stuck.pct.mean(), "pct_ok": ok.pct.mean(),
                     "delta": stuck.pct.mean() - ok.pct.mean(), "p": p})
loopcost = pd.DataFrame(rows).round(3)
print(loopcost.to_string(index=False))
out["loop_cost"] = loopcost.to_dict("records")

# -------------------------------------------------------------- scale proxies
# Exogenous-ish scale: cross-arm median submission LOC per task (how big the
# project objectively needs to be), excluding the language being scored
# (leave-one-out) to avoid endogeneity; plus n_total_tests (fully exogenous).
piv_loc = m.pivot_table(index="task", columns="lang", values="sub_loc")
piv_pct = m.pivot_table(index="task", columns="lang", values="pct")
tests_per_task = m.groupby("task")["n_total_tests"].first()

def loo_median_loc(lang):
    return piv_loc.drop(columns=[lang]).median(axis=1)

# difficulty (leave-one-out cross-arm mean pct; low = hard)
def loo_difficulty(exclude):
    return piv_pct.drop(columns=[c for c in exclude if c in piv_pct]).mean(axis=1)

# ------------------------------------------- long-horizon interaction per lang
print("\n" + "=" * 100)
print("LONG-HORIZON: pass-rate slope vs scale, per language -- EXPLORATORY")
print("scale A = log(n_total_tests); scale B = log(leave-one-out median sub LOC)")
rows = []
for lang in MANDATED:
    sub = m[m.lang == lang].set_index("task")
    sA = np.log10(tests_per_task.reindex(sub.index).astype(float))
    sB = np.log10(loo_median_loc(lang).reindex(sub.index).astype(float))
    y = sub["pct"]
    rA = stats.spearmanr(sA, y, nan_policy="omit")
    rB = stats.spearmanr(sB, y, nan_policy="omit")
    rows.append({"lang": lang, "rho_tests": rA.statistic, "p_tests": rA.pvalue,
                 "rho_loc": rB.statistic, "p_loc": rB.pvalue})
slopes = pd.DataFrame(rows).round(4)
print(slopes.to_string(index=False))
out["scale_corr"] = slopes.to_dict("records")

# ---------------------------------- paired dyn-vs-static deltas by scale bin
print("\n" + "=" * 100)
print("PAIRED python-vs-typed delta by scale tercile (python pct - other pct)")
pairs = [("python", o) for o in ["rust", "go", "java", "ts", "c"]] + \
        [("js", "ts")]
rows = []
for dyn, st in pairs:
    delta = (piv_pct[dyn] - piv_pct[st]).dropna()
    scale = loo_median_loc("python").reindex(delta.index)  # same proxy for all
    terc = pd.qcut(scale, 3, labels=["small", "mid", "large"])
    for t in ["small", "mid", "large"]:
        d = delta[terc == t]
        w = stats.wilcoxon(d, zero_method="zsplit") if (d != 0).any() else None
        rows.append({"pair": f"{dyn}-vs-{st}", "tercile": t, "n": len(d),
                     "mean_delta": d.mean(), "median_delta": d.median(),
                     "win": (d > 0).sum(), "lose": (d < 0).sum(),
                     "p_wilcoxon": w.pvalue if w else np.nan})
    # interaction: slope of delta vs log-scale
    sl = stats.spearmanr(np.log10(scale.astype(float)), delta, nan_policy="omit")
    rows.append({"pair": f"{dyn}-vs-{st}", "tercile": "SLOPE(rho)", "n": len(delta),
                 "mean_delta": sl.statistic, "median_delta": np.nan,
                 "win": np.nan, "lose": np.nan, "p_wilcoxon": sl.pvalue})
paired = pd.DataFrame(rows).round(4)
print(paired.to_string(index=False))
out["paired_by_scale"] = paired.to_dict("records")

# Same by LOO difficulty terciles (hard vs easy rather than big vs small)
print("\nPAIRED python-vs-typed delta by LEAVE-BOTH-OUT difficulty tercile")
rows = []
for dyn, st in pairs:
    delta = (piv_pct[dyn] - piv_pct[st]).dropna()
    diff = loo_difficulty([dyn, st]).reindex(delta.index)
    terc = pd.qcut(diff, 3, labels=["hard", "mid", "easy"])
    for t in ["hard", "mid", "easy"]:
        d = delta[terc == t]
        w = stats.wilcoxon(d, zero_method="zsplit") if (d != 0).any() else None
        rows.append({"pair": f"{dyn}-vs-{st}", "tercile": t, "n": len(d),
                     "mean_delta": d.mean(),
                     "win": (d > 0).sum(), "lose": (d < 0).sum(),
                     "p_wilcoxon": w.pvalue if w else np.nan})
    sl = stats.spearmanr(diff, delta, nan_policy="omit")
    rows.append({"pair": f"{dyn}-vs-{st}", "tercile": "SLOPE(rho)", "n": len(delta),
                 "mean_delta": sl.statistic, "win": np.nan, "lose": np.nan,
                 "p_wilcoxon": sl.pvalue})
paired_d = pd.DataFrame(rows).round(4)
print(paired_d.to_string(index=False))
out["paired_by_difficulty"] = paired_d.to_dict("records")

# ------------------------------------------------ within-trajectory horizon
print("\n" + "=" * 100)
print("WITHIN-TRAJECTORY: where do errors/rework land? (early vs late)")
h = m.groupby("lang")[["early_fail_frac", "late_fail_frac", "late_static_errs",
                       "n_late_re_edits", "static_share"]].mean().round(3)
print(h.to_string())
out["horizon"] = h.reset_index().to_dict("records")

# eval-time deferred failure: not_run given compile_ok (program built but
# tests never ran = runtime collapse at scoring time)
print("\nEval-time deferral: among compile_ok submissions, share of tests not_run")
dr = m[m.compile_ok == 1].groupby("lang").agg(
    n=("task", "count"), not_run_frac=("not_run_frac", "mean"),
    failed_of_ran=("failed_frac_of_ran", "mean")).round(3)
print(dr.to_string())
out["eval_deferral"] = dr.reset_index().to_dict("records")

# ---------------------------------------------------------------- free arm
print("\n" + "=" * 100)
print("FREE-CHOICE ARM: what codex-free picked, and its trajectory profile vs mandated same-language")
fl = free.groupby("language").agg(n=("task", "count"), pct=("pct", "mean")).round(2)
print(fl.to_string())
out["free_choice"] = fl.reset_index().to_dict("records")

# scatter data for viz: per-task scale x delta for the headline pair
sc = pd.DataFrame({
    "task": piv_pct.index,
    "delta_py_rust": (piv_pct["python"] - piv_pct["rust"]).values,
    "delta_py_ts": (piv_pct["python"] - piv_pct["ts"]).values,
    "scale_loc": loo_median_loc("python").reindex(piv_pct.index).values,
    "n_tests": tests_per_task.reindex(piv_pct.index).values,
    "difficulty": loo_difficulty(["python", "rust"]).reindex(piv_pct.index).values,
}).dropna(subset=["delta_py_rust"])
out["scatter"] = sc.round(3).to_dict("records")

# per-lang pct-vs-scale binned curves for viz
curves = {}
scale_all = loo_median_loc("python")  # common scale proxy
bins = pd.qcut(scale_all, 4, labels=["Q1 small", "Q2", "Q3", "Q4 large"])
for lang in MANDATED:
    sub = m[m.lang == lang].set_index("task")
    bl = bins.reindex(sub.index)
    curves[lang] = sub.groupby(bl, observed=True)["pct"].mean().round(2).to_dict()
print("\nMean pct by project-scale quartile (cross-arm median LOC):")
cv = pd.DataFrame(curves).T
print(cv.to_string())
out["scale_curves"] = {k: v for k, v in curves.items()}

with open(f"{REPO}/analysis/flexibility_results.json", "w") as f:
    json.dump(out, f, indent=1, default=float)
print("\nwrote analysis/flexibility_results.json", file=sys.stderr)
