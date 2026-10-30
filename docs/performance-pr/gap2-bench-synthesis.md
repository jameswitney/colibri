# gap2 bench synthesis — uplift vs upstream-on-Vulkan and the fork, attribution, best arms

Date: 2026-10-28/29. Session logs: `/root/bench-colibri/up2276/gap2-*` (window log = the run record).
Protocol: `run-arm2276.sh`, model DeepSeek-V4-Flash, prompt 2,515 tok, 64 tokens, ×3 interleaved, md5/text
checks green, VRAM co-tenant guard + stability band throughout. Binaries: U=upstream/dev `c1c06ac6`,
F=fork `d11fba5b`, P=`port/imp2-stack` `7e551c75`, L=`port/imp2-lanes` `e2038194`.

**Session memory regimes (owner-mandated desktop tolerance; both re-gates recorded in the window log):**
- Old: RAM_GB=24, host pool 4 GiB, tier 5.26 GiB (VRAM co-tenant 3.16 GiB) — anchors r1–r3.
- New: RAM_GB=16, host pool 2 GiB, tier 6.51 GiB, cgroup 24G — everything r4+.
Cross-regime absolutes are confounded by design; all lever deltas are within-regime.

## 1. The uplift table (decode tok/s med / TTFT s med)

| arm | decode | TTFT | vs U-VK decode | vs U-VK TTFT |
|---|---:|---:|---:|---:|
| **U-VK upstream as-shipped** (n4) | **0.587** | **277.0** | — | — |
| **F fork** (n4) | **1.096** | **107.9** | **+87%** | **−61%** |
| P0 port standing (new regime) | 0.518 | 153.6 | −12% | −45% |
| **PGCS port best-decode** (old regime r1–2) | **0.823** | 149.1 | **+40%** | −46% |
| PGCS (new regime r4–5) | 0.753 | 152.3 | +28% | −45% |
| PRC ring-cold (n3) | 0.539 | 140.3 | −8% | −49% |
| **PRC+FA port best-TTFT** (n3) | 0.526 | **121.7** | −10% | **−56%** |

Headline: **the port carries a +28–40% decode and −45–56% TTFT uplift over upstream-on-Vulkan**, and the
fork demonstrates the ceiling (+87% / −61%). Port-without-levers (P0) ≈ upstream parity — the uplift is
entirely the campaign's levers, none of which upstream has.

## 2. Wave-2 lever scoreboard (new regime, vs PGCS anchor 0.753; predictions scored)

| lever | decode | verdict vs prediction |
|---|---:|---|
| CS_ALIAS_CACHE+SKIP (n3) | 0.460 | **REGRESSION −39%.** Churn-reduction works (build 6.56→2.85 s/run, release 0.64→0.03; alias hit 80ms vs miss 2,072ms) but the 4 GiB/321-entry cache thrashes at this shape (3,877 hits / 6,583 misses / 6,262 evictions) and the issue span explodes 0.98→19.18 s — cached entries ride a slow path. Falsified: caches the import, not the read |
| CS_DEVSUM (n2) | 0.733 | −2.7% vs anchor; predicted −35..−60 ms/tok gain → MISS (tail dispatch ≥ saved merge at this shape) |
| PILOT (n2) | 0.740 | −1.8%; predicted −150..−450 if read-settle owns window → read-settle DOES own it (see §3) yet pilot is neutral → **the re-read is bandwidth-bound, not latency-bound** — issuing earlier cannot buy bytes |
| ATTN_CELL+MHC_S1 (n2) | 0.749 | −0.6% ≈ neutral; predicted −5..−15 → MISS (A1 residual was already only 4.5 ms/tok) |
| SLOTS=64 (n2) | 0.696 / TTFT 230 | MISS of the 0.81–0.84 band: shrunken tier leaves nothing to reallocate; staging starves (+78 s TTFT) |
| SLOTS=2 diagnostic (n1) | **0.774** / TTFT 391 | **Best decode of the session (+2.8%)** — the residency mechanism CONFIRMED, at brutal prefill cost |
| TIER_QUEUE=0 (n2) | 0.719 | −4.5%: the own queue earns its keep |
| ALL-ARMED (n2) | 0.524 | −30% ≈ exactly the cache drag — stack arithmetic consistent |
| CS+LANES (n2) | 0.708 | −6%: does not stack under CS in this regime |

TTFT stack (new regime): PRC 140.3 → **+FA 121.7** (−18.6 s, the FA prediction 104–115 landed 121.7 —
direction right, regime toll) → +ROWS_ADAPTIVE 134–137 (MISS in this regime; its ~97 s prediction was
calibrated for full RAM) → full stack 127.8–130.5. **PRC+FA alone is the TTFT optimum.**

## 3. Where the remaining fork-gap lives — the discriminator verdict (gap2-pgcs-dprof-r4)

CS window 790.4 ms/tok = **settle 670.7 (84.8%)** + build 104.1 + issue 15.5. The settle is
**10,460 loader reads/run = 130.24 GiB = 2.07 GiB/token re-read into the store** (5,171 RAM-hit + 5,289
disk at ~3.1 GB/s). Import churn is real but small: 10,460 imports × 0.48 ms ≈ 80 ms/tok (0 dedup hits),
destroys ≈ 20. Fence 306 vs device 127.5 leaves a ~178 ms/tok residual (queue/latency class — the
queue0 arm says it is not the second queue). **Wave-1's central conflict is settled: the store re-read
hypothesis (inventory lane) wins; the churn hypothesis (joinwait lane) is excluded.** The fork avoids the
re-read structurally: its 24.7 GiB RAM arena (1,982 slots) makes a warm expert a handle lookup. The port,
squeezed to a 6.5 GiB tier + 2 GiB host pool by the desktop co-tenant, moves the bytes every token.
SLOTS=2 buying +2.8% decode with residents↑ is the mechanism's direct confirmation.

## 4. Best performance

- **Best decode:** PGCS **0.823** (0.804–0.827 across sessions at full memory); this session's constrained
  best 0.753 (PGCS) / 0.774 (slots2 diagnostic). Fork: 1.10.
- **Best TTFT:** **PRC+FA 121.7 s** (best rep 119.4; prior port best 145.9). Fork: 107.9.
- **Best balanced:** PGCS-class for decode-dominated use; PRC+FA for TTFT-dominated. No single arm wins both
  (the ring trades ~0.21 tok/s for ~30 s TTFT).

## 5. The path to fork parity (now precisely known)

Cut the 2.07 GiB/token store re-read by keeping expert bytes warm across tokens: a fork-class RAM arena /
persistent store slabs / larger resident tier. It is a memory-lifetime lever, not a scheduling lever —
pilot (latency), cache (import lifetime), devsum (tail), cell (submit structure) all measured ≈ neutral
because none of them touch byte volume. On a quiet rig (RAM_GB=24+), the same PGCS arm already measures
0.804–0.827; the arena lever is the candidate to close the rest.

## Session incident record

Stage-A worker timeout (matrix survived on disk; orphan driver shepherded to completion), two memory
re-gates per owner instruction (VRAM 2600→3584 after desktop grew to 3.16 GiB; RAM 24→16 after host hit
37/38 GiB), 2 legs lost to the RAM squeeze (pgcs-r3, pgcs-dprof-r1 — re-run clean), slots64/ROWS arms'
misses attributable to the constrained regime, all gates green on all four binaries, no pushes beyond
Gitea, fork checkout untouched.
