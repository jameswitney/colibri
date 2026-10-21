# Code Context — upstream/dev target architecture for DeepSeek-V4 + Vulkan

Worktree: `/root/bench-worktrees/upstream-dev` @ `5d56c05a` (`v2.0.0-483-g5d56c05a`), clean.
Fork reference: `/root/Projects/colibri-ds4-vulkan` @ `d11fba5b` (no `vk_tier.c`/`vk_chain.c`; it ships its own `backend_vulkan_dsv4.c`).

## Files Retrieved

1. `c/deepseek_v4.c` (22047 lines) — amalgamated engine; one object per `COLI_V4_UNIT_*`
2. `c/Makefile.deepseek-v4.units` (1-34) — the unit list (`V4_TARGET_UNITS`, `V4_TEST_UNITS`, `V4_SEGMENT_UNIT`)
3. `c/Makefile.deepseek-v4` (215-400) — `VK=1` object/shader set, per-unit compile rule, flags stamps
4. `c/deepseek_v4_internal.h` (260-345, 740-830, 969-1090) — device-only dense placement, `ColiV4VkTier`, CUDA-tier and Vulkan-hook typedefs
5. `c/deepseek_v4_chain.h` (1-137, 939-960, 971-1335) — DSV4 on the dense chain (`v4c_*`)
6. `c/vk_tier.h` (1-345) — the routed-expert tier contract + integration recipe
7. `c/vk_chain.h` (1-130, 362-530) — chain recording model, ops, `vkc_dsv4_*`
8. `c/vk_dmoe.h` (1-45) — routed experts inside the frame (not used by DSV4)
9. `c/vk_kvsplit.h` (36-110, 247-260) — KV split past the device budget, `COLI_VK_KV_COLD`
10. `c/tier.h` (1-70) — the shared admission/promotion policy (LFRU, hysteresis)
11. `c/expert_store.h` / `c/expert_store_registry.h` — store vtable + `COLI_EXPERT_STORE` backend plug
12. `c/backend_vulkan.h` (1-400) — resident tensors, expert batch, `xb_*`, device2, arena caps
13. `c/vk_alloc.h` (1-30) — offset sub-allocator behind resident weight memory
14. `c/shaders/chain_dsv4.comp` (1-70), `c/shaders/qmatmul*.comp`, `c/shaders/chain_*.comp`
15. `docs/deepseek-v4.md` (1-556), `docs/vulkan.md` (85-100, 404-560, 1713-1812, 2339-2460, 3325-3345), `docs/ENVIRONMENT.md` (214-320)
16. `c/tests/vulkan_engines.sh`, `c/tests/test_vk_tier.c`, `c/tests/test_vk_chain.c`, `.github/workflows/ci.yml` (92-180)

## Key Code

### What runs where (V4), per path

Two independent Vulkan mechanisms exist, selected independently:

* **Per-op ("per-matrix") path** — engine calls a function pointer set at open:
  `ColiV4VkMatmul coli_v4_vk_matmul` (`deepseek_v4.c:20048`), wired in `v4_vk_open` (`deepseek_v4.c:13973`). Hooks live inside the quant units: `coli_fp8_matvec_ref` (`:20077`), `coli_fp8_matvec_pre` (`:20097`), the dual (`:20225`), the batch forms (`:20381`, `:20406`). Plus the tier: `v4_vkt_issue/join/note` (`:13560-13635`) wrapped in `g_v4_vkt` (`:13741`).
* **Device chain** — `deepseek_v4_chain.h`, included once by the GENERATE_STATS unit (`deepseek_v4.c:14560`), entered from `target_batch`/`target_token` (`:14620`, `:14727`) via `v4c_forward` (`deepseek_v4_chain.h:1293`).

| Stage | Per-op Vulkan path (default `COLI_VK_DENSE`) | Device chain (`COLI_VK_CHAIN=1`) |
|---|---|---|
| decode dense | resident fp8 dense matrices (fmt 12) + bf16 (fmt 11) via `coli_v4_vk_fp8`/`_matmul`; head `deepseek_v4.c:14143`; router `:10903` | all in frame A1 (`deepseek_v4_chain.h:30-44`) |
| decode attention | **CPU** (sparse/window ref); compressor projections on device `deepseek_v4.c:3734-3743` | device, `chain_dsv4.comp` mode 0 + `v4c_attention` (`deepseek_v4_chain.h:858`) |
| decode routed experts | tier `v4_vk_token_issue` (`:5484`) → `vkt_issue_w`, CPU share, `v4_vk_token_finish` (`:5517`), call at `:5674`/`:6020` | **host** step between frames: `coli_v4_moe_routed` (`deepseek_v4_chain.h:45`) |
| decode shared expert | CPU `coli_v4_shared_expert_forward_ref` (`:5731`) | device frame A2, `v4c_shared` (`deepseek_v4_chain.h:939`) |
| prefill dense | same hooks, batch forms `:20381`/`:20406`; compressor projections `:3160-3180` | frames A1 per chunk |
| prefill attention | **CPU** (indexer scoring and DSA selection are CUDA-only: `coli_v4_gpu_indexer_score_batch`) | device: compressor/indexer/top-k (`chain_dsv4.comp` modes 2-5) |
| prefill routed experts | tier `v4_vk_batch_issue` (`:6358`), union `v4_moe_batch_union` (`:6485`), finish `:6674`; streaming via `vkt_step_rows` | host step per layer (no `vk_dmoe.h` here) |
| head/argmax | head matmul on device (`:14143`), argmax on host (`head_scores_argmax`, `:14181`) | head on host (`docs/vulkan.md:1740`) |
| mHC | **CPU** (`:6802`, `:6825` are `COLI_V4_GPU_TIER`, i.e. CUDA-only) | device `chain_mhc.comp`, `vkc_mhc` (`vk_chain.h:362-365`) |

CUDA (§`COLI_V4_UNIT_GPU`, `deepseek_v4.c:11367-13157`) is a separate tier with its own names (`coli_v4_gpu_*`, `deepseek_v4_internal.h:969-1090`) and its own expert mirror in `ColiExpertStore.gpu` (`expert_store.h:88`).

### The tier contract (`vk_tier.h`)

```
vkt_init(&VktConfig, heat)   -> 0 = refused (no room / formats) ⇒ engine stays CPU-side
vkt_issue(layer, x, S, K, idx, taken)  -> returns at once; taken[] = device took it
vkt_join(rows)               -> one row per (s,k); engine adds in rank order
vkt_note / vkt_wants / vkt_report / vkt_plan+vkt_put (warm start)
vkt_stream_prefetch(layer,S) -> PILOT-like prediction for the next layer
vkt_dev_table / vkt_dev_count / vkt_epoch -> for experts-in-the-frame (vk_dmoe)
```
Sources are format descriptors (`VktSrc`, `vk_tier.h:160-172`), activation is `VKT_ACT_SWIGLU_V4` for V4 (`vk_tier.h:143-152`) — i.e. the CPU's exact bf16/E4M3 rounding sequence, which is why the engine hands in x already E4M3-rounded (`deepseek_v4.c:5461` `v4_vk_round_rows`).

### Extension seams

| Seam | Where | Notes |
|---|---|---|
| tensor upload / arena | `coli_vk_tensor_ensure` (`backend_vulkan.h:102`), tier pool `:221`, `vka_pool` (`vk_alloc.h:33-64`) | budget-limited best-fit; refusal = "tier is full" |
| chain buffers | `vkc_buf/reserve/ptr` + `VKC_DEV/UP/DOWN/HOST` (`vk_chain.h:47-62`) | sub-allocated from a few blocks |
| submit model | `vkc_begin/vkc_submit(wait)/vkc_finish`; `vkc_split_layers`+`vkc_layer_recorded` (`vk_chain.h:85-99`) | ring of frames, each its own fence/pool; one submission per layer |
| per-op submit | `coli_vk_matmul` submits and waits | 1 dispatch per matrix — the thing the chain exists to fix |
| engine units | `Makefile.deepseek-v4.units:2-34`; ifdef boundaries `deepseek_v4.c:15,596,1253,1444,1535,1820,2073,2579,3562,3906,4640,4708,7000,7424,7829,8377,10662,10859,10973,11367,13159,13224,17774,17877,17954,18046,18629,18935,19168,20109,20306` | GPU work must not be referenced from non-GPU units |
| chain vs per-op dispatch | `v4c_decide` (`deepseek_v4_chain.h:1360`), `coli_vk_chain_decide`; `v4_vk_open` (`deepseek_v4.c:13973`) | chain needs dense resident; declines per-op-incompatible configs |
| shaders / SPV | `Makefile.deepseek-v4:236-246` lists every `.spv`; rule `:324-326` `glslc --target-env=vulkan1.2`; committed `.spv` next to sources; found at runtime via `COLI_VK_SHADERS` | a new op = new `.comp` + `.spv` + add to `V4_VK_SPV` + a `vkc_*` wrapper + `test_vk_chain.c` case |
| env knobs | no registry: `getenv` in the owning unit (`backend_vulkan.c` has 48) + a row in `docs/ENVIRONMENT.md` | `COLI_VK_*` for the backend/tier, `V4_*`/`DSV4_*` for the engine |

## Architecture

```
colibri/coli (CLI, colibri.c)  ──► deepseek_v4.h API ──► deepseek_v4.c (30 units)
                                                          │
                    ┌─────────────────────────────────────┼───────────────────────────┐
                    │ per-op hooks (native_quant units)    │ GENERATE_STATS unit       │
                    │  coli_v4_vk_matmul / _fp8 / _host    │  v4c_forward / v4c_start  │
                    ▼                                      ▼                           ▼
            backend_vulkan.c (device, memory, tensors)   deepseek_v4_chain.h ──► vk_chain.c (+ vk_alloc.h)
                    ▲                                      │  frames A1/A2             │
                    │                                      └──► vk_tier.c (vkt_*) ◄─────┘ (dev_table, count)
             vk_tier.c (expert cache; vk_alloc pools; second queue; COLI_VK_DEV2)
                    ▲
             expert_store.h vtable ◄── expert_store_registry.c (COLI_EXPERT_STORE=auto|…)
```

Control flow for a forward: `target_batch`/`target_token` produce `hc_mult` residual streams and call `coli_v4_attention_window_batch_ref` (CPU) or the chain; MoE goes through `moe_token_pipeline` / `v4_moe_batch_union`, which fan out to `vkt_issue` (Vulkan) or `coli_v4_gpu_moe_batch_union` (CUDA bank) and fall back to `coli_v4_expert_forward_ref`. Every device call returns `0` on refusal and the CPU reference runs — there is no "assert", degradation is silent by design.

**Prefill scheduling**: `V4_PREFILL_SEGMENT` (4096, atomic, cancel boundary) at `deepseek_v4.c:15729`, chunk `V4_PREFILL_CHUNK` (128) inside `target_batch`; chain chunk from `COLI_VK_CHAIN_ROWS` (`v4c_chunk_rows`, `deepseek_v4_chain.h:694`).

**Q3 — capabilities already upstream under other names**

| Capability | Upstream equivalent | Cite |
|---|---|---|
| VRAM expert LRU/tier | `vk_tier.c` + `tier.h` (LFRU = heat<<8 \| recency-255) | `tier.h:40-57` |
| MFU/MRU popularity ranking | heat table from `.coli_usage` (`route_trace.h`), `tier_pick_lfru`, `COLI_VK_TIER_RATE` (16/token), `COLI_VK_TIER_FILL` warm fill | `tier.h:39-68`, `docs/ENVIRONMENT.md:248-251` |
| disk cold-KV tier | host/device KV split `vk_kvsplit.h` + `COLI_VK_KV_COLD=device`; prefix snapshots to `<model>/.coli_ckpt` (`V4_PREFIX_CKPT_DISK`) | `vk_kvsplit.h:36,247`; `docs/deepseek-v4.md:270-276` |
| prefill chunk/segment scheduling | `V4_PREFILL_SEGMENT`/`CHUNK`, `vkt_step_rows`, `COLI_VK_CHAIN_ROWS` | `deepseek_v4.c:15729`; `vk_tier.h:245` |
| submit merging / cmd-buffer batching | chain frames + `vkc_split_layers`/`vkc_layer_recorded`; tier's own queue (`COLI_VK_TIER_QUEUE`); `xb_step` one batched submit | `vk_chain.h:85-99`; `vk_tier.h:83-97` |
| async expert prefetch (PILOT-like) | `vkt_stream_prefetch(layer,S)` (previous big step's routing), tier streaming (`COLI_VK_TIER_STREAM*`), `COLI_CUDA_MOE_DOUBLE`, `COLI_V4_PREWARM` | `vk_tier.h:250-253`; `docs/deepseek-v4.md:290` |
| per-layer MoE batching | `vkt_issue` per layer (one submit), `V4_EXPERT_UNION`, grouped GEMM/GEMV (`COLI_VK_XB_GROUPED`, `_GEMV`) | `vk_tier.h:83-97`; `docs/ENVIRONMENT.md:255-258` |
| e4m3/fp8 decode | fmt 12 (e4m3 per 128 block), fmt 13 (int8 grouped), fp8 experts fmt 12 — decode is a LUT, not fp8 MMA | `shaders/qmatmul.comp:59-126`; `docs/vulkan.md:219-221` |
| mHC device residency | `chain_mhc.comp` + `vkc_mhc` (chain only; per-op path keeps mixes on host) | `vk_chain.h:362-365` |
| DSA/indexer on GPU | `chain_dsv4.comp` modes 3-5 (`vkc_dsv4_score/cand/topk`); CUDA `coli_v4_gpu_indexer_score_batch` | `vk_chain.h:517-530` |
| multi-slot KV (kv-slots) | `KV_SLOTS` 1..16 (`deepseek_v4.c:17228`), tier serves the batched rows; chain mux (`COLI_VK_CHAIN_MUX`) exists for GLM only | `deepseek_v4.c:6908,16244`; `glm_chain.h:788-795` |

**Gaps (no upstream equivalent)**: attention on the device *without* the chain (per-op Vulkan leaves attention on the CPU); experts-inside-the-frame for V4 (`vk_dmoe` is included only by olmoe/qwen36/qwen38 chain headers); a disk KV tier as system of record; strict-fatal capability degradation.

## Start Here

`c/vk_tier.h:1-150` — it is simultaneously the tier's API and its integration contract; then `c/deepseek_v4_chain.h:1-90` for what "the chain" actually records.

## Build / validation on this host

Host: 18 cores, 38 GB RAM, AMD RX 6900 XT (RADV NAVI21, Mesa 26.2.1), `glslc` present, `cooperative_matrix` **absent**; BDA, `VK_EXT_memory_budget/priority/external_memory_host`, `VK_EXT_subgroup_size_control`, subgroup arithmetic+clustered, `shaderFloat64` present. ⇒ coop GEMM (`qmatmul_coop`, `chain_gemm`), grouped expert GEMM (`COLI_VK_XB_GROUPED`) are off here; fp32 GEMM/GEMV and `vkc_moe` (BDA + clustered) are available.

```bash
cd c
make deepseek-v4                                   # CPU engine (Makefile:821)
make deepseek-v4 VK=1                              # + backend_vulkan.o, vk_tier.o, vk_chain.o, all .spv
make deepseek-v4-tiny-check                        # generates c/deepseek_v4_tiny, runs the torch oracle (Makefile:831)
make deepseek-v4-oracle MODEL=/path MEMORY_GB=32   # real checkpoint only (Makefile:844)
make vk-tier-check VK=1 && make vk-chain-check VK=1   # Makefile:2338,2348 (needs a device)
make tests/test_deepseek_v4 && ./tests/test_deepseek_v4   # C unit tests (Makefile:2648)
bash tests/vulkan_engines.sh deepseek | deepseek-sanitize | deepseek-chain | prefill-deepseek | kv-split-deepseek | mux-deepseek | dev2-deepseek-kimi-mimo
```
`COLI_VULKAN=1` at run time; `VK_ICD_FILENAMES` points at Lavapipe in CI. Gated on a real checkpoint: `deepseek-v4-oracle`, and any perf claim (tiny fixtures are correctness-only). Shaders assume: Vulkan 1.2 + subgroup arithmetic (hard), fp32 arithmetic only (no fp64, no native fp8 MMA — both emulated), optional coopmat 16x16x16 f16→f32, BDA, subgroup-size control, memory budget/priority, external-memory-host. No `fmad`/fast-math requirement; correct results depend on the roundings the shaders spell out.

## Do NOT port / already superseded

| Fork asset | Superseded by | Why |
|---|---|---|
| `backend_vulkan_dsv4.c/.h` (5433 lines, DSV4-private device layer) | `backend_vulkan.c` + `vk_tier.c` + `vk_chain.c` (+ `vk_alloc.h`) | A second device layer would bypass the arena, staged uploads, dev2, partial chain, and every other engine's fixes (#1901, #1933, #1948) |
| "MFU/MRU" VRAM cache (`cache_engine.h`, `cache_reorder.c`, `COLI_DSV4_VK_MFU_*`) | `tier.h` LFRU + `vk_tier.c` heat/rate/fill/exclusive | Same policy, already shared by 9 engines and tested (`test_vk_tier.c`) |
| `COLI_DSV4_VK_PILOT_*` async prefetch | `vkt_stream_prefetch` + `COLI_VK_TIER_STREAM*` | Upstream predicts from the previous big step's routing and streams into staging slots |
| GPU-FOLD fused composition | the dense chain (`vk_chain.c`, `deepseek_v4_chain.h`) | The chain *is* the fold: one frame per layer, streams resident, roundings hoisted |
| decode-mHC-chain machinery, compressor-FOLD/RESIDENT (fork deleted both) | `chain_mhc.comp` / `vkc_dsv4_compress` | Already re-expressed as chain ops |
| submit-merge / cell-tail merge (`PLAN_submit_merge`, `COLI_DSV4_VK_CELL_TAIL`, `QUEUE_AHEAD`) | `vkc_split_layers` + `vkc_layer_recorded`, tier's second queue, `xb_step` | Upstream splits a long frame every N layers instead of merging cells |
| disk cold-KV tier (`19764dd0`) | `vk_kvsplit.h` + `V4_PREFIX_CKPT_DISK` | Host-side rows + persistent prefix snapshots already cover "KV past the budget" |
| CUDA DLL ABI handshake (`94262d96`) | `COLI_DSV4_DLL` + `dsv4_cuda_backend_arch_ok` | Loader already refuses a wrong/absent DLL loudly |
| prompt-sized VRAM admission (`e834da31`) | `COLI_VK_TIER_GB` + `coli_vk_free_bytes` + `dense_host_decide` + `coli plan` | Budget accounting lives in the backend |
| `COLI_VK_STRICT` strict-fatal degradations | — (genuinely new) | Upstream degrades silently per op; porting it changes failure semantics for every engine |
