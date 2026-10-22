# Day-2 report: fork vs merged upstream, the gap analysis, and the MXFP4 grouped GEMM

**Date:** 2026-10-22 · **branch:** `port/up-2276` (tip `b8affcad`+) · nothing pushed.

## 1. The A/B (2,515-token prompt / 64 decode tokens, 28 GiB budget, interleaved)

| arm | TTFT s | decode tok/s | wall s |
|---|---:|---:|---:|
| **fork** (`colibri-ds4-vulkan` @ port-source, ×2) | **104.2 / 107.1** | **1.094 / 1.144** | **161.8 / 162.2** |
| merged tree, defaults | 251.9 / 255.3 | 0.603 / 0.636 | 356.4 / 354.3 |
| merged + `COLI_VK_CHAIN_GEMM_ROWS=-1` (×3, two days) | 232.5–238.8 | 0.598–0.602 | 337.9–344.3 |
| merged + chain GEMM + **MXFP4 GEMM** | 238.6 | 0.601 | 343.4 |
| merged + chain GEMM + 8 GiB host pool | 254.7 | **0.624** | 355.6 |
| merged + chain GEMM + `TIER_GEMM_ROWS=1` (everything streams) | 313.2 | 0.544 | 429.0 |
| …same without the MXFP4 GEMM | 327.7 | 0.546 | 443.0 |

Drift between same-config arms is ≤ 6 s TTFT / ≤ 0.04 tok/s.

**The gap:** the fork leads TTFT by 2.2× and decode by 1.8× at this operating point.

## 2. Where the time goes (the engines' own tier/chain reports)

The merged tree's routed-expert accounting for the default arm:

```
device 6248.7 ms, CPU share 141219.3 ms, waited 2519.3 ms
stream: 172 steps, 8800 cold experts (147.96 GiB, 8.33 GB/s), 348853 rows streamed,
        16703 cold experts (90807 rows) KEPT ON THE CPU
```

- The device computes almost nothing of the routed experts' time budget: **~141 s is
  host-side expert compute**, and it is almost entirely the **≤16-row long tail** the
  tier's stream rule keeps on the CPU (an expert's 15 MiB upload amortizes at ~16 rows
  of CPU compute — `COLI_VK_TIER_GEMM_ROWS=16`).
- Forcing everything to stream (`GEMM_ROWS=1`) proves both halves: the CPU share
  collapses to 3 s, but **697 GiB** stream at 8.75 GB/s (~80 s of pure uploads, the
  64 stream slots churn on 1-row experts) — net 75 s worse.
- An 8 GiB host pool (544 experts, plan-override) buys decode (+4 %) but does not move
  the tail: the hybrid computes only ≤2-row pooled pairs in place; the stream rule,
  not pool residency, decides the tail.

The fork's lines tell what it does instead:

```
v4_gpu moe-ram=on ring=3.19 GiB qd=16 take=par
v4_gpu moe-batch=on bank=256-experts
v4_gpu v5-cache: post-prefill refill target=247 ... installed=247 ... mfu=...
```

## 3. What is actually missing (the merge list, ranked by measured leverage)

1. **The expert-major bank (P4.1) — the one big prefill piece upstream lacks.** The
   fork gathers every routed expert's rows across a step, uploads each expert ONCE
   into a 256-expert per-layer VRAM bank, and computes them weight-stationary. That
   is exactly the ≤16-row tail's problem: upstream's 64 stream slots churn on small
   experts, and its pool-copy slots (c55cb4be) hold only a few. Measured headroom:
   ~90–140 s of the ~230 s TTFT. This is the top candidate for the next port — as an
   extension of upstream's slot machinery, not the fork's bank stack.
2. **Popularity-based decode residency (the fork's MFU/v5-cache).** Upstream's
   promote (#2258) moves pooled experts up only when the pool holds *every* expert —
   a 167 GB model never qualifies on this host, so decode rides the warm-start LFRU
   set only. A partial-pool promote (their own mechanism, relaxed) is the
   upstreamable slice; the fork's decode lead (1.09 vs 0.60) is mostly this plus (3).
3. **The host-RAM ring + PCIe-activation overlap (P3.5's pass).** The fork overlaps
   next-layer expert loads with compute (`ring=3.19 GiB, take=par`); upstream's
   prefetch (`prefetched 8202 (6911 used)`) covers part of it.
4. **mm8 split/ping-pong projections (P3.1's decode side)** — upstream's tiled GEMM
   now covers prompt rows (PR #2253); decode keeps the GEMV's bits, and the fork's
   mm8 decode-side win is still unported.

Superseded by upstream (do not port): P2.2 async PILOT, P3.4 idxsel, P4.2 ring (the
pool is the host-RAM layer), P4.3 submit merges.

## 4. The MXFP4 grouped GEMM (the pf4-GEMM merge, done)

**What landed:** `qmatmul_grp_mx.comp` (+ GATE_UP variant) — mode 4 in the expert
batch. One dispatch covers every fmt 7 expert of a big step: the GGUF kernel's
proven shape (32 rows × 64 outputs a workgroup, weights decoded once into shared
memory, float arithmetic, **no matrix units, any subgroup size**) with the grouped
GEMV's MXFP4 decode (e2m1 nibbles, one float scale a 32-input group). It rides all
of upstream's batch machinery (items, expert table, amap sub-batches, slots);
`COLI_VK_XB_GROUPED_MX=0` restores the old routes.

**Why this shape and not the fork's pf4 kernels verbatim:** the fork's family is
built on its own tensor layout (packed UE8M0 scales, PCPf4 push constants, per-
expert dispatch against the GPU-FOLD stack). Upstream's tier tensors (float scales,
its expert table) and batch machinery are the seam the port plan fixes
(§2: capabilities into seams). The fork's *measured capability* — a tiled
weight-stationary MXFP4 GEMM on RDNA2 — is what this re-expresses.

**Bug found by the new test case, worth remembering:** the recorder's item
`it.z` encoding differs by mode (block index for the GEMMs, first output for the
GEMV). Mode 4 initially fell into the GEMV branch, so every output block after the
first read and wrote past its matrix — the case caught it at 1.4e+00, the fix is
one host line, and the case now holds at **3.8e-07** worst relative error.

**Measured effect (honest):** at the default stream threshold the big fmt 7 steps
were served by the tier's per-expert GEMM route, which turns out to be efficient —
device time at `GEMM_ROWS=1` is 25.12 s with or without the MX kernel. The win at
that routing is dispatch consolidation (429.0 vs 443.0 s wall, ~3 %). The kernel's
real value: (a) fmt 7 finally has a grouped route — every native-MXFP4 engine
(kimi_k3, mimo, deepseek_v4.1, qwen38 GGUF-side) on a non-cooperative-matrix
device gets it; (b) the dispatch reduction matters more on smaller/contended
queues; (c) it is the foundation the bank (§3.1) would compute through.

**Gates:** `vk-tier-check` PASS (with the new MXFP4 grouped case),
`vk-chain-check` PASS, `vk-strict-check` PASS, `cu_tier.c -DCOLI_CUDA
-fsyntax-only` clean (the tier's second compile). The MX test case runs the single
mode only — no streaming env — so the tier's pool history stays as the cases
before it left it (`extra`'s eviction scenario is marginal to it; documented in
the test).

## 5. Recommended next moves

1. **The bank port** (§3.1) as an extension of the stream-slot machinery — the one
   slice that can close most of the 2.2× TTFT gap. Design sketch: gather rows per
   expert at issue, a per-layer VRAM window of N experts with LRU across the
   conversation (the fork's numbers: −2.2 s @11 rows → −708 s @4093 rows).
2. **Partial-pool promote** (§3.2) for decode — extend upstream's #2258 mechanism
   below the `fit >= all` condition, rate-limited as theirs is.
3. Send the #2253 follow-up (the bare `make deepseek_v4` fix) — the maintainer's
   one note, root-caused and fixed on this branch.
4. The MX GEMM can ride to upstream behind the tier-host-pool PR or standalone
   (self-contained: one shader pair + one mode in the batch; kimi/mimo/v41
   deployments on Intel/RADV benefit immediately).

## 6. Addendum (later that day): the partial-pool promote — landed and measured

The decode residency slice is in: **promotions from a partial host pool**
(`COLI_VK_TIER_PROMOTE=n`, opt-in where the pool is short of every expert —
the fork's MFU popularity ladder on upstream's own #2258 machinery: the pool
holds the heat-ordered next-hot tail, routed pooled experts move up by their
own pool copy, the coldest resident gives way — freed to the RAM cache when
it has no pool copy, the promoted expert keeps its pool entry so a later
eviction swaps back at no copy). `test_vk_tier`'s `promote2` holds it
(ups 2 at 2.9e-07; the default promotes nothing).

Measured (same rig, real model):

| arm | TTFT | decode |
|---|---:|---:|
| merged + chain GEMM | 232.5–238.8 | 0.598–0.602 |
| merged + chain GEMM + 8 GiB pool | 254.7 | 0.624 |
| **merged + chain GEMM + 8 GiB pool + PROMOTE=32** | **246.5** | **0.654** |
| fork | 104–107 | 1.09–1.14 |

Decode +8.5 % over no-pool, +5 % over the pool alone, 22 promotions over the
run. The gap to the fork's decode remains ~1.7×: the profile says our decode
spends ~1.6 s/token waiting on the device (760 matmuls/token, f32-GEMV
class) — the fork's mm8 int8-activation projections (4.73× on that class)
are the next decode slice, a parity-class change that needs the F8 envelope
language.

The threshold sweep's negative result is also recorded (gr16/gr4/gr1:
238/278/313 s TTFT): the stream path's per-expert upload economy (15 MiB
regardless of rows) and step serialization cap it — the bank (§3.1) with
cross-segment retention and overlapped uploads is the remaining prefill
slice, next session's build.

## 7. Second addendum: the slot-churn finding — the bank, mostly already there

The gr4 mystery is solved, and the fix is a knob, not a build: **slot churn**.
DeepSeek V4 Flash routes ~220 distinct experts a layer's 768-row segment; the
64-slot staging default re-streams every expert each sub-batch that wants it.
Widening the slots IS the fork's bank within upstream's machinery (the slots
are the per-segment expert window; the prefetcher already overlaps loads):

| config | TTFT | decode | streamed | kept rows (CPU) |
|---|---:|---:|---|---:|
| chain GEMM (default slots/threshold) | 232.5–238.8 | 0.598–0.602 | 148 GiB | 90,807 |
| + `STREAM_SLOTS=192 GEMM_ROWS=4` | 219.4 | 0.538 | 199 GiB | 5,218 |
| + `STREAM_SLOTS=256 GEMM_ROWS=4` | **194.9** | 0.528 | — | — |
| + `HOST_GB=8 PROMOTE=32` (28 GiB) | 246.5 | **0.654** | — | — |
| **all: 24 GiB plan + pool 5 + slots 192 + gr4 + promote + chain GEMM** | **201.3** | **0.583** | — | — |

The host's routed-expert compute fell 146 s → 56 s and the small-expert tail
91k rows → 5k. The all-in arm needs the budget rebalanced (the slots' host
staging is ~15 MiB a slot beside the plan: 28+8 GiB OOMs a 34 GiB cgroup;
24+5 fits) — the plan cap's warning line is doing its job there.

**Campaign totals (upstream default → our best/balanced):** TTFT 266 → 194.9
(best) / 201.3 (balanced, wall 309.4 from 370); decode 0.603 → 0.654. The fork
reference stands at 104–107 / 1.09–1.14 — the remaining ~1.9× on both sides
is the fork's whole-stack device residency (ring + GPU-FOLD) and its mm8
int8-activation projections; both need their own sessions (the ring is an
overlap build on the stream path; mm8 is parity-class, F8 language first).

`COLI_VK_TIER_STREAM_SLOTS`'s ENVIRONMENT row carries the finding and the
measured numbers.

## 8. Close-out: the sweep has converged

`GEMM_ROWS=2` at 256 slots: 196.0 / 0.547 / 311.1 — inside noise of gr4
(194.9). The tail is exhausted (1,664 single-row experts remain on the CPU,
57 s host share, 14.5 s device): the expert side of prefill is done. The
~195 s TTFT floor is now the rest of prefill — dense chain frames, loads and
staging on the engine thread, attention/indexer — which is the ring/overlap
build's territory, not the tier's.

## 9. Third addendum: the two remaining cheap hypotheses, tested — both negative

**Speculative decoding** (upstream's verify-row sharing made it worth testing):
- n-gram drafter (`V4_DRAFT=4`): 194.4 / 0.533 — no drafts fired (the bench's
  continuation has no prompt n-grams; `target_only=1`).
- the Flash's MTP head (`V4_MTP=1 V4_DRAFT=4`): 201.8 / 0.506 —
  `attempts=1 drafted=3 accepted=0`, the adaptive drafter shut down.
- Fairness: the fork's reference arms are also `target_only=1` — the 1.9× gap
  never included drafting. Spec decode may still pay on long generations or
  with the DSpark-supplement checkpoint; on this bench it is a wash.

**Bigger prompt chunks** (`COLI_VK_CHAIN_ROWS=1536`): TTFT 927.7 s —
catastrophic on this 16 GiB card (the chunk's activations and the giant
stream steps thrash; the CPU row cost measure doubled under load). 768
stands.

**Where this leaves prefill:** the remaining ~90 s of host-side MoE wall
(loads on the engine thread, staging, join bubbles) over an irreducible
~70+ s of NVMe (29.4k expert reads ≈ 435 GiB) is the loader-thread build:
move `st_fill_group`'s `T.c.load_batch` off the engine thread onto the
existing uploader with a deeper queue, and let the prefetcher hold a
two-layer slot window (the fork's ring equivalent). Design constraints:
the `SS_*` slot states and the two-half sub-batch pipeline are the
synchronization points; `COLI_VK_TIER_SYNC=1` must keep its
deterministic-drain contract (the tests rely on it). Expected ceiling:
TTFT ~195 → ~150 s (NVMe-bound), not the fork's 104 (its GPU-FOLD kept
the whole MoE device-side, an architecture we chose not to port).

## 10. The GPU-FOLD attribution series (2026-10-22, final)

Six interleaved arms, two reps each of the three decisive configs:

| arm | TTFT | decode | wall |
|---|---:|---:|---:|
| fork, full GPU-FOLD (dense + experts) | 107.8 / 104.4 | 1.162 / 1.155 | 162.0 / 158.9 |
| **fork, expert fold OFF** (`DSV4_VK_EXPERTS=0`) | **104.1 / 104.2** | **0.630 / 0.610** | 204.2 / 207.5 |
| new fork (`s256-gr4`) | 202.0 / 202.4 | 0.515 / 0.520 | 324.3 / 323.7 |

**The answer to "is GPU-FOLD the difference": it is HALF the difference, and
not the half we assumed.**

1. **The expert fold (the v5-cache/GPU-expert stack) contributes ~nothing to
   the fork's TTFT** (104 with it, 104 without) and **1.84× to decode**
   (0.62 → 1.16). The decode work we ported (partial-pool promote + pool)
   already sits at the fold-free fork's level (0.654 vs 0.61-0.63); the rest
   of the decode gap is exactly this fold's device-resident hot set.
2. **The TTFT gap (104 vs 202) is NOT the expert fold.** It decomposes into:
   - **~60 s of expert BYTE economy**: the fold-free fork reads **68 GiB**
     from disk for the same prompt (store: 16,254 requests, 68.5% hits,
     5,113 misses) where the new fork reads **~435 GiB** (29.4k loads, 25%
     hits). Same 25.7 GiB cache both sides, same autopin history loaded —
     the fork's ExpertCache/slot-pool retention keeps the working set; our
     LRU thrashes on the cyclic segment access (13,158-expert working set).
     This is a retention-policy port, not a bandwidth problem, and it is
     cheaper than the ring with a bigger ceiling than we thought (~60 s).
   - **~38 s dense-side**: the fork's dense fold kernels (mm8-class
     projections, wo_b, activation placement) + MoE orchestration, on top of
     the loader-thread ring's join bubbles.
3. Both forks and the new fork ran target-only (no drafting) — every
   comparison in this campaign is draft-free.

**Revised next-session ranking:** (1) the expert-store retention policy
(the ~60 s, engine-side, no shaders), (2) the loader-thread ring (~15-25 s,
threading), (3) mm8 decode projections (the fold's decode half, parity
language first).

## 11. The window sweep and the ring: both falsified — the cell pipeline is what's left

Two structural hypotheses tested to destruction:

**The MoE window size** (the chain's per-forward row window, `v4c_rows()` —
capped at 128 when `COLI_VK_CHAIN_ROWS` is set, otherwise the whole auto-fit
chunk):

| window (rows) | sweeps | TTFT | store requests |
|---:|---:|---:|---:|
| 128 (CHAIN_ROWS set) | 20 | 583–928 | 116,296 |
| **768 (the default fit)** | 4 | **195–202** | 30,932 |
| 2516 (TIER_GB=5, one chunk) | 1 | **982** | — |

The default is a broad optimum. One sweep is catastophic: the tier's slot
groups and the chain's window-ring growth thrash at that width. The fork's
104 s is not window sizing — its cell pipeline (the dense fold's cell-wise
prefill: P3.5's wo_b/activation pass and P4.3's cell machinery we measured
"neutral" in the fork's own frame) processes rows in cells with its own
rings, and that architecture is what reads 68 GiB where every windowed
layout reads 230-435.

**The host-RAM stream ring** (implemented, gated, passing — then reverted):
heat-ranked retention of streamed experts in front of the store. At any
viable capacity (~3 GiB = 240 experts) it measured **0 hits**: the reuse
distance of a layer's set is 43 layers × ~221 experts ≈ 9,500 experts —
no capacity short of the model itself spans it, and per-layer partitioning
divides capacity by 43. The ring's copies only added overhead (314 s vs
202). Reverted rather than shipped dead.

**Conclusion:** the remaining prefill gap is the fork's cell-pipeline
dense-fold architecture (P3.5/P4.3 as a structure, not as knobs). That is
the one port left, it is large, and it competes with simply upstreaming
what already works: everything else in this campaign.
