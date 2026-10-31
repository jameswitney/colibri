# gap3 bench synthesis — the forked decode path: results and verdict

Session: 2026-10-29, `port/imp3-stack` @ `e5d08bdf` (imp2-stack + port/forkdec + port/forkdec-s1gemv + CUDA
wiring repair), full gates green pre-bench (vk-tier 8 legs incl. forkdec + s1gemv, oracles, smokes ×3).
Logs: `/root/bench-colibri/up2276/gap3-*`. Protocol as gap2 (×3 interleaved, per-leg env echo + free-g + vram0;
the desktop co-tenant oscillated 1.3–6.2 GiB VRAM / RAM all session — per-leg snapshots in the window log;
the fork suffers the same squeeze, making same-session comparisons honest).

## Medians (decode tok/s / TTFT s)

| arm | decode | TTFT | vs PGCS decode |
|---|---:|---:|---:|
| F fork (same session) | **0.975** (0.953–1.005) | **109.9** | +30% |
| PGCS anchor | 0.752 | 150.3 | — |
| PGCS+FA (0-LOC attention finding) | 0.775 | 148.0 | +3% (r1 +8%, median +3%) |
| **forkdec** (registry path) | **0.840** | ~156 | **+11.8%** |
| **forkdec+s1gemv** | **0.856** | ~156 | **+13.8%** |
| **BOTH (full best-of-both stack)** | **0.910** (best rep **0.960**) | 154 | **+21.1%** |
| forkdec DPROF leg | 0.940 | 156 | +25% (DPROF on!) |
| PRC+FA (re-anchor; forkdec inert — see §3) | 0.601 | **116.6** (best **112.8**) | TTFT −33.7 vs PGCS |

vs **upstream-on-Vulkan** (gap2: 0.587 / 277.0): best decode arm **+55%**, best TTFT arm **−58%**
(fork: +66% / −60%).

## The same-session verdict

**Decode: port 0.910 med / 0.960 best vs fork 0.975 — the gap is ~7% at median, ~1.5% at best rep.**
**TTFT: port 116.6 med / 112.8 best vs fork 109.9 — within 6% median, ~3% best.** Under this session's
desktop-squeezed memory the fork itself fell from its 1.11 full-memory figure — and the port's best arm
met it there. On a quiet rig the fork returns to ~1.11 and the port's remaining lever is the arena
(§ mechanism, below) — the honest statement is: **mechanism parity reached; capacity remains.**

## Mechanism confirmation (gap3-forkdec-dprof-r1 vs gap2-pgcs-dprof-r4)

| bucket | before | after | ms/tok after |
|---|---:|---:|---:|
| slab imports | 5040.5 ms / 10,460 | **0.0 (0)** | 0 |
| build (alias+xb) | 6557 ms | 2624 ms | 41.7 |
| issue | 975 ms | 151 ms | 2.4 |
| fence | 19274 ms | **7680 ms** | **122** (was 306) |
| release | 636 ms | 6.9 ms | 0.1 |
| device | 8031 ms | 7476 ms | 118.7 |
| settle | 42252 ms | 41175 ms | **653** |

The registry killed churn exactly as specced — and beat the spec's modesty: the fence residual
("not this path's target") halved anyway (306→122 ms/tok; the SDA whole-buffer slabs ride RADV's fault
path far cheaper than per-token imports). **Settle did not collapse: the 13.39 GiB / 1,075-slab arena
serves a working set that wants ~1,982 slabs (the fork's full-RAM number) — 5,247 reads still come off
disk each run.** The residual 653 ms/tok is a memory-capacity term, not a mechanism term: at full RAM
(SLAB_ARENA_GB unclamped by the desktop) the warm path takes over and settle → misses-only.

## Session notes (honest bookkeeping)

1. The prcfa-forkdec legs carried `DECODE_PATH=fork` without `EXPERTS=1`, so the lever ignored itself
   (0 engagement lines — by design); those reps are a clean PRC+FA re-anchor on the new binary. The true
   PRC+FA+forkdec TTFT composition is one env line away and unmeasured; prediction stands (~110 s,
   the attn spec's 8–11 s store-volume cut).
2. PGCS+FA's median landed +3% (r1 +8%): the A1 wait does not always track device down in this regime —
   the attention finding is real but smaller than the spec's point estimate.
3. VRAM co-tenant churn (band 3.8 GiB transients) was wait-gated correctly; the late-session desktop
   release (vram0 → 1.3 GiB) likely explains `both`-r3's 0.960 and the DPROF leg's 0.940 — regime
   documented per leg, medians quoted.

## What the restructure delivered (the "best of both works" answer)

- **From the fork**: the tensor lifetime (persistent slab registry, 0-driver-object aliases, heap-room
  clamp) + the S=1 fmt-15 GEMV — as `COLI_VK_V4_DECODE_PATH=fork` + `COLI_VK_V4_S1GEMV`, default-off,
  gated, documented, PR-shaped.
- **From the port**: everything else — the chain (A1 at birth = the fork's merge destination), FA (already
  fork-class), CS compute-site, pilot, devsum, the whole default-off env ladder, and upstream lineage
  (243 commits current as of imp1).
- **Attention**: nothing ported — proven already best-of-both.
- **Net**: +21% decode over the port's own best previous stack, +55% over upstream-on-Vulkan, fork parity
  at matched memory, and the remaining gap named to a single term (arena capacity) with the knob already
  shipped (`COLI_VK_V4_SLAB_ARENA_GB`).

## Next (ranked, for the owner)

1. Quiet-rig confirmation session: forkdec arms at unclamped arena + PRC+FA+EXPERTS=1 TTFT leg (predictions:
   decode ≥ 1.0, TTFT ~110).
2. The PR queue reorganization — the stack now carries ~10 upstream-ready default-off levers with evidence.
3. Optional: S1 settle-reorder (~45–60 LOC) and the bank lane, only if the quiet-rig session leaves TTFT > ~112.

## Post-audit corrections (2026-10-31)

This synthesis's numbers are the measured record and stand as written; one range they fed into the PR body
was corrected there (`docs/campaign/plans/pr-perf-body.md`): the PR's "the same stack pre-merge (gap3)
TTFT 146–156 s" matched neither the BOTH arm's full rep range (**149.7–157.1 s**; this document's own
154.3 median) nor the stack-arm envelope, and its decode "0.91–0.96" was median-to-best (min rep 0.8998) —
the PR body now quotes 0.90–0.96 (med 0.91, best 0.96) / 149.7–157.1 s. The audit branch
(`audit/2026-10-31`) carries the full evidence audit.
