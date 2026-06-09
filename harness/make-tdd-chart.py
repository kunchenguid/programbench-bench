#!/usr/bin/env python3
"""Cost-vs-quality chart for the TDD post: control (codex-free) vs codex-free-tdd
at each difficulty tier, with an arrow control->tdd per tier. The arrows all
point down-and-right (less quality, more cost) = TDD is strictly dominated.

Run: cache/pb-venv/bin/python harness/make-tdd-chart.py [POST_DIR]
Reads <POST_DIR>/data/per-task.csv (must contain control + tdd + the 8 mandated
arms; difficulty is defined by the 8 mandated arms so both compared arms are
out-of-sample). Writes <POST_DIR>/cost-vs-quality.svg.
"""
import csv, sys
from statistics import mean

POST_DIR = sys.argv[1] if len(sys.argv) > 1 else "blog/does-tdd-help-coding-agents"
BLOCK = {"sharkdp__hyperfine","eliukblau__pixterm","ggreer__the_silver_searcher","tinycc__tinycc",
         "stathissideris__ditaa","tarka__xcp","alecthomas__chroma","multiprocessio__dsq"}
MAND = ["codex-lang-python","codex-lang-ts","codex-lang-rust","codex-lang-go",
        "codex-lang-js","codex-lang-ruby","codex-lang-c","codex-lang-java"]
def short(t): return t.split(".")[0]

rows = [r for r in csv.DictReader(open(f"{POST_DIR}/data/per-task.csv")) if short(r["task"]) not in BLOCK]
def col(a, k):
    m = {}
    for r in rows:
        if r["arm"] == a:
            try: m[r["task"]] = float(r[k])
            except: m[r["task"]] = 0.0
    return m
pct = {a: col(a, "pct") for a in ["codex-free","codex-free-tdd"] + MAND}
cost = {a: col(a, "cost_usd") for a in ["codex-free","codex-free-tdd"]}
common = sorted(set(pct["codex-free"]) & set(pct["codex-free-tdd"]) & set.intersection(*[set(pct[a]) for a in MAND]))
diff = {t: mean(pct[a][t] for a in MAND) for t in common}
order = sorted(common, key=lambda t: diff[t]); k = len(order)//3
terc = {"HARD": order[:k], "MED": order[k:2*k], "EASY": order[2*k:]}

pts = {}  # tier -> (ctrl_x,ctrl_y,tdd_x,tdd_y)
for nm, ts in terc.items():
    pts[nm] = (mean(cost["codex-free"][t] for t in ts), mean(pct["codex-free"][t] for t in ts),
               mean(cost["codex-free-tdd"][t] for t in ts), mean(pct["codex-free-tdd"][t] for t in ts))

W, H = 600, 470
PX0, PY0, PX1, PY1 = 78, 72, 560, 400
xs = [v for p in pts.values() for v in (p[0], p[2])]
ys = [v for p in pts.values() for v in (p[1], p[3])]
xlo, xhi = min(xs) - 0.06, max(xs) + 0.06
ylo, yhi = min(ys) - 6, max(ys) + 6
def X(c): return PX0 + (c - xlo)/(xhi - xlo)*(PX1 - PX0)
def Y(q): return PY1 - (q - ylo)/(yhi - ylo)*(PY1 - PY0)

CTRL, TDD = "#111111", "#CC342D"
s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" font-family="-apple-system,Helvetica,Arial,sans-serif">']
s.append(f'<rect width="{W}" height="{H}" fill="white"/>')
s.append('<text x="300" y="30" text-anchor="middle" font-size="17" font-weight="bold">TDD: more cost, less quality - at every difficulty</text>')
s.append('<text x="300" y="50" text-anchor="middle" font-size="11" fill="#666">x = token cost ($/task), y = mean test pass-rate %. Arrow = control → TDD. Down-and-right = worse.</text>')
s.append(f'<rect x="{PX0}" y="{PY0}" width="{PX1-PX0}" height="{PY1-PY0}" fill="#fafafa" stroke="#ddd"/>')
s.append('<text x="319" y="442" text-anchor="middle" font-size="12" fill="#444">$ / task</text>')
s.append(f'<text transform="translate(24,236) rotate(-90)" text-anchor="middle" font-size="12" fill="#444">mean pass-rate %</text>')
for i in range(5):
    cx = xlo + (xhi-xlo)*i/4; s.append(f'<text x="{X(cx):.1f}" y="418" text-anchor="middle" font-size="9" fill="#999">${cx:.2f}</text>')
    qy = ylo + (yhi-ylo)*i/4; s.append(f'<text x="70" y="{Y(qy)+3:.1f}" text-anchor="end" font-size="9" fill="#999">{qy:.0f}</text>')
s.append('<defs><marker id="ar" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto"><path d="M0,0 L7,3 L0,6 Z" fill="#CC342D"/></marker></defs>')
for nm in ["EASY","MED","HARD"]:
    cx, cy, tx, ty = pts[nm]
    # arrow control -> tdd (shortened so it doesn't overlap the dots)
    import math
    x1,y1,x2,y2 = X(cx),Y(cy),X(tx),Y(ty)
    dx,dy = x2-x1, y2-y1; L=math.hypot(dx,dy); ux,uy=dx/L,dy/L
    s.append(f'<line x1="{x1+ux*8:.1f}" y1="{y1+uy*8:.1f}" x2="{x2-ux*10:.1f}" y2="{y2-uy*10:.1f}" stroke="#CC342D" stroke-width="1.5" opacity="0.55" marker-end="url(#ar)"/>')
    s.append(f'<circle cx="{x1:.1f}" cy="{y1:.1f}" r="6" fill="{CTRL}" stroke="white" stroke-width="1.2"/>')
    s.append(f'<circle cx="{x2:.1f}" cy="{y2:.1f}" r="6" fill="{TDD}" stroke="white" stroke-width="1.2"/>')
    s.append(f'<text x="{x1-9:.1f}" y="{y1+3:.1f}" text-anchor="end" font-size="11" font-weight="600" fill="#444">{nm}</text>')
# legend
s.append(f'<circle cx="430" cy="86" r="6" fill="{CTRL}" stroke="white" stroke-width="1.2"/><text x="441" y="90" font-size="12" fill="#111">control (free choice)</text>')
s.append(f'<circle cx="430" cy="106" r="6" fill="{TDD}" stroke="white" stroke-width="1.2"/><text x="441" y="110" font-size="12" fill="{TDD}">test-driven (TDD)</text>')
s.append('</svg>')
open(f"{POST_DIR}/cost-vs-quality.svg","w").write("\n".join(s)+"\n")
print(f"wrote {POST_DIR}/cost-vs-quality.svg")
for nm in ["HARD","MED","EASY"]:
    cx,cy,tx,ty=pts[nm]; print(f"  {nm}: control (${cx:.2f},{cy:.1f}) -> tdd (${tx:.2f},{ty:.1f})")
