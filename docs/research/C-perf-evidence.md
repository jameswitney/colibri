# C — Measured performance evidence ledger (colibri-ds4-vulkan → upstream port)

Scope: every number below was produced by this fork and is traceable to a dated
doc, commit message, or result table. No benchmark was re-run for this ledger.
Box unless stated: RX 6900 XT 16 GiB (RADV gfx1030), 18–24 host threads, NVMe,
DeepSeek-V4-Flash-0731, greedy, `KVSAVE=0`. Retained result dirs are gitignored;
evidence is the commit/doc tables named in the last column. Effect sizes are
point estimates from the cited arms; noise bands are stated where the source
stated them.

## 1. Baseline: CPU-only vs VK, and the prefill/decode split

| date | arm / operating point | CPU-only | VK tier | note |
|---|---|---|---|---|
| 2026-08-28 | serve, cpuset 0-7/OMP8, 16 g, 512-tok prefill | 1.022 tok/s, TTFT 25.96 s, prefill 230.4 s | 1.582 tok/s (M3a–M3e-pre); 2.301 after the WC-read fix | first real tier win; `docs/archive/reviews/audit-2026-08-28.md` §5 |
| 2026-08-29 | 4-arm same-session, 12 GiB budget | 1.012 tok/s, prefill 225.4 s, TTFT 26.6 s | dense-only 1.248 tok/s / 140.9 s; +D7 drop 2.032 tok/s / 111.7 s | `audit-m43-2026-08-29.md` |
| 2026-08-30 | agentic prompts, 64/128 tok, vs upstream v1.9.0 | 0.32–0.34 tok/s | vk-dense 1.70–1.89×; vk-exp 2.34–2.74× decode, 1.95–2.34× end-to-end | `audit-longbench-2026-08-30.md` |
| 2026-09-29 | 2010-tok cold CLI, 64 tok | — | 0.853–0.864 tok/s (≈1.17 s/token) | `decode-profile-2026-09-29.md` |
| 2026-10-05 | same box | — | 1.27 tok/s; **47 % decode-window disk-busy, GPU 3–4 %** | `dwarfstar4-decode-comparison-2026-10-05.md` |
| 2026-10-16 | warm `.coli_mfu` pool, 10-token answer | — | 3.0 tok/s decode, TTFT 34.1 s | commit `0f1b06d2` |

**Split.** Prefill is expert-streaming-bound at short/medium length (MoE =
87–89 % of the whole turn, 2026-09-18, `PROGRESS_GPU_PREFILL.md`), and
compute/host-bound at ≥32k (28.0 ms/token flat 32k→64k, `79faf627`). Decode is
disk+host-glue-bound: at 2010 tok the 1095 ms/token wall decomposes to GPU
132–175, disk 440–451, CPU indexer 22–43, host glue/launch/sync ≈430 ms
(2026-10-02 review). GPU is idle 85–88 % of decode; the drive is ~40 % busy at
~1.3 GB/s of ~6 GB/s. Consequence: kernel work is not the decode lever; hit
rate, host serialization and submit structure are.

## 2. Evidence table by subsystem

| feature | claim | operating point | method | effect size | verdict | evidence |
|---|---|---|---|---|---|---|
| Dense fp8 GPU tier (M3) | GPU dense beats CPU dense | 512-tok prefill, 12 GiB | 3 arms, same session, 2 reps | prefill 225.4→140.9 s (−37.5 %), TTFT −12 % | KEEP | `audit-m43-2026-08-29.md` |
| D7 dense-RAM drop | freed RAM → expert cache | same | held vs cleared arm | decode +63 % (1.248→2.032), prefill −20.7 % | KEEP | same |
| Full tier vs upstream | end-to-end speedup | agentic 64/128 tok | 38 runs, 11 prompts, same session | 1.95–2.34× wall; decode 2.34–2.74× | KEEP | `audit-longbench-2026-08-30.md` |
| Decode attention cell (1 submit/layer-token) | fewer submits help | 1k code, 64 tok | ABBA 4+2 order-controlled pairs | +4.12 % decode (6/6 pairs) | KEEP | `d87233f7`, CHANGELOG |
| mHC decode fusion (pre/post) | device mHC beats host loop | default stack | bench, parity at batch gate | +19 % decode (1.17→1.40 tok/s); mHC 3.67→0.47 ms/call from the WC-read cache fix | KEEP | `59ae2f90`, audit-2026-08-28 §5.2 |
| Warm-pool lane compute | pool hits should compute on lanes | real ckpt, warm `.coli_mfu`, 10 tok | A/B | decode 2.05→3.0 tok/s (−32 % wall); pool warm 12.0→9.4 s | KEEP | `0f1b06d2` |
| Prefill expert bank (GPU) vs CPU union | bank wins all lengths | 11→4093 tok | bank on/off, engagement verified | prefill-only −2.2 s @11 tok → −708 s @4093; whole request loses only ≤~20 tok | KEEP | REVIEW G18, `0b5eed9a` |
| Bank gate 256→1 | 20–256 tok band was on CPU | same | same | default change; CPU union only on VRAM refusal | KEEP | G18 |
| Host-RAM prefetch ring | background ring hides layer refill | 512→8808 tok | 2-arm, 3 reps @4.1k, 1 rep @8.8k | −9.6 % @4.1k, −5.3 % @8.8k, −19…−23 % @0.5–1.6k; +7 % bytes @4.1k | KEEP | REVIEW 2026-09-06/07 |
| Parallel ring→bank take (P2) | upload loop is short-prompt cost | 1k/2k/8k/32k | interleaved, 2 reps | −23.8 % @1k, −9.8 % @2k, −3.4 % @8k, −0.9 % @32k | KEEP | `cf256f8e`, PLAN_prefill_p2 §9 |
| Deeper read QD (P1) | deeper queue helps prefill | 1k/32k/64k | A/B | −7.6 % @1k, **+1.7 % @32k**, −1.0 % @64k | DROP (≤4k only) | PLAN_prefill_p2 §8 |
| mm8 tiled projection GEMM (#46) | token-major GEMM re-reads weights | S=128, 2010/4016 | bitwise L2 + ts profile | projections 87.1→18.4 ms/cell (4.73×); **~6.8 % end-to-end** | KEEP | `232c3d5d`, `fd280903`, PROGRESS_GPU_PREFILL |
| pf4 expert GEMM + expert-major bank | prefill routed leg is issue-bound | H4096 I2048 top-6, 128 tok | bench + in-engine | 335→114 ms/cell (2.94×); session 491→1302 GMAC/s (2.65×) | KEEP | `08f57152`, `acf85993`, `95626486` |
| Activation placement + KV-ring-on-device + split-K | buffers were in system RAM | 32k–256k | ts prof, 1 rep/length | wo_b 3338→1508 µs (−55 %), segment 14.2→9.0 ms, gpu_ms −14 %; 32k 884.6 s (35.89 tok/s), 64k 1774.7 s, 256k 8140.6 s | KEEP | `79faf627` |
| mHC device residency (prefill) | residual streams cross PCIe per op | 32k, 10707 cells | ABBA | slice 21.5→7.7 ms/cell; TTFT 1288→1216 s (−5.5 %) | KEEP | `ccd9d05f` |
| Flash-attention kernel | sparse attention tile was 128× KV amplification | 2k/3k/8k | bench + engine | cell 5.0× @2k, 16.7× @8k (749→45 ms); decode 2.1× @3k, 2.4× @8k | KEEP | `8a1ef885` |
| idxscore LDS tiling | score kernel was gather-bound | 8k, real shape | gate off/on + engine arm | kernel 11.2–15.5×; indexer 26.1→6.2 ms/cell (4.2×); TTFT 412.5→398.2 s | KEEP | `bdca30f4` |
| idxsel v2 (collect + bitonic) | phase-2 rank loop was the long-context slope | 33k play+quiz | 2 clean runs, identical command | TTFT 991.1→898.3 s (−9.4 %), qb/cell 21.9→25.1 ms flat; 128k −25 % projected (unmeasured) | KEEP | `2266299d`, PLAN_idx_v2 |
| GPU indexer scoring by default | per-call cost, not residency, gated it | 2k code, 64 tok | forced-GPU A/B | 0.92→0.933 tok/s (+1.4 %), indexer CPU 43→22 ms/token | KEEP | `decode-profile-2026-09-29.md` |
| GPU-MFU fill-to-free + ÷4 decay | boot left VRAM idle | code-lru, 64 tok | harness, reproduced 2× | decode 0.70–0.73→0.93–0.95 tok/s (+33 %), GPU hits 29→43 % | KEEP | `PROGRESS_gpu_mfu_sizing.md` T6 |
| v6 spanning cache (dual residency) | shed/refill cycle costs a rebuild | 5-turn coding, 48 tok/turn | server A/B, two worktrees | decode +4.3 % mean, +6.4 % turn-2+; TTFT −3.0 %; wall −0.8 % | CONDITIONAL (loses the prefill bank) | PLAN_cache_span §3, `28555d42` |
| MFU/MRU split direction fix | demand misses evicted the wrong tier | 50 prompts, 1681 slots | 3 arms, same warm table | adapt 1.20 vs freq 1.09 vs rec 1.08 tok/s; hit 75.0/70.3/72.8 % | KEEP | `d11fba5b` |
| Decode MoE demand lanes | top-k misses were serialized | 982-tok code | 2×2 interleaved, md5 ×4 | after_first 69.2–71.9→55.3–57.1 s; decode 0.92→1.10–1.19 tok/s (+23 %) | KEEP | REVIEW G15 |
| Async PILOT | synchronous pilot blocks the decode thread | same | 2×2 interleaved, byte-identical | blocking 4.27→2.77 s (−35 %); **wall +0.4 % (noise)** | CONDITIONAL (T5 substrate) | REVIEW G14 |
| T5 next-token PILOT | earlier issue → shorter waits | same | 2×2 interleaved, md5 ×4 | waits 2.45→0.03 s, wall unchanged (60.7/59.3 vs 60.6/58.3) | DROP | REVIEW G16 |
| Per-device NVMe queues | queue depth/priority per drive | real O_DIRECT + simulator | `moe_lane_sim.py`, ±5 % | devq/policy 6.33–6.39 ms vs fifo noise; lanes alone 12.8–14.5→6.3–8.6 ms | DROP | REVIEW G17, PLAN_device_queues |
| Cell-tail merge (mHC tail) | fewer fences per cell | 1.2k, 344 cells | 2×2 + 6 tracer runs, bitwise | submits 4511→4167 (−1/cell); TTFT 74.98→74.25 s (noise) | CONDITIONAL (correctness substrate) | PLAN_submit_merge §10e |
| Cell-join queue-ahead | overlap host staging with segment | 4k | same-session A/B | wall neutral (attn 54.5→29.2 s, hc2 2.6→27.4 s; wait conserved) | CONDITIONAL | PLAN_submit_merge §11 |
| mHC edge folds (dec2-mhc, SHARED_DEFER, COMP_FOLD_DEC) | folding cadence ops into a submit | 1k–8k | ABBA 3–6 pairs | **−10.5 %**, **−4.6 %**, **−2.1 %** (5/6 negative) | DROP | `4edbf82d`, CHANGELOG, `d4c504c7` |
| COMP_RESIDENT / FFN_TAIL / MHC_PREFUSED | fold removes host work | 2k/8k, 64 tok | 2×2 interleaved | washes: 1.229/1.205 vs 1.221/1.258; 1.195 vs 1.16 tok/s; −0.11…+0.37 % | DROP (code kept as substrate) | `df926ee0`, `344969ec`, `470ac196` |
| Cold KV tier (disk as record) | RAM slots cap lineages and thrash | interleaved agents, 66 new tokens | functional E2E + measured cost model | miss = **677 s** re-prefill; restore 25–80 ms, write 70–250 ms; catalog 4 B/token; cap 4 agents removed | CONDITIONAL (no end-to-end wall A/B) | `19764dd0`, PLAN_kv_cold, REVIEW 2026-10-16 |
| Reactive prefill segment fit + OOM recovery | overcommit let the kernel OOM-kill the host | 128k on a 38.9 GiB box | post-mortem, then forced 33k/9 segments | eliminated 2 host OOM kills; no tok/s claim | KEEP (robustness) | `cfd775f2`, REVIEW 2026-10-12 |
| Prompt-sized VRAM admission + reserve floor | flat 1 GiB need parked the tier on the threshold | live serve | 200/503 before/after | permanent 503 wedge fixed; tier ~14 % smaller | KEEP (availability) | `c3298ec5`, `e834da31` |
| PSI-driven elastic CPU RAM | shed cold slabs under co-tenant pressure | — | none (design only; no PSI code in tree) | **UNPROVEN — no measurement exists** | DROP (defer) | PLAN_ram_elastic (status: draft) |
| Device-only fp16 KV | fp16 halves KV, frees RAM | — | capacity arithmetic only | **UNPROVEN — ~6.9 KB/token is a model, no run** | DROP (defer) | PLAN_gpu_fp16 |
| GPU activation QDQ | GPU can match the CPU quant chain | L1 oracle, 10 cases | bitwise vs `coli_fp8_activation_qdq_ref` | exact 10/10; no performance claim | KEEP (correctness) | REVIEW G9 |

## 3. Claims that must not drive porting

- **Cadence-op folds inside an already-recorded submit are negative or neutral**
  on this box: dec2-mhc −10.5 %, SHARED_DEFER −4.6 %, COMP_FOLD_DEC −2.1 %,
  COMP_RESIDENT/FFN_TAIL/MHC_PREFUSED washes, cell-tail and queue-ahead neutral.
  The recurring cause is clock residency (sclk unpinned, dips to 500 MHz between
  bursty submits), not arithmetic. Do not port "fewer submits" as a win.
- **Scheduling within one saturated device cannot create bandwidth**: T5
  collapsed pilot waits 80× with zero wall change; per-device queues are noise;
  only added lane concurrency (shared and per-device) paid.
- **Refused/negative A/Bs**: fp32 accumulator for #46 (+0.8 % end-to-end, parity
  risk — reverted), `COLI_CUDA_MOE_RING` at 32k, P1 deep QD at ≥32k, promotions
  when the pool is warm-booted (−23 %).
- **Single-run numbers**: the 512-token prefill in `audit-m43` is one run per arm
  (±10 s class); the 8.8k ring arm is 1 rep; the 128k prefill is a projection
  from a 3600 s cap. Treat as directional only.
- **Build-dependent flips**: the M5-1c short-prompt parity flipped after a clean
  LTO rebuild with no functional change; `idxsel2.spv` shipped byte-identical to
  `idxsel.spv` for weeks (the "fix" was never compiled). Never cite parity from a
  single binary.
- **Wrong-lever experiments**: G17's prefill conclusion came from a flag that
  never reached the prefill path (it compared GPU prefill with GPU prefill).
  Verify engagement counters before believing an arm.

## 4. Numerics envelope caveat (what re-validation must cover)

The tier is **thresholded, not bitwise**, against the CPU: fp32 tree reductions
vs the CPU's exact accumulation order, and the prefill bank adds a f32-sum drift
that occasionally flips a bf16 boundary. Effect: greedy long generation diverges
on borderline logits — measured flips at token 1 (math-trains), ~5 (code-lru),
~5–6 (json-schema, formatting only), ~7–8 (code-review), ~28 (photosynthesis);
tool-use/agent-loop/agent-recover/long-multi held 64 tokens. The envelope is
**prompt- and build-dependent** (G12; `audit-longbench-2026-08-30.md`), and the
parity proofs are codegen-sensitive (ACO FMA contraction, chained-fp64 rounding,
fp32-FMA denormal flush — REVIEW F2). Re-validation on a fresh upstream must
therefore: (a) run per-op suites against the CPU oracle for every op it touches,
(b) re-establish the envelope per prompt class rather than assuming "≤16 tokens",
(c) re-run the bitwise gates after any compiler/upstream hot-loop change, and
(d) treat any upstream rewrite of `deepseek_v4.c` MoE/attention loops as
invalidating the L2 gates until re-measured. Test gates themselves:
`TEST.md` §3 (CUDA tolerance class, 40/40 `test-vk-all`), `scripts/vk_parity.sh`,
`vk_golden_parity.sh`.

## 5. Ranked top-10 for a fresh upstream fork (expected value, not commit volume)

1. **Dense fp8 GPU tier + post-upload RAM handover** — the load-bearing 2×:
   1.01→2.03 tok/s decode, 225→112 s prefill. Everything else is secondary.
2. **GPU prefill expert bank, gate at 1 token** — 576 s vs 967 s (CPU union),
   −708 s at 4k; wins every length; only VRAM-refusal falls back.
3. **Decode lane work: demand lanes + warm-pool lane compute + async pilot** —
   +23 % then 2.05→3.0 tok/s; the single largest post-tier decode lever.
4. **mm8 tiled projection GEMM (#46)** — 4.73× on the projection phase, 6.8 %
   end-to-end, bitwise on production data classes.
5. **pf4 expert GEMM + expert-major bank + VRAM activation placement** —
   2.94× routed cell, 2.65× session GMAC/s, wo_b −55 %.
6. **GPU-MFU sizing: fill-to-free, ÷4 decay, dual residency, MFU/MRU split** —
   0.70→0.95 tok/s (+33 %), then +4.3…6.4 % multi-turn; also fixes a serve wedge.
7. **Host-RAM prefetch ring + parallel take** — −5…−24 % TTFT across 0.5k–8.8k,
   reads-only, byte-identical; cheapest large win for short/medium prompts.
8. **Decode attention cell + S=1 GEMV + mHC decode fusion** — +4.1 % and +19 %,
   both bitwise-gated; also the substrate for a replayable segment.
9. **Flash-attention kernel** — attention 5.0× @2k / 16.7× @8k; the long-context
   prerequisite, low risk (1 bf16 ulp gate).
10. **Indexer: LDS-tiled score + idxsel v2** — 4.2× indexer at 8k, −9.4 % TTFT
    at 33k; the measured long-context slope term.

## 6. Lowest value — skip (or port last)

1. **Cadence-op submit folds** (dec2-mhc, SHARED_DEFER, COMP_FOLD_DEC,
   COMP_RESIDENT, FFN_TAIL, cell-tail, queue-ahead): measured neutral to −10.5 %.
2. **Per-device NVMe queues / demand-priority scheduling**: emulator and A/B
   both at noise; multi-drive already works via routing + lanes.
3. **T5 next-token PILOT**: waits collapsed, wall unchanged; reverted.
4. **fp32-accumulator / numerics-relaxation variants**: +0.8 % end-to-end for a
   parity-class break; mm8 split-K already moved to a reassociation class for
   −31 % on wo_b, which is the only numerics relaxation worth carrying.
5. **PSI elastic RAM and device-only fp16 KV**: no measurements exist; both are
   design documents. Port only after a fresh A/B on the target box.
