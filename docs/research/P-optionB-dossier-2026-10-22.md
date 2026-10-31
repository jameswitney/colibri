# Evidence dossier — "Option B": transplanting the fork's cell-pipeline dense fold

**Prepared for the owner's decision. No verdict is offered; the trade space is presented.**
Fork: `/root/Projects/colibri-ds4-vulkan` @ `d11fba5b` (= tag `port-source-2026-10-19`).
Port: `/root/bench-worktrees/up2276-merge` (`port/up-2276` @ `d1a2abba`, base `upstream/dev` @ `b90a369e`, mm8 landed).

**Labels used throughout**
- **MEASURED** — a number from a cited run/arm table/doc on this rig, or read directly from code.
- **ESTIMATED** — arithmetic or judgement derived from measurements; the derivation is shown.
- **OPEN** — an unresolved attribution, a contradiction between sources, or an untested assumption.

**Naming collision (read first).** `docs/PORT_PLAN.md` §6.1 defines an "Option B" that is *not* this one
(that one = revive the fork's `backend_vulkan_dsv4.c` per-op ABI as the surviving stack; **decided
against** 2026-10-19, `PORT_PLAN.md:279-302`). The "Option B" of *this* dossier is what
`docs/HANDOVER-2026-10-22.md:89` calls "the cell-pipeline dense fold — the last ~90 s of TTFT; an
architecture transplant (fork stack, 'Option B'); only if we consciously relax the 'capabilities, not
stack' decision". They share a shape (relax the 2026-10-19 principle) but not a file set.

---

## 1. WHAT the fork's cell pipeline IS

### 1.1 The unit of work

A **cell** is one *layer × one token-chunk* (prefill) or one *layer × one token* (decode), recorded into
**one Vulkan submission**, with the MoE half folded into that same submission where eligible. There is no
per-op submit inside a cell: the cell's command buffer is opened by the *prologue*, camera-appended by
every stage, and ended+fenced once by the *join*.

The recorders (all in `c/backend_vulkan.c`, all named `ds4vk_*`):

| stage | recorder | anchor |
|---|---|---|
| cell ownership / "am I inside a cell" | `ds4vk_cell_recording()` | `backend_vulkan.c:2118` |
| prologue: wq_a QDQ+fmt8 matmul + q_norm + both compressor wkv/wgate pairs, one staged activation | `ds4vk_cell_prologue_impl()` | `backend_vulkan.c:14436`; commit `:14827`; engine side `deepseek_v4.c:17494-17619` |
| pre-indexer segment (prologue + resident `comp_scan`) committed as one | `coli_v4_gpu_cell_prologue_defer()` call sites | `deepseek_v4.c:4797-4801`, commit `:5078/:5327` |
| indexer train (qdq+idxproj+prep+score+sel) | `ds4vk_idx*` | `backend_vulkan.c:5459+` |
| attention segment (16 dispatches, batch=1 supported) | `coli_vk_dsv4_attn_seg_*` | `backend_vulkan.c:15596-16267`, `:6417` copy-out |
| KV ring append (device resident window ring) | `coli_vk_dsv4_kv_ring_append[_resident]()` | `backend_vulkan.c:4911`, `:4945`; engine `deepseek_v4.c:22016` (wqb+wo append) |
| wo chain joined onto the segment (wo_a grouped, wo_b, mHC tail) | `ds4vk_wo_record`, `ds4vk_attn_resident_wo_impl`, `ds4vk_attn_join_wqb_wo_impl` | `backend_vulkan.c:15596+`, `:16267` |
| **join** (end, submit, ONE fence, all copy-outs) | `coli_vk_dsv4_cell_join_commit()` | `backend_vulkan.c:9004`; engine wrapper `deepseek_v4.c:20998` |
| queue-ahead (fence left pending, `COLI_DSV4_VK_QUEUE_AHEAD`) | `cell_join_commit_nowait` | `backend_vulkan.c:6378-6391` |
| **decode** cell: dec2 = wq_a+wq_b+wkv+q_norm+rope in ONE submit, optionally absorbing the segment | `ds4vk_dec2_qkv_impl` | `backend_vulkan.c:13715+` block; engine `deepseek_v4.c:20665-20790` |
| **FFN opener** (decode): ffn mHC pre + route gate GEMV + shared-expert chain as ONE submit, consumed by the MoE later | `coli_v4_gpu_ffn_opener_try/take_shared` | `deepseek_v4.c:21404-21757` |
| mHC pre/post arm→head→tail riding the same submit | `coli_v4_gpu_mhc_cell_arm`, `ds4vk_mhc_cell_flush` | `deepseek_v4.c:21107-21380`; `backend_vulkan.c:7652-7863` |
| **expert bank** (shared, MoE) — 256-expert per-layer VRAM bank, expert-major | `eg2_bank_ensure_pool`, `egm_bank_execute` | `backend_vulkan.c:10696`, `:12625`; entry points `:13145-13311` |
| decode orchestrator that wires it all | `block_token_pipeline()` | `deepseek_v4.c:10030-10253` |
| prefill cell that wires it all | `attention_token_impl()` (≈4.4k lines) | `deepseek_v4.c:3979-8399` |
| MoE half consumed by the cell | `moe_token_pipeline()` | `deepseek_v4.c:9132` |
| host-RAM ring (next-layer prefetch, parallel take) | `v4_ram_*`, `v4_ram_take` | `deepseek_v4.c:18481-18521`, used at `:19296` |

### 1.2 The components, with size and separability

LOC are read from the tree (fork) — the ranges are the *region* a port would have to re-express, not a
diff.

| # | component | fork lines (approx) | shaders | separable from the cell? |
|---|---|---|---|---|
| A | **Dense fp8 projections + glue** (wq_a/wq_b/wkv/wo/wo_a grouped, norms, bf16 rounds, rope) | `backend_vulkan.c:13715-16747` (~3.0k, the "fused DECODE dense chain" block) + `attention_token_impl`'s dense legs | `glue1/2/3.comp` (493), `glue_qn_rope.comp` (139), `dec_qa/dec_rows/dec_fin` (409), `bf16r.comp` (31) | **No** — this *is* the fold: it only pays because the recording granularity is a cell |
| B | **mHC pre/post device residency + decode fusion** | `backend_vulkan.c:~5950-8100` (~2.1k) | `mhc_pre_fused`, `mhc_dec_pre`, `mhc_dec_post`, `mhc_ffn_tail`, `mhc_sinkhorn`, `mhc_collapse`, `mhc_rmsinv`, `mhc_rmsnorm` (~1.1k total) | **Yes** (separately measured: +19 % decode, `59ae2f90`) — and *already covered in the port* (see §3.3) |
| C | **Compressor + DSA indexer on device** | `backend_vulkan.c:5459-6100` (~650) + engine gates | `comp_scan(.par).comp` (677), `idxprep/idxproj/idxscore(_tiled)/idxsel/idxsel2` (1,098) | **Yes** (shader-only), but the port's `chain_dsv4.comp` already has these modes |
| D | **Sparse attention (FA + Br=2 decode tile)** | `backend_vulkan.c` attn block | `sparse_attn(_fa)(_dec)(_f16).comp` (527) | **Yes** (shader-only); the port has `chain_attn_flash` for other engines but not in the V4 chain |
| E | **Expert bank, shared** (256-expert/layer VRAM, expert-major, weight-stationary) | `backend_vulkan.c:10696-13350` (~2.6k) + engine refill `deepseek_v4.c:19139-19460` (~320) + `v4_moe_batch_union*` `:10411-10579` | `qmatmul_pf4*.comp` (923), `qmatmul_s1_fp4/s1g` (200), `moe_swiglu/merge/reduce`, `wo_gather/wo_in_gather` (257) | **Yes, strongly** — it lives on the MoE path, not the dense path (see §2) |
| F | **The cell machinery itself** (ownership, prologue-defer, join, queue-ahead, CB-session guard) | `backend_vulkan.c:2118, 6378-6391, 9004` + `deepseek_v4.c:3979-8399` (~4.4k) | — | **No** — this is the fusion |
| G | **Host-RAM ring** (next-layer prefetch into the bank, `ring=3.19 GiB qd=16 take=par`) | `deepseek_v4.c:18481-18600` (~120) + `deepseek_v4_ram_prefetch.h` (75) | — | **Yes** mechanically, but bank-coupled (it exists to feed the bank) |
| H | **dsv4 ABI shim** (`dsv4_cuda_*`, 81 symbols) | `backend_vulkan_dsv4.c` (5,433) + `.h` | — | This is the *Option B* of `PORT_PLAN` §6.1, not of this dossier — **out of scope** |

**Interdependence summary (MEASURED from code).** A→F are one object: `ds4vk_cell_recording()` gates
every recorder (`backend_vulkan.c:2118, 2143`), and `cell_join_commit` is the only place outputs become
host-visible (`:9004`, copy-out block `:7652-7863`). E→A only through the FFN opener (`deepseek_v4.c:21404-21445`),
which is a submit-count/glue optimisation the fork itself measures as a **wash** end-to-end
(`+0.3 %`, `deepseek_v4.c:21458-21472`) — so **E is separable from A/F**: the bank's beneficiary is the
*MoE* stage, not the dense recording.

Fork's own dependency graph: `docs/research/B-fork-inventory.md:§7` (`V6 → V9 → T1 → T2`; `V7/V8 → V6`).

### 1.3 Boot-time evidence that this is a single switch

Fork boot line: `v4_gpu boot-gate-ok device=0 cell-pipeline=on` (`bench/up2276/fork-full-r3.log`), from
`dsv4_cuda_cell_pipeline_probe()` (`deepseek_v4.c:16842`). The cell pipeline is on/off as one thing; the
fork has no supported "cell for dense, not for MoE" configuration other than the two arms used in the
campaign (`DSV4_VK_EXPERTS=0` turns off the *expert fold*, not the cell).

---

## 2. The EXPERT BYTE ECONOMY — 68 GiB vs 148–435 GiB

### 2.1 The measured facts

| arm | expert bytes read for the 2,515-tok prompt | source |
|---|---|---|
| fork, expert fold **off** (`DSV4_VK_EXPERTS=0`) | **68.5 GiB** — "store: 16,254 requests, 68.5 % hits, 5,113 misses" | `O-day2-fork-gap-and-mx-gemm.md:§10` |
| port, `STREAM_SLOTS=192 GEMM_ROWS=4` | **199 GiB** streamed | `O-day2-fork-gap-and-mx-gemm.md:§7` table |
| port, defaults (64 slots, gr16) | **148 GiB** streamed; 90,807 rows (16,703 experts) kept on the CPU | `O-day2` §2, §7 |
| port, `TIER_GEMM_ROWS=1` (everything streams) | **697 GiB** | `O-day2` §2 |
| port, campaign-total figure quoted in the handover | "260 GiB — it never re-requests; we re-sweep 4×" | `HANDOVER-2026-10-22.md:39-41` |

Bandwidth measured in the same logs: **8.0–8.5 GB/s** for a 15.0 MiB expert upload
(`bench/up2276/merge-gemm-r1.log`: "an upload of 15.0 MiB at 8.0 GB/s takes 1.975 ms").

### 2.2 Exactly why the fork never re-requests — the mechanism, with anchors

Three mechanisms, in order of measured contribution:

1. **The bank is a per-layer expert cache with a validity bitmap.**
   `deepseek_v4.c:19273` allocates `dsv4_cuda_expert_bank_create(256, 4096, 2048, …)`; the layer changes
   clear it (`:19291-19294`, `bank_layer != layer → memset(bank_valid,0)`), and the refill uploads only
   `!bank_valid[expert]` entries (`:19420-19433`). The code states the effect itself:
   > "Route-aware refill: the persistent bank is a perfect per-layer expert cache. Each chunk routes
   > first, then uploads only the routed experts that are not already resident for this layer, so every
   > expert is read from the store **AT MOST once per layer** — the CPU union's LRU cache re-reads the
   > same experts several times per layer under prefill's expert-major sweeps (measured **~4-6x** the
   > layer's expert bytes)." — `deepseek_v4.c:19284-19290`

   256 experts × ~12.8–15 MiB ≈ **3.3 GiB of VRAM** (`V4_GPU_BANK_MIB 3277`, `deepseek_v4.c:16642`),
   i.e. it *replaces* the resident tier for the duration of a prefill (the fork sheds the VRAM tier to
   make room: `gpu_mfu_cache_shed_all()` at `deepseek_v4.c:19239`, and post-prefill refill is explicitly
   "INERT by design… `had` never drops to 0" once that shed was removed, `deepseek_v4.c:16130-16146`).

2. **The refill bypasses the store's cache entirely.**
   > "STAGING refill…: read each missing expert with `coli_v4_expert_store_read_bytes` into a BOUNDED
   > pool of aligned buffers, then upload to the bank — **never the store-lease path**. The lease path
   > (`coli_expert_lookup`) fills the store's own RAM slab cache… `read_bytes` touches no cache/lease/slot
   > state ('no mutex is needed'), so the host cost here is FIXED — N buffers x 16 MiB — independent of
   > layer count or missing-set size." — `deepseek_v4.c:19429-19438`

   This is the reason the fork's *RAM retention* survives a prefill: the prefill does not evict the
   decode hot set, because it does not enter the cache at all.

3. **The cross-layer/RAM layer**: the v5 ExpertCache (frozen MFU/MRU tier, single-mutator, no mid-request
   demote — `B-fork-inventory.md` §1 C1–C7: `mfu_table.c` 147, `expert_slot_pool.c` 285,
   `miss_path.c` 101, `expert_cache.c` 281, `cache_reorder.c` 466, `gpu_mfu_cache.c` 527) plus the
   host-RAM ring (`moe-ram=on ring=3.19 GiB qd=16 take=par`, `fork-full-r3.log`). This is what the
   day-2 report blamed first (~60 s, `O-day2` §10).

### 2.3 The attribution is genuinely contested — flag for the owner

The same campaign hands down **three different** explanations for the 68 GiB:

| source | explanation | implication for cost |
|---|---|---|
| `O-day2` §10 | "**~60 s of expert BYTE economy**: … the fork's ExpertCache/slot-pool **retention policy** keeps the working set; our LRU thrashes on the cyclic segment access (13,158-expert working set). This is a **retention-policy port, not a bandwidth problem**, and it is cheaper than the ring with a bigger ceiling than we thought (~60 s)" | small, engine-side |
| `O-day2` §3.1 | "The fork gathers every routed expert's rows across a step, uploads each expert ONCE into a 256-expert per-layer VRAM bank… Measured headroom: **~90–140 s** of the ~230 s TTFT. This is the top candidate — as an extension of upstream's slot machinery" | medium, tier-side |
| `O-day2` §11 | "the fork's cell pipeline … **that architecture is what reads 68 GiB** where every windowed layout reads 230–435" | large, fold-side |

The §10 evidence is the `DSV4_VK_EXPERTS=0` arm. That arm disables the *expert fold* (v5-cache / GPU
experts) — it does **not** disable the bank, the `read_bytes` refill, or the dense cell. So §10 is
**not** a test of "cell vs no cell"; it is a test of "expert fold vs no expert fold". §11's window sweep
(argued below) is the only evidence pointing at the recording architecture, and it is *indirect*.
**OPEN: no arm exists that runs the fork's retention/bank policy on the port's windowed recording, or the
port's recording on the fork's retention. That is the experiment the decision hinges on.**

### 2.4 Byte→time arithmetic (ESTIMATED, from measured bandwidth)

At ~8 GB/s, serial:

| read set | GiB | GB | s of NVMe |
|---|---:|---:|---:|
| fork (fold off) | 68.5 | 73.6 | **9.2** |
| port defaults | 148 | 159 | 19.9 |
| port slots192+gr4 | 199 | 214 | 26.7 |
| port `GEMM_ROWS=1` | 697 | 748 | 93.5 |
| handover's "260" | 260 | 279 | 34.9 |

Reads are overlapped with compute (the fork's ring, the tier's prefetcher), so the *wall* delta is
strictly smaller than the byte delta ÷ bandwidth, and the day-2 report's ~60 s figure corresponds to the
**pre-slot-widening** arm (435 GiB class, `O-day2` §10 item 1). After §7/§8 (slots 256, gr4 → 194.9 s),
the pure-byte headroom to the fork's read set is **~80 GiB ≈ 10 s of NVMe**, not 60 s.
**ESTIMATED, and this is the single most important number to re-measure before making the call.**

### 2.5 What a minimal "no re-request" port looks like, WITHOUT the whole fold

**It is independent of the cell pipeline.** The bank lives on the MoE path (`v4_moe_batch_union` /
`egm_bank_execute`), consumes a route computed by the existing router, and produces the MoE output; it
touches no dense recorder. The only cell-flavoured coupling is the FFN opener, which the fork measures
as a wash (`deepseek_v4.c:21458-21472`).

The port already has every seam the minimal version needs:

- **route-aware, expert-major batch dispatch**: `coli_vk_xb_*` items/expert-table/amap sub-batches
  (`O-day2` §4), plus the MXFP4 grouped GEMM `qmatmul_grp_mx.comp` (155 lines, mode 4,
  `COLI_VK_XB_GROUPED_MX`, `backend_vulkan.c:4539`) — i.e. **the weight-stationary compute half already
  exists for fmt 7**;
- **a VRAM expert window**: the tier's stream slots (`VStage`, `vk_tier.c:71`, sizing
  `vk_tier.c:2725-2740`, VRAM budget carve-out `fit > fit_raw - slots`);
- **a host pool + promotions** (`COLI_VK_TIER_PROMOTE`, `O-day2` §6).

**The one policy line that makes it "at most once per layer" is currently the opposite:**

```c
/* c/vk_tier.c:1354-1358 — prefetched slots this step does not stream go back */
for (int i = 0; T.st && i < T.st_n; i++) {
    VStage *v = &T.st[i];
    if (v->state == SS_FILLED && (v->layer != layer || cls[v->eid] != BC_STREAM)) v->state = SS_FREE;
}
```
A slot is dropped when the current 768-row step merely *does not route* that expert, even on the same
layer — so a layer's 3 steps (2,515 / 768 ≈ 3.3) re-stream experts that were resident one step earlier.
Slot reuse across steps of the same layer *is* implemented (`vk_tier.c:1426-1431`), which is why widening
the slots helped at all; the free-on-non-route rule is what caps the win. **MEASURED from code; the byte
consequence is ESTIMATED.**

Minimal port shape (**ESTIMATED**, ~400–800 lines, no shaders): retain a *layer window* of N slots with
LRU eviction instead of free-on-non-route; route-aware fill from the store with a fixed bounded buffer
(no cache-lease churn, the fork's `read_bytes` discipline); count and log `bytes read` and
`misses per layer`. Costs: N × 15 MiB of VRAM (256 → 3.84 GiB, taken out of the tier's 465-expert/7.79 GiB
budget, cf. `merge-gemm-r1.log`) **and** N × 15 MiB of host staging (`HANDOVER` §8 trap 2: "Slot staging
is host RAM (~15 MiB/slot): 28 GiB plan + 8 GiB pool + 192 slots OOMs a 34 GiB cgroup").

### 2.6 The counter-evidence must be carried into the decision

**The host-RAM ring was implemented on the port and measured 0 hits, then reverted** (`O-day2` §11):
"At any viable capacity (~3 GiB = 240 experts) it measured **0 hits**: the reuse distance of a layer's
set is 43 layers × ~221 experts ≈ 9,500 experts — no capacity short of the model itself spans it, and
per-layer partitioning divides capacity by 43. The ring's copies only added overhead (314 s vs 202)."

That experiment is about *retention of streamed experts in front of the store* — the same 3 GiB the
fork's bank spends. Why the fork wins where the port's ring measured 0 hits is **OPEN** and is the crux:
the fork's window is *per layer and refilled every layer* (reuse distance = 0 layers within a layer's
step), whereas the ring was a *global* heat-ranked window (reuse distance = 43 layers). The code
suggests the distinction is real (`bank_layer != layer → memset`), but no arm has isolated it.

---

## 3. The DECODE side — fork 1.16 vs port 0.61

### 3.1 The one decisive measurement

`O-day2` §10, six interleaved arms, two reps each:

| arm | TTFT | decode |
|---|---:|---:|
| fork, full GPU-FOLD | 107.8 / 104.4 | **1.162 / 1.155** |
| fork, expert fold OFF (`DSV4_VK_EXPERTS=0`) | 104.1 / 104.2 | **0.630 / 0.610** |
| port (`s256-gr4` at the time) | 202.0 / 202.4 | 0.515 / 0.520 |

**MEASURED: the expert fold is worth 1.84× on decode and ~0 on TTFT.** Everything else in the fork's
decode stack is *inside* the fold-free arm and therefore already not the differentiator: the port at
`PROMOTE=32` + 8 GiB pool reaches **0.654** (`O-day2` §6), which is at/above the fold-free fork
(0.61–0.63). So the entire remaining decode gap is the fold's device-resident hot set — not dec2, not
the attention segment, not the mHC fusion, not the lanes.

### 3.2 The fork's own decode profile (pre-fold, 0.85–0.92 tok/s)

`docs/archive/reviews/decode-profile-2026-09-29.md` (2010-tok prompt, 64 tokens, median of 2–3 reps):

| metric | value | line |
|---|---|---|
| decode wall | 1,095–1,170 ms/token | `:31`, `:127` |
| **expert op** | 14.5–14.6 s = **33 %** (2,050 calls, 7.1 ms avg) | `:56` |
| **glue op** | 12.7–13.2 s = **29 %** (774 calls, 16.5–17.1 ms) | `:57` |
| mhc / indexer / route / wo / qkv / shared / attn / head / comp | 9 / 6 / 6 / 5 / 5 / 4 / 2 / 0.5 / 0 % | `:58-67` |
| **GPU busy, decode window** | **11–13 %** (med), power 40–41 W | `:36-37`, `:80` |
| **disk IO busy** | **51.0 % / 53.2 %** (whole run); 40–41 % over the decode window | `:39`, `:131` |
| decode-window split | GPU 132–175 ms (12–16 %), disk 440–451 ms (40–41 %), CPU indexer 43 ms (4 %), **host glue/launch/sync ≈ 430 ms (~40 %)** | `:127-135` |
| expert cache routing during the run | GPU tier 15 %, MFU 0 %, MRU 56–57 %, **miss→disk 28 %**; GPU tier 381–387 entries of cap 880–898 | `:49-52` |

> **Note on the task's "dense 16 %":** the fork's published table gives **GPU execution 12–16 %** of the
> decode wall (`:127`), not a "dense op" share; the per-op table's dense rows (qkv 5 %, wo 5 %, attn 2 %,
> shared 4 %) sum to ~16 %. Both readings land on 16 %; cite whichever, they are the same phenomenon from
> two angles. **MEASURED.**
> The 1.16 tok/s arm has **no published per-op profile** — the profile above is the 0.85–0.92 tok/s
> config. **OPEN: the fold's effect on the op mix is inferred, not published.**

### 3.3 What exists in the port today vs what is missing

| fork decode lever | fork evidence | port status |
|---|---|---|
| **expert fold: VRAM-resident hot set + device-side expert compute (fused group), MFU/MRU split, promote ring, gap-exact shed** | **1.84×** decode (`O-day2` §10); +33 % from fill-to-free/÷4-decay (`C-perf-evidence.md` §2 "GPU-MFU fill-to-free"); adapt 75.0 % hit vs 70.3/72.8 (`d11fba5b`, `C-perf-evidence.md` §2) | **partly**: tier = VRAM resident set + LFRU (`vk_tier.c`), partial-pool promote (`COLI_VK_TIER_PROMOTE`, 0.654), host pool. **Missing**: dual residency, MFU/MRU split sections, promote ring with warm-boot discipline, gap-exact shed — i.e. exactly the C6 module (`gpu_mfu_cache.c` 527 lines). |
| dec2 (decode qkv in one submit) + attention segment | +4.12 % decode, 6/6 pairs (`d87233f7`, `C-perf-evidence.md` §2) | **superseded by the chain**: the port records the whole dense half of a layer into one frame (`deepseek_v4_chain.h:1297-1320`, `vkc_begin`/`vkc_submit`) |
| **mHC decode pre/post fusion** | **+19 %** decode (1.17 → 1.40 tok/s; `59ae2f90`) | **already present in form**: `v4c_pre`/`v4c_post` record `vkc_mhc(SPLIT/COLLAPSE/POST)` *inside* the layer frame for every row count including 1 (`deepseek_v4_chain.h:949-963`) on a discrete GPU, where `coli_vk_chain_decide()` returns ON for decode too (`backend_vulkan.c:2672-2696`). **ESTIMATED near-zero headroom** — the fork's +19 % was host-loop → device-fuse, a step the port never takes. |
| demand lanes (+23 %), async PILOT, warm-pool lane compute (+32 % wall) | `C-perf-evidence.md` §2 (G15/G14, `0f1b06d2`) | **falsified/superseded**: "P2.2 async PILOT — upstream's `vkt_join` computes host experts before waiting" (`PORT_STATUS.md:65-66`) |
| dec2-mhc / SHARED_DEFER / COMP_FOLD_DEC submits folds | **−10.5 % / −4.6 % / −2.1 %** (`C-perf-evidence.md` §3) | do not port (measured negative; cause = sclk residency) |
| WO_S1G, EXPERT_S1GEMV, BANK_DESC_CACHE | **wash**/neutral (`C-perf-evidence.md` §5, `B-fork-inventory.md` §5) | skip — "fewer submits / less glue" is not a measured win in the fork's own record |
| mm8 tiled projection GEMM (prefill S≥2) | 4.73× on projections, ~6.8 % e2e (`232c3d5d`) | **landed** in the port: `COLI_VK_MM8`, `COLI_VK_MM8_SPLITK` (`PORT_PLAN` §4.3 P3.1; arm 229.5–239.8 s vs defaults 257.7–261.6, `d1a2abba`) — decode unchanged (mm8 refuses S<2 by construction, fork `backend_vulkan.c:1104`, `:13730`) |
| mm8-class **decode** projections (int8 activation, S=1) | fork claims 4.73× "on that class"; day-2 §6 estimates 0.65 → ~0.9–1.0 | **missing**; needs the F8 envelope language first (`HANDOVER` §6.1) — *not part of Option B, but the largest decode item that is not the fold* |

**Bottom line for §3 (MEASURED):** the port has already reached the fork-minus-expert-fold on decode.
A cell-pipeline dense fold does **not** by itself close the decode gap; the decode gap belongs to the
expert fold (C6/C7 + a device-resident hot set), which is a *tier* capability, not a recording
architecture.

---

## 4. PORT COST — what transplanting the cell pipeline onto the port's `vk_chain.c` lineage means

### 4.1 The two architectures, side by side

| | fork | port |
|---|---|---|
| unit of submission | **cell = one layer × chunk**, one submit, joined once (`backend_vulkan.c:9004`) | **frame = one layer × chunk's dense half**, one submit (`deepseek_v4_chain.h:1297-1320`), then **host** MoE, then a second submit for the shared expert (`:1310`) |
| who owns the device | `backend_vulkan.c` (18,237 lines, 371 functions) + `backend_vulkan_dsv4.c` shim (5,433) | `vk_chain.c` (3,616) + `vk_tier.c` (3,100) + `backend_vulkan.c` (7,773), shared by 9–11 engines |
| dense ops | per-op recorders appended to one CB (`ds4vk_*`) | op recorders over a 16-frame ring, one pipeline layout, 8 bindings + 128 B push constants (`vk_chain.c:1-16, 67-80`) |
| MoE during a step | **inside the cell** (bank + fused group) or the FFN opener tail | **host** `coli_v4_moe_routed` between two frames (`deepseek_v4_chain.h:1330-1352`), or upstream's device MoE for *other* engines (`vk_dmoe.h`) |
| device MoE capability | in the cell | **exists but unused by V4**: `vk_dmoe.h` (678 lines) does exactly this for a step of ≤8 rows (`VKC_DMOE_ROWS`, `vk_dmoe.h:52`) and for prompt chunks via `vkc_moe_rows` grouped GEMMs — but `deepseek_v4_chain.h` does **not** include it (includes are `vk_chain.h`, `vk_kvsplit.h`, `deepseek_v4_chain.h:90-91`; `vk_dmoe.h` is included by `olmoe/qwen36/qwen38_chain.h` only) |
| measured host MoE wall | fold: n/a (device) | **215,900 ms of routed experts on the host** over 64 forwards in the chain report (`bench/up2276/merge-gemm-r1.log`) vs `25,848 ms waiting for the device` |

### 4.2 What "capabilities, not stack" bought

`PORT_PLAN.md:§1.1, §6.1` (decided 2026-10-19, D3): keep upstream's chain/tier, port capabilities into
its seams. The realised payoff, from the port's own record:

- **Four slices merged with 0–2-conflict files and no functional loss** (`PORT_STATUS.md:12-27`,
  `N-up2276-merge-report.md` §"The regression the gates caught"): strict gate, tier host pool, chain GEMM
  (#2253 — *already an upstream PR, accepted by the maintainer*), KV cold tier v2.
- **Seven further day-2 slices landed on the same base** (MXFP4 grouped GEMM, partial-pool promote, docs)
  — `HANDOVER-2026-10-22.md:§3`.
- **Upstream's own decode gain was inherited free**: 0.487 → 0.60 tok/s from their host-pool series
  (`PORT_STATUS.md:60-64`) — a capability the fork would have had to re-import.
- **The chain's decode path came with device mHC and one-submit-per-layer**: i.e. roughly
  dec2 + attention-segment + mHC-fuse (~4 %, ~19 % class) for zero port cost.

### 4.3 What a fold port would cost, measured in divergence

Upstream commit velocity and churn (MEASURED, `git log upstream/dev`):

| window | commits | of which touch `c/vk_chain.c` | touch `c/backend_vulkan.c` | touch `c/vk_tier.c` | touch `c/deepseek_v4.c` |
|---|---:|---:|---:|---:|---:|
| last 400 | 400 | **105 (26 %)** | **111 (28 %)** | 57 (14 %) | 166 (42 %) |
| `a0037a3a..b90a369e` | 177 | 0 | 0 | 0 | *n/a (see below)* |
| `b90a369e..upstream/dev` | **31** | **0** | **0** | **0** | *yes* (`:294 lines`) |

Two things are true at once and both matter:
1. **In the last 31 commits** upstream touched **no** Vulkan file — the traffic is entirely the CUDA
   tier (`cu_tier.c`, `cu_dense.h` +180, `backend_cuda*`, five engines' GGUF-dense hooks) plus docs;
   `git diff --stat b90a369e..upstream/dev` = 33 files, `+1,515/−419`, zero `c/vk_*`.
2. **In the last 400 commits** upstream rewrote `vk_chain.c` in 105 of them — chain work is *bursty and
   continuous* (e.g. `f79cd944` "the routed experts' passes for a GGUF by the layer's shape",
   `d918c75c` verify rows as decode steps, `09238ec5` `chain_moe_gv.comp` MXFP4, `0b5b7f9a` DSA indexer
   scores on a workgroup grid, `349ee999`, `7e590705` MLA decode core, `21dbf19f` KDA recurrence).
   `docs/research/B-fork-inventory.md` §0 records the same conclusion for DeepSeek V4's own ops.

**ESTIMATED merge-risk:** a fold that rewrites the V4 chain's frame model (`v4c_forward_seg`,
`v4c_attention`, `v4c_join`, `v4c_pre/post` — `deepseek_v4_chain.h:991-1090, 1104-1360`) sits on files
upstream edits in **~1 commit in 4**, and on `deepseek_v4.c` (42 % of commits) because the fold also
changes the engine's block/MoE call sites. Every upstream `upstream/dev` merge boundary
(`PORT_PLAN` §6.2 "merge every release boundary") becomes a hand resolution in the hottest files, which
is precisely the cost the 2026-10-19 decision paid to avoid (`PORT_PLAN` §1.1: "217 `COLI_V4_GPU_TIER`
sites in the fork vs 48 upstream, 307 `dsv4_cuda_*` call sites vs 143, a 7,752-line GPU unit upstream
does not have… a rebase produces a plausible-looking binary that misbehaves").

### 4.4 Code size (ESTIMATED from the component table)

| item | fork source | re-expressed in the port |
|---|---:|---|
| dense fold + cell machinery | ~7.4k (backend_vulkan dense/cell) + ~4.4k engine + ~1.0k shaders | 2.5–4k in `vk_chain.c`/`deepseek_v4_chain.h` (the frame model *is* the fold; the port already has ~60 % of the recorders) |
| MoE inside the frame for V4 (fmt 7) | bank 2.6k + engine 0.6k + pf4 shaders 1.1k | 1.5–2.5k: extend `vk_dmoe.h`/`vkc_moe_rows` to fmt 7 (currently `our_fmt` = 1/2/4 only, `vk_chain.c:2598`) or route V4 through the tier's `qmatmul_grp_mx` (already present) |
| ring / overlap | 0.2k | 0.3–0.6k (a loader thread; the chain has no cross-frame prefetch) |
| mHC, dec2, attention segment, indexer, compressor | 2.1k + 0.4k + 0.5k + 1.1k + 0.7k | ~0 — already covered by `chain_dsv4.comp`/`chain_mhc.comp` and `v4c_pre/post` |
| **total** | — | **~4.5–7k new/changed lines**, 1 new shader family (fmt 7 grouped MoE in the chain), 0 new ABI shims |

### 4.5 Gates

Every ported path must enter the existing gate set (all green at `d1a2abba`, `PORT_STATUS.md:31-38`):
`vk-tier-check`, `vk-chain-check`, `vk-strict-check`, `deepseek-v4-tiny-check` (23 PASS),
`test_v4_serve_framing`, `cu_tier.c -DCOLI_CUDA -fsyntax-only`. A fold additionally needs:
- a **bitwise/thresholded oracle for the folded MoE** per op (the fork's own numerics law: thresholded,
  not bitwise; envelope prompt- and build-dependent — `C-perf-evidence.md` §4, `PORT_PLAN` F8), which the
  port does not have for fmt 7 device MoE because that path does not exist;
- a **cell-replay/golden leg** (`PORT_PLAN` §7 G1/G2; `.golden` re-record ≈ 4.1 h per run, F10);
- **engagement counters** as the gate (the G17 "wrong lever" trap, `C-perf-evidence.md` §3);
- the tier/chain **cross-engine** gate (`tests/vulkan_engines.sh`), since the fold would touch shared code.

### 4.6 Would upstream take it? (evidence, not opinion)

Signals from the tree and the queue:

- Upstream's own architecture direction for device MoE is **`vk_dmoe.h`** — a *generic, reusable*
  in-chain MoE for a step of ≤8 rows plus grouped GEMMs for chunk rows, driven by the tier's device
  address table. It is engine-agnostic (`vk_dmoe.h:1-40`); DeepSeek V4 is simply not wired to it.
- Upstream's current 31-commit burst is **the CUDA tier** (`e0a4627d` `cu_dense.h`, `beb23ec8`
  glm53/v41/mimo routed-expert tier on a CUDA device, `35632423` kimi_k3, `4c10d4e7` batched GPU
  attention for a GGUF on CUDA, `e43a243a`/`b9ad9738` docs) — RDNA2-specific fork kernels are outside
  that direction, and the chain is actively being generalised (`f79cd944`: "the routed experts' passes
  for a GGUF by the layer's shape, not the step's rows").
- Upstream's accept/reject temperament is recorded and narrow: "small, single-topic PRs with evidence
  (#2252–#2276 all narrow); #2253 got a positive maintainer validation *because* narrow";
  an "all-encompassing performance PR" was considered and advised against (`HANDOVER` §5).
- **The port's own portfolio already verdicts P4.3 (cell/submit merge) "do not port as perf wins" and
  P3.5/P3.6 "conditional on re-baseline"** (`PORT_PLAN` §4.3/§4.4, `PORT_STATUS.md:65-72`).

**ESTIMATED:** a 4.5–7k-line, DSV4-only architectural rewrite of a shared, actively-developed file is at
the far tail of that distribution; the same capability expressed as *tier policy* (retention + promote)
has a plausible one-PR path (`#2258` extension), and the *chain MoE* half has a plausible path as "wire
DeepSeek V4 to `vk_dmoe.h`" — which is a different, much smaller change than the fork's cell pipeline.

---

## 5. The ALTERNATIVES ladder (ranked by evidence-per-cost)

Ranking rule: measured effect on *this* rig ÷ (lines + divergence cost + gate cost). All sizes are
ESTIMATED T-shirt unless stated.

### L1 — Minimal expert retention ("at most once per layer"), the ~60 s claim — **best evidence-per-cost**
- **Fork evidence (MEASURED):** 68.5 GiB vs 148–435 GiB; the mechanism is *in code* with the fork's own
  "4–6×" comment (`deepseek_v4.c:19284-19296`, `:19429-19438`); the arm that isolates it from the expert
  fold exists (`DSV4_VK_EXPERTS=0` → 68 GiB, `O-day2` §10).
- **Port applicability: high.** All machinery exists (route-aware expert-major batch, MXFP4 grouped GEMM,
  VRAM slots, promote, host pool). The blocker is one policy line, `vk_tier.c:1354-1358`
  (free-on-non-route).
- **Size:** ~400–800 lines, no shaders (tier + engine counters + one test).
- **Risks:** (a) the 3 GiB VRAM + 3 GiB host staging must come out of the tier's 7.79 GiB / 28 GiB plan
  (`HANDOVER` §8 trap 2); (b) `COLI_VK_TIER_SYNC=1`'s deterministic-drain contract must survive
  (`O-day2` §9); (c) the 0-hit ring precedent (`O-day2` §11) says a *global* window does nothing — the
  per-layer window is a different mechanism but is **unproven on the port (OPEN)**;
  (d) **ceiling uncertainty**: after slots 256 the byte headroom is ≈10 s (§2.4), not 60 s — the 60 s
  figure belongs to the pre-slot arm. **Re-measure before sizing effort.**
- **Upstreamability:** plausible as a generic tier improvement ("a layer's routed set at most once per
  step"); no DSV4-specific code.

### L2 — The chain MoE half only (wire DeepSeek V4 to `vk_dmoe.h`) — **second best**
- **Fork evidence (MEASURED):** the fork's MoE-side gain on this rig is the host→device move of the
  expert compute, worth 146 s → 56 s host share when the port approximated it with wider slots
  (`O-day2` §7); the port's chain report shows **215.9 s of routed experts on the host** vs 25.8 s of
  device wait (`bench/up2276/merge-gemm-r1.log`).
- **Port applicability: high and cheap to prove** — the mechanism is *already upstream's*, just not
  enabled for this engine (`vk_dmoe.h` absent from `deepseek_v4_chain.h:90-91`).
- **Size:** 300–800 lines (fmt 7 in `our_fmt`/`rows_pipe`, `vkc_dmoe_prepare/on/layer/ids` wiring,
  tier epoch discipline). No new submission model — one frame per forward when every layer qualifies.
- **Risks:** (a) V4's expert tables are fmt 7 (`merge-gemm-r1.log`: "fmt 7 gs 32") and `vkc_moe`/
  `vkc_moe_rows` accept only fmt 1/2/4 or GGUF block types (`vk_chain.c:2598, 2667`) — so this needs a
  new kernel arm or a re-route through the existing `qmatmul_grp_mx`; (b) a frame that reads the tier's
  BDA table must respect `vkt_epoch` (the header warns of freed-memory reads, `vk_dmoe.h:29-33`);
  (c) decode steps are 1 row, below `VKC_DMOE_ROWS`=8 — the same code path serves decode, which is where
  the fold's 1.84× lives, so this is also the *only* candidate in the ladder that touches decode.
- **Upstreamability:** high — it is their own file and their own pattern; a "V4 joins vk_dmoe" PR is the
  shape their recent chain commits take.

### L3 — Expert-fold decode residency (C6/C7: MFU/MRU split, dual residency, promote ring, shed) — **decode's only remaining lever**
- **Fork evidence (MEASURED):** 1.84× decode attribution (`O-day2` §10); +33 % from fill-to-free + ÷4
  decay (`C-perf-evidence.md` §2); adapt 75.0 % vs 70.3/72.8 % hit (`d11fba5b`); v6 spanning cache
  +4.3 % multi-turn but "loses the prefill bank" (`C-perf-evidence.md` §2).
- **Port applicability: medium.** The tier has residency + promote; it lacks the frozen overlay, the
  MFU/MRU split, the promote ring, and gap-exact shed (`B-fork-inventory.md` §1 C6).
- **Size:** ~500–900 lines in `vk_tier.c` (+ tests), no new submission model.
- **Risks:** (a) 16 GiB card, dense chain already 6.40 GiB (`merge-gemm-r1.log`), tier 7.79 GiB — the
  overlay competes with both; (b) the fork's own history shows the MFU/MRU split needed a *direction fix*
  (`d11fba5b`, the fork's last commit) — a subtle policy; (c) measured at this bench's fixed prompt the
  residency benefit is partly invisible (see L4).

### L4 — Post-prefill residency refill
- **Fork evidence (MEASURED, and negative for this bench):** the fork's refill is "**INERT by design**…
  `had` never drops to 0 through a prefill and the early return below fires"
  (`deepseek_v4.c:16130-16146`); the arm needs a tier shed first.
- **Port evidence:** "real in production; invisible in our bench — the fixed `.coli_usage` already
  encodes the prompt" (`HANDOVER-2026-10-22.md:90`).
- **Size:** small (~100–200 lines) — the port's tier already refills by promote.
- **Verdict for this decision:** near-zero bench value; a production/serve-shape item, not a way to
  close the 90 s / 0.55 tok/s gap. Keep on the list only to say it is *not* a lever here.

### L5 — mHC decode pre/post fusion (P3.6)
- **Fork evidence (MEASURED):** +19 % decode, 1.17 → 1.40 tok/s (`59ae2f90`), parity in the fork's
  thresholded class.
- **Port applicability: ~zero — likely already realised.** The chain records `vkc_mhc(SPLIT/COLLAPSE/
  POST)` inside the layer frame for any row count (`deepseek_v4_chain.h:949-963`), and decode runs
  through the chain on a discrete GPU (`backend_vulkan.c:2672-2696`). The remaining candidate is a
  *single-dispatch* mHC for S=1 (the fork's `mhc_dec_pre/post.comp`), justified by the fork's own
  finding that the prefill 3-dispatch chain at S=1 **regressed** 0.315 → 1.161 ms (`decode-…-review-
  2026-10-02.md:§1`).
- **Size:** ~200–400 lines of shader work + parity gate.
- **Risk:** low correctness risk, but **expected gain unmeasured on the port, plausibly a wash** — the
  exact class of lever `C-perf-evidence.md` §3 warns against (cadence folds inside an already-recorded
  submit measured −10.5 … +0.4 %).

### L6 — Flash attention (P3.3)
- **Fork evidence (MEASURED):** attention cell 5.0× @2k, 16.7× @8k; decode 2.1× @3k, 2.4× @8k
  (`C-perf-evidence.md` §2, `8a1ef885`).
- **Port applicability: medium** (shader-only; `chain_attn_flash` exists for other engines, V4's
  `chain_dsv4.comp` mode 0 is the target).
- **But:** attention is **2 %** of the fork's own per-op decode wall (10 ms/token, `:65`) and a similar
  sliver of a 2.5k prefill. The 5–17× wins are *long-context* wins.
- **Size:** ~400–800 lines + 1 bf16-ulp gate.
- **Verdict for this decision:** does not close the 90 s at 2,515 tokens; belongs to the 8k road.

### L7 (context, not on the ladder) — mm8/F8-class decode projections
`HANDOVER` §6 ranks this **#1 remaining decode item**, above the fold: "fork measured 4.73× on the
class; our decode = 1.6 s/token of device wait over ~760 f32-GEMV matmuls… Est: decode 0.65 → ~0.9–1.0.
Parity-class: write the F8 envelope language first; opt-in." It is **not** part of Option B and does not
depend on it. Any decision that treats the fold as *the* decode answer should be read against this line.

### L8 — Do nothing / stop at the campaign's best arms
The port's measured best operating points already exist as configuration, not code:
`194.9 s / 0.528` (slots 256 + gr4) and `201.3 s / 0.583` (balanced all-in), vs upstream 266/0.603
(`O-day2` §7, `HANDOVER` §2). This is the baseline every option must beat.

---

## 6. One-page decision matrix

Estimates assume the current port at `d1a2abba` (~230 s TTFT with mm8 / 0.61 decode; campaign best
194.9 / 0.528). "Gain" is against the 2026-10-22 campaign best, not against upstream.

| option | TTFT gain est | decode gain est | upstream-divergence cost | effort | confidence |
|---|---|---|---|---|---|
| **0. Do nothing** (keep the staged configs; ship the 6 PR slices) | 0 (194.9 s is already held by knobs; deployment balanced 201 s) | 0 (0.654 held by pool+promote; the 0.528/0.654 trade is a choice, not a gap) | **zero** — the queue is 6 narrow PRs, 4 already merge-clean (`PORT_STATUS.md:12-27`) | 0 | **HIGH** (MEASURED arms) |
| **1. Retention-only** (L1: per-layer window + route-aware dedup, no cell) | **+10 s (high conf.) to +40 s (low conf.)** off a 195–230 s base → 155–220 s; the "~60 s" reading requires re-measure (§2.4) | ~0 (prefill-side; decode unchanged on the fork's own split, `O-day2` §10) | **low**: `vk_tier.c` only; ~14 % of upstream commits touch it; generic story ("a layer's set at most once") | M: 1–2 wk, 400–800 lines, no shaders | **MED-HIGH** on mechanism (code-anchored), **MED** on magnitude, **LOW** on "no re-request" being sufficient (the 0-hit ring, §2.6) |
| **2. mHC-only** (L5) | ~0 | **~0 to +2 %** (chain already fuses mHC; only the S=1 single-dispatch remains) | low (`chain_mhc.comp` only) | S: 3–5 d | **MED** that it is a wash (a direct inference from `deepseek_v4_chain.h:949-963` + the fork's own S=1 regression record) — **cheapest thing to falsify** |
| **3. Retention + chain-MoE (L1+L2)** — the "fold capability without the fold stack" | **+25–60 s** (bytes + host-MoE wall 215.9 s → device; cf. 146 → 56 s at slots 192, `O-day2` §7) | **+? up to 1.5×** — the fold's 1.84× is device-resident *hot set*, which L2 gives only for layers whose experts are all on the device (a 167 GB model on 16 GiB: almost never) → realistically **0 to +15 %** | **medium**: `deepseek_v4_chain.h` + `vk_dmoe.h`; V4 joins a shared, actively developed path (their direction, but conflicts likely) | M–L: 3–5 wk, 700–1,600 lines, fmt 7 chain kernel | **MED** on TTFT (mechanism upstream's own), **LOW** on decode (needs the residency half too) |
| **4. Full Option B** (cell-pipeline dense fold + expert byte economy + bank) | **+90 s ⇒ 104 s class** *if* §11's attribution is right; **+40 s ⇒ ~155 s** if §10's retention reading is right and the fold is only dense-side (~38 s) | **1.84× ⇒ ~1.1 tok/s** *only together with* the fold's VRAM-resident hot set (L3), which the fold does not by itself provide on a 16 GiB card | **high**: `vk_chain.c` (26 % of the last 400 upstream commits), `deepseek_v4.c` (42 %), `vk_tier.c` (14 %); a 4.5–7k-line DSV4-only rewrite of shared files; upstream's direction is `vk_dmoe` + CUDA, and their accept rule is "narrow, single-topic" | XL: 5–8 wk, 4.5–7k lines, 1 new shader family, new oracle + golden gates (≈4.1 h/run) | **LOW-MED** on TTFT (three competing attributions, §2.3), **MED** on decode (the 1.84× is real but belongs to C6, not to the fold), **LOW** on merge cost staying bounded |
| **5. Staged** (1 → measure → 3 → measure → 4 only if the numbers demand it) | cumulative, each step gated on its own A/B (the campaign's own method) | same | grows monotonically with the steps taken; **stop-loss at every gate** | M now, optional later | **HIGH** — it is the only plan whose first step is falsifiable for <2 weeks of work |

**Cross-cutting facts the matrix cannot hold:**
- The three arms are *not additive* on this box: slots 256 buy TTFT and cost decode (0.528 vs 0.654); the
  pool buys decode and costs TTFT (246.5 vs 232); the budget must be rebalanced (201.3 / 0.583).
  Any option's "gain" must state which point on that frontier it is measured at.
- **Decode's biggest documented item is not on this ladder at all** (mm8/F8 decode projections, L7:
  est. 0.65 → 0.9–1.0 tok/s, `HANDOVER` §6.1). If decode is the priority (D6), it is the better first buy.
- **TTFT's remaining ~90 s** decomposes per `O-day2` §10 as **~60 s bytes/retention + ~38 s dense**, and
  per §7/§8 the expert tail is already "exhausted" at 194.9 s. The 68 GiB target is reachable only if
  §2.2's two mechanisms (per-layer dedup + cache-bypassing reads) are both reproduced; §2.6 says the
  port's first attempt at (part of) that measured 0 hits.

---

## 7. OPEN questions (what would settle each)

1. **Attribution of the 68 GiB** (§2.3) — needs one arm: the *port's* recording with a per-layer expert
   window; or the *fork* with its bank disabled. Neither exists. Cost: ~1 week, 1 arm each.
2. **Is the byte economy worth more than ~10 s post-slots?** (§2.4) — the "~60 s" figure predates the slot
   finding. Re-derive from the current arm's store counters before sizing effort.
3. **Does the fork's decode 1.16 survive without the *dense* fold?** The `DSV4_VK_EXPERTS=0` arm suggests
   yes (104 s TTFT / 0.61 decode) but the fold-OFF arm may also drop the GPU-MFU tier; if so, 0.61 already
   *is* the no-fold-fork decode, which is what §3.1 concludes — confirm from the arm's log
   (`bench/up2276/fork-noexperts-r1.log`).
4. **Port decode profile at 0.61** — the port has "1.6 s/token waiting on the device over ~760 f32-GEMV
   matmuls" (`O-day2` §6) but no per-op table like the fork's. Needed before any decode claim.
5. **Chain MoE for V4 (L2):** does fmt 7 fit `vkc_moe_rows`' item/amap/coop path, or is a new kernel
   needed? One microbench answers it.
6. **Merge-risk quantification:** how many of the next 30 upstream commits touch `vk_chain.c`? The last 31
   touched none; the last 400 touched 105. A single week of upstream traffic would bracket the estimate.

---

## 8. Files an implementer would open first

| purpose | file |
|---|---|
| the port's recording model (what a fold would rewrite) | `c/deepseek_v4_chain.h:1104-1436` (`v4c_forward_seg`), `:949-1090` (`v4c_pre/post/attention/shared/join`) |
| the port's op recorders / frame ring | `c/vk_chain.c:1-16` (contract), `:786` (`vkc_begin`), `:820` (`vkc_submit`), `:2459` (`vkc_moe`), `:2674` (`vkc_moe_rows`) |
| upstream's ready-made device MoE (L2) | `c/vk_dmoe.h:1-60` |
| the tier policy L1 would change | `c/vk_tier.c:1354-1358` (slot free), `:1426-1431` (reuse), `:2725-2740` (slots sizing) |
| the fork's byte-economy mechanism | `c/deepseek_v4.c:19273-19460` (bank create/refill/`read_bytes`) |
| the fork's cell join | `c/backend_vulkan.c:9004`; engine `c/deepseek_v4.c:20998` |
| the evidence ledger | `docs/research/O-day2-fork-gap-and-mx-gemm.md` §10–§11, `docs/HANDOVER-2026-10-22.md` §2/§4/§6 |
