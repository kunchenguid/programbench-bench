# codex-free-rtk — findings

Arm: `codex-free` (free-language choice, stripped cleanroom) **+ the [rtk](https://github.com/rtk-ai/rtk) "Rust Token Killer" CLI**.
rtk is a CLI proxy that filters/compresses command output (`rtk cargo test`, `rtk pytest`, `rtk read/grep/ls`, `rtk git diff`, ...) to cut the tokens that reach the agent's context.
Delivered as the single experimental variable vs `codex-free`: the rtk binary is installed into the cleanroom (`harness/run-codex.sh`, gated on the vendored `rtk-x86_64-unknown-linux-musl.tar.gz`) and rtk's own instruction catalog is injected via `AGENTS.md` + an orchestration mandate.
Model held constant (gpt-5.5). n=192 (8 blocklisted), paired against `codex-free`.

## Result (final, fair-rescored)

| metric | codex-free | codex-free-rtk | Δ |
| --- | --- | --- | --- |
| **$ / task** | $1.12 | **$1.38** | **+23%** |
| **turns** | 40 | **58** | **+45%** |
| **ran %** (cap-independent) | 55.1 | 53.6 | **−1.5** |
| mean % | 53.7 | 51.1 | −2.6 (Wilcoxon p=0.0025) |
| solve@75 | 13.5 | 12.0 | −1.6 |
| win/lose/tie | — | — | 66 / 103 / 23 |

**On ProgramBench, rtk made the agent ~23% more expensive AND modestly worse on quality** — the opposite of its token-saving purpose.

## IMPORTANT: this does NOT generalize to "rtk is bad"

The result is tied to ProgramBench's task shape: **black-box CLI reverse-engineering**, where the agent must observe the reference tool's *exact* bytes to clone it.
rtk's value proposition (compress command output) is structurally mismatched to that: compression would corrupt the very output the agent needs.
On rtk's actual target — long-lived codebases with verbose build/test/lint output to compress — the conclusion could easily flip. Treat this as directional evidence about one task shape, not a verdict on the tool.

## Mechanism

- **Cost (+23% / +45%): well-understood and causal.** The agent prefixed commands with rtk, but routed **~65% through `rtk proxy` (raw, zero compression)** because it needed exact reference output, and did +27% more reference probes. Net **+31% more commands/task**; the agent loop re-feeds the growing transcript each step, so more steps → **+45% uncached input tokens (= the turn count) → +23% cost.** Per-call compression *did* work (−5%) but was swamped. Command-count and token-blowup track tightly per task.
- **Quality (~−1.5 ran%): direction clear, causal attribution weaker.** The "compression hid info" hypothesis is **refuted** (correlation ≈ 0; rtk probed the reference *more* than free). The gap is "workflow distraction" — rtk's arm made worse build-vs-leverage calls on specific tasks (hand-rolled a fake-brotli where free found Node's real `zlib.brotli`; a Python JS-interpreter where free used Node's `vm`; narrower happy-path probing). But with **single-sample-per-task**, some of the −1.5 is run-to-run variance, not an rtk effect. Suggestive, not proven; would need replication (3-5× per arm on the biggest losers) to firm up.

## Eval-methodology caveats (so the numbers are trustworthy)

- **Timeout parity**: codex-free was scored at a 6h per-branch cap. An early rtk pass used 900s, which under-scored rtk's heavy tasks (the "baseline-vintage" trap). Fixed by re-running the affected tasks at the matching budget. See the "Timeout parity is mandatory" note in `AGENTS.md`.
- **Residual cap**: 8 heavy/blocking tasks (brotli, php, sqlite, broot, nnn, tig, bore, grex) still hit a 90-min bound (vs free's 6h). The **ran% metric (−1.5) is cap-independent** and is the cleanest single quality number; the mean% (−2.6) carries a ≤1.3-pt residual from these 8. True mean% gap ≈ −1.3 to −2.6.
- Cost figures are agent-side (token-derived) and unaffected by any eval-scoring issue.
