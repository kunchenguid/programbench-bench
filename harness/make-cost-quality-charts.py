#!/usr/bin/env python3
"""Regenerate the blog's 3 cost-vs-quality SVG charts (hard/med/easy terciles)
from the live de-polluted + 6h-fixed n=193 data.

x = token cost ($/task), y = mean test pass-rate %, one brand-colored point per
arm, median dashed quadrant lines, greedy label de-collision with leader lines.

Run: cache/pb-venv/bin/python harness/make-cost-quality-charts.py [POST_DIR]
Reads <POST_DIR>/data/per-task.csv (the co-located, reader-accessible snapshot;
must contain all 9 language arms). Writes <POST_DIR>/cost-quality-{hard,med,easy}.svg.
POST_DIR defaults to the programming-languages post.
To refresh the snapshot from a fresh run: analyze.py --run codex-pilot-2 ...
then cp runs/codex-pilot-2/per-task.csv <POST_DIR>/data/per-task.csv.
"""
import csv
import sys
from statistics import mean, median

POST_DIR = sys.argv[1] if len(sys.argv) > 1 else "blog/best-programming-languages-for-agents"

BLOCK = {"sharkdp__hyperfine", "eliukblau__pixterm", "ggreer__the_silver_searcher",
         "tinycc__tinycc", "stathissideris__ditaa", "tarka__xcp", "alecthomas__chroma"}
ARMS = ["codex-free", "codex-lang-python", "codex-lang-ts", "codex-lang-rust",
        "codex-lang-go", "codex-lang-js", "codex-lang-ruby", "codex-lang-c", "codex-lang-java"]
NAME = {"codex-free": "free", "codex-lang-python": "python", "codex-lang-ts": "ts",
        "codex-lang-rust": "rust", "codex-lang-go": "go", "codex-lang-js": "js",
        "codex-lang-ruby": "ruby", "codex-lang-c": "c", "codex-lang-java": "java"}
# GitHub-Linguist-ish brand colors
COLOR = {"free": "#111111", "python": "#3572A5", "ts": "#3178C6", "rust": "#B7410E",
         "go": "#00ADD8", "js": "#D4B500", "ruby": "#CC342D", "c": "#555555", "java": "#B07219"}

def short(t): return t.split(".")[0]

def load():
    rows = [r for r in csv.DictReader(open(f"{POST_DIR}/data/per-task.csv"))
            if short(r["task"]) not in BLOCK]
    pct = {a: {} for a in ARMS}; cost = {a: {} for a in ARMS}
    for r in rows:
        a = r["arm"]
        if a not in pct: continue
        try: pct[a][r["task"]] = float(r["pct"])
        except: pct[a][r["task"]] = 0.0
        try: cost[a][r["task"]] = float(r["cost_usd"])
        except: cost[a][r["task"]] = 0.0
    common = sorted(set.intersection(*[set(pct[a]) for a in ARMS]))
    diff = {t: mean(pct[a][t] for a in ARMS) for t in common}
    order = sorted(common, key=lambda t: diff[t]); k = len(order) // 3
    terc = {"HARD": order[:k], "MED": order[k:2 * k], "EASY": order[2 * k:]}
    return pct, cost, terc

# plot geometry
W, H = 560, 460
PX0, PY0, PX1, PY1 = 70, 70, 530, 400

def nice_range(lo, hi, pad_frac=0.12, min_pad=0.0):
    pad = max((hi - lo) * pad_frac, min_pad)
    return lo - pad, hi + pad

def esc(s): return s

def chart(tier, tasks, pct, cost):
    pts = []
    for a in ARMS:
        q = mean(pct[a][t] for t in tasks)
        c = mean(cost[a][t] for t in tasks)
        pts.append((NAME[a], q, c))
    qs = [p[1] for p in pts]; cs = [p[2] for p in pts]
    xlo, xhi = nice_range(min(cs), max(cs), 0.12, 0.02)
    ylo, yhi = nice_range(min(qs), max(qs), 0.14, 1.0)
    medx, medy = median(cs), median(qs)

    def X(c): return PX0 + (c - xlo) / (xhi - xlo) * (PX1 - PX0)
    def Y(q): return PY1 - (q - ylo) / (yhi - ylo) * (PY1 - PY0)

    s = []
    s.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
             f'font-family="-apple-system,Helvetica,Arial,sans-serif">')
    s.append(f'<rect width="{W}" height="{H}" fill="white"/>')
    s.append(f'<text x="280.0" y="28" text-anchor="middle" font-size="17" font-weight="bold">'
             f'{tier} tasks: cost vs quality</text>')
    s.append('<text x="280.0" y="48" text-anchor="middle" font-size="11" fill="#666">'
             'x = token cost ($/task), y = mean pass-rate %. Top-left = cheap + good. Dashed = medians.</text>')
    s.append(f'<rect x="{PX0}" y="{PY0}" width="{PX1-PX0}" height="{PY1-PY0}" fill="#fafafa" stroke="#ddd"/>')
    # median lines
    s.append(f'<line x1="{X(medx):.1f}" y1="{PY0}" x2="{X(medx):.1f}" y2="{PY1}" stroke="#ccc" stroke-dasharray="5 4"/>')
    s.append(f'<line x1="{PX0}" y1="{Y(medy):.1f}" x2="{PX1}" y2="{Y(medy):.1f}" stroke="#ccc" stroke-dasharray="5 4"/>')
    # axis titles
    s.append(f'<text x="300.0" y="438" text-anchor="middle" font-size="12" fill="#444">$ / task</text>')
    s.append(f'<text transform="translate(20,235.0) rotate(-90)" text-anchor="middle" font-size="12" fill="#444">mean pass-rate %</text>')
    # 5 ticks each
    for i in range(5):
        cx = xlo + (xhi - xlo) * i / 4
        px = X(cx)
        s.append(f'<text x="{px:.1f}" y="418" text-anchor="middle" font-size="9" fill="#999">${cx:.2f}</text>')
        qy = ylo + (yhi - ylo) * i / 4
        py = Y(qy)
        s.append(f'<text x="62" y="{py+3:.1f}" text-anchor="end" font-size="9" fill="#999">{qy:.0f}</text>')
    # points, sorted top-to-bottom for label stacking
    pts_xy = sorted(((nm, X(c), Y(q)) for nm, q, c in pts), key=lambda p: p[2])
    placed = []  # label boxes (x0,y0,x1,y1)
    def box(lx, ly, nm, anchor):
        w = len(nm) * 7 + 4
        x0 = lx if anchor == "start" else lx - w
        return (x0, ly - 10, x0 + w, ly + 4)
    def hit(b):
        return any(not (b[2] < p[0] or b[0] > p[2] or b[3] < p[1] or b[1] > p[3]) for p in placed)
    body = []
    for nm, cx, cy in pts_xy:
        col = COLOR[nm]
        # default label right of point; flip left near right edge
        anchor = "end" if cx + 9 + len(nm) * 7 > PX1 + 22 else "start"
        lx = cx + 9 if anchor == "start" else cx - 9
        ly = cy + 3
        b = box(lx, ly, nm, anchor)
        shifted = False
        while hit(b):
            ly += 12; b = box(lx, ly, nm, anchor); shifted = True
        placed.append(b)
        body.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="6" fill="{col}" stroke="white" stroke-width="1.2"/>')
        if shifted:
            sx = cx + 6 if anchor == "start" else cx - 6
            body.append(f'<line x1="{sx:.1f}" y1="{cy:.1f}" x2="{lx:.1f}" y2="{ly-3:.1f}" '
                        f'stroke="{col}" stroke-width="0.7" opacity="0.5"/>')
        ta = "start" if anchor == "start" else "end"
        body.append(f'<text x="{lx:.1f}" y="{ly:.1f}" font-size="12" font-weight="600" '
                    f'fill="{col}" text-anchor="{ta}">{nm}</text>')
    s.extend(body)
    s.append('</svg>')
    return "\n".join(s) + "\n"

def main():
    pct, cost, terc = load()
    fn = {"HARD": "hard", "MED": "med", "EASY": "easy"}
    for tier in ["HARD", "MED", "EASY"]:
        svg = chart(tier, terc[tier], pct, cost)
        path = f"{POST_DIR}/cost-quality-{fn[tier]}.svg"
        open(path, "w").write(svg)
        print(f"wrote {path} (n={len(terc[tier])})")

if __name__ == "__main__":
    main()
