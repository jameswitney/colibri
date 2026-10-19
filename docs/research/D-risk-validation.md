# D — Portability, Risk & Validation Strategy: fork → fresh fork of upstream/dev

Static analysis only. Fork = `/root/Projects/colibri-ds4-vulkan` (READ-ONLY, WIP present), target = `/root/bench-worktrees/upstream-dev` @ `5d56c05a` (READ-ONLY). Merge-base `dd7df2c9`.

*Output-path override: the brief's deliverable path is superseded by the run-authoritative artifacts path; this file is the complete artifact.*

---

## 1. Divergence map

| | commits | files | insertions | deletions |
|---|---:|---:|---:|---:|
| fork | 356 | 318 | +124,595 | −3,653 |
| upstream/dev | **2,399** | 864 (690 A, 173 M, 1 D) | +320,208 | −5,571 |

> UNCERTAIN: brief says "upstream +1919"; `git rev-list --count dd7df2c9..5d56c05a` gives **2399**. Conclusions use 2399.

### Shared hot files (`git diff --numstat dd7df2c9 <rev> -- <f>`)

| file | base | fork | up | fork ± | up ± |
|---|---:|---:|---:|---:|---:|
| `c/deepseek_v4.c` | 17,017 | 30,154 | 22,047 | **+15,354 / −2,217** | +5,568 / −538 |
| `c/deepseek_v4_internal.h` | 998 | 2,196 | 1,249 | +1,216 / −18 | +251 / −0 |
| `c/backend_vulkan.h` | 134 | 1,581 | 508 | +1,448 / −1 | +375 / −1 |
| `c/backend_vulkan.c` | 2,166 | **18,237** | 7,144 | **+16,382 / −311** | +5,321 / −343 |
| `c/backend_cuda_dsv4.h` | 234 | 878 | 238 | +653 / −9 | +4 / −0 |
| `c/Makefile.deepseek-v4` | 281 | 1,422 | 393 | +1,164 / −23 | +130 / −18 |
| `c/dsv4.def` | 82 | 84 | 82 | +2 / −0 | 0 |

Each side also added **disjoint new files**: fork `c/backend_vulkan_dsv4.{c,h}` (5,433 + 71, new); upstream `c/vk_tier.{c,h}`, `c/vk_chain.{c,h}`, `c/vk_alloc.h`, `c/vk_load.h`, `c/vk_dmoe.h`, `c/vk_kvsplit.h`, `c/backend_xdna.{c,h}`, `c/deepseek_v41.c`, `c/decide_vk.h`, `c/segment_runtime.{c,h}`, `c/ggml_view.h`, `c/fp8_format.h` and ~680 others.

### Blocks both sides changed

Identifiers from `git diff -U0` hunk headers of `c/deepseek_v4.c`: fork touches 136 functions, upstream 109, **49 touched by both** — `attention_token_impl`, `block_token_impl`, `block_token_pipeline`, `build_runtime_plan`, `target_batch`, `target_token`, `moe_token`, `moe_token_pipeline`, `head_argmax`, `main`, `prefetch`, `coli_v4_engine_open`, `coli_v4_layer_load`, `coli_v4_session_{destroy,generate}`, `coli_v4_serve_{main,one}`, `coli_fp8_{matvec_pre,matvec_ref,dual_matvec_ref,matmul_batch_ref,matmul_batch_pre}`, `coli_fp4_{matvec_ref,dual_matvec_ref}`, `coli_v4_{route_bf16,hc_post,indexer_select_batch,attention_window_batch_ref,block_window_batch_ref}`, `compressor_pool_and_emit`, `fp8_view`, plus the whole `coli_v4_expert_store_*`, `v4_ckpt_*`, `v4_gpu_expert_*`, `hot_*`, `profiled_expert_load_*` families — exactly where each side inserted tier hooks.

---

## 2. Structural drift

**The brief's premise is wrong, and that is good news.** Upstream is *also* an amalgamated per-unit build: `c/Makefile.deepseek-v4.units` exists upstream and differs from the fork's by one trailing line, `V4_SEGMENT_UNIT = COLI_V4_UNIT_SEGMENT_ADAPTER`. Both `c/deepseek_v4.c` carry the same `#ifdef COLI_V4_UNIT_*` structure (fork 33 units, upstream 34). The unit build model ports for free.

Real drift:

| axis | upstream/dev | fork | port effect |
|---|---|---|---|
| Vulkan backend files | `backend_vulkan.c` (7,144) + `vk_tier.c` (2,123) + `vk_chain.c` (162 KB) + `vk_alloc/vk_load/vk_kvsplit/vk_dmoe.h` | `backend_vulkan.c` (18,237) + `backend_vulkan_dsv4.c` (5,433) | fork's 16,382 added lines land in a file upstream also rewrote (+5,321/−343) |
| fn identity in `backend_vulkan.c` | 333 top-level fns | 371 fns | **only 68 shared names**, 265 upstream-only — two different programs sharing a prefix |
| dsv4 GPU entry | `vk_tier`/`vk_chain` recording chain (`vkc_*`), driven by `deepseek_v41.c`/`decide_vk.h`; `deepseek_v4.c` uses `v4_vk_tier_start/_report` + fn-pointer hooks (`coli_v4_dense_place`, `coli_v4_dense_device_lost`, `coli_v4_expert_store_ram_first`) | `dsv4_cuda_*` same-named ABI over `backend_vulkan_dsv4.c`, reached via `#include "backend_vulkan_dsv4.h"` | **two parallel Vulkan stacks, incompatible ownership** |
| engine ifdef density | 48 × `COLI_V4_GPU_TIER` | **217**, of which 115 `_VK` | every GPU-touching hunk conflicts |
| `dsv4_cuda_` call sites in engine | 143 | **307** | 164 sites to re-establish |
| `COLI_V4_UNIT_GPU` block | absent (no GPU unit in the engine) | lines **15051–22803 = 7,752 lines** | the fork's whole engine-side tier |
| VK make targets | 0 (15 target lines total) | 40 in `VK_L2_TARGETS`; `Makefile` 1,422 lines | whole harness re-lands |
| shader tree | 97 files (`chain_*`, `qmatmul_coop`) | 113 files (`mhc_*`, `glue*`, `dec_*`, `idx*`, `qmatmul_pf4_*`, `sparse_attn*`) | §5 |

**Where a mechanical port breaks**

1. `c/shaders/qmatmul.comp` — both trees own the name, with different push-constant structs and `fmt` tables (§4). A copy silently reinterprets `fmt`, `scale[]` width and drops `woff`/`soff`, compiling cleanly.
2. `c/shaders/{attention_absorb,qmatmul_gate_up,rmsnorm}.comp` — same name, different implementation.
3. `c/backend_vulkan.c` — 68/371 shared names: a 3-way merge yields a file that compiles and misbehaves, and the 265 upstream-only functions are *missing symbols* for upstream's other engines (`colibri.c`, `kimi_k3.c`, `qwen3*.c`, `glm53.c`, `laya.c`, `gliner_decide.c`).
4. Include sets diverge: upstream's engine includes six headers the fork's does not (`deepseek_v4_chain.h`, `vk_tier.h`, `ggml_view.h`, `segment_adapters.h`, `own_file.h`, `cpu_check.h`); four fork includes are absent upstream (`backend_vulkan_dsv4.h`, `cache_engine.h`, `cache_reorder.h`, `deepseek_v4_ram_prefetch.h`).

---

## 3. ABI / API drift

### `dsv4_cuda_*` surface — fork 161 declared, upstream 82

| direction | symbols |
|---|---|
| upstream only (**guaranteed undefined ref**) | `dsv4_cuda_device_unified`, `dsv4_cuda_expert_bank_upload_aux` |
| fork only (80) | `_abi_version`, `_tensor_shape`, `_expert_tensor_slab`, `_cell_{prologue,tail,join}_*`, `_compscan_*`, `_dec2_qkv*`, `_ffn_opener*`, `_glue2/3_*`, `_idx*`, `_kv_*_resident`, `_matmul_{bf16_pair,batch_norm}`, `_mhc_*_cell_*`, `_qkv_pre/_post`, `_route_top6_batch_fixed`, `_wo_fused`, `_expert_bank_em*`, `_expert_group_tail` |
| renamed | **none** — the fork kept upstream names byte-for-byte (its `backend_vulkan_dsv4.h` records that a `-D` rename and a forked prototype list were both rejected) |
| signature change | `COLI_DSV4_ABI_VERSION 2` exists only in the fork (covers `mhc_post_batch`/`_post_pre_norm_batch` taking explicit `hc`); upstream has no version symbol |

`c/dsv4.def` is the cleanest artifact: fork = upstream **+2 lines** (`dsv4_cuda_abi_version`, `dsv4_cuda_route_top6_batch_fixed`). But it exports 83 while the header declares 161 — **~78 declared symbols are not exported**. The fork's `.cu` defines 118 `extern "C"` entries (VK extras stubbed to refusal), so ELF builds link; a Windows DLL build of the wider ABI would not. P1 decision: real ABI vs `#ifdef COLI_V4_GPU_TIER_VK`-internal.

### `deepseek_v4_internal.h` (+251 upstream, +1,216 fork)

Upstream added, none in the fork: `#define ST_GGUF` + `ggml_view.h` (checkpoint readable as GGUF in place: `coli_v4_ggml_view`, `coli_v4_gguf_held_type`, `coli_v4_index_gguf`); `unsigned char convert` on `ColiDeepSeekV4TensorSpec`; `mapped[]`/`host_gone[]` on the layer struct (device-only dense weights, host pages returned); fn-pointer seams `coli_v4_dense_place`, `coli_v4_dense_device_lost`, `coli_v4_dense_reread`, `coli_v4_expert_store_ram_first/_gave`; `coli_v4_route_bf16`, `coli_v4_layer_host_drop/restore`, `coli_v4_expert_store_prewarm`, `coli_deepseek_v4_expert_store_open_base`, `skip_mirror_setup`.

Fork added `ColiV4ExpertRawView` and the `V4GpuExpertMirrorCache` test-hook surface (`coli_v4_test_expert_mirrors_create/_attach/_peek/_release/_lease/_count/_capacity`) — which the L2 mirror-refs suite links, so it is contract, not decoration.

### Ownership invariants a port must satisfy

1. **Refusal ≠ failure.** Refusal (`return 0`) leaves the backend ready and the CPU op runs byte-identically; a real driver failure clears ready and aborts non-zero naming the op. Upstream's model is the opposite (§6).
2. **GPU never owns state.** CPU ring writes always happen; on failure the slot is poisoned (`deepseek_v4.c:2143–2176` at base), so an engine-level divergence implicates GPU math only.
3. **Mirror leases.** attach/peek take a lease; compute releases; recycling skips leased entries; all-leased ⇒ refusal, never eviction.
4. **`COLI_DSV4_ABI_VERSION`** handshake on every backend exporting the ABI.
5. **VK=1 is mandatory-tier** (`COLI_V4_VK_ONLY`): missing ICD or unreadable `COLI_VK_SHADERS` aborts at open. Upstream keeps Vulkan optional and self-disabling.

---

## 4. Numerics / codegen contract

`qmatmul.comp` is the most dangerous file (223 diff lines):

| item | fork | upstream | conflict |
|---|---|---|---|
| fp8 e4m3 id | **8** — raw e4m3, one f32 scale per **128×128 block**, `scale[]` is `uint` (4 packed E8M0/word) | **12** — "fp8-e4m3 grouped", per-row `float scale[]` | same dtype, different scale layout **and binding type** |
| f32 | **0** | **10** | collides on every `fmt` switch |
| bf16 | **16** | **11** | idem |
| f16 | absent | **14** | upstream-only |
| extra ids | `99` | `112`, `113`, `202`, `203` | disjoint |
| push constants | adds `int woff; int soff;` (grouped `wo_a` slicing) | absent | **shader binary ABI** |
| E4M3 decode | arithmetic; bit-identical to the 256-entry LUT, but a LUT gather measured ~1.5 GB/s vs 265+ GB/s on RADV | arithmetic, same math | re-prove |
| fp64 | **removed** — fmt=8 accumulates fp32 like fmt=10; the old "fp64 per-lane + fp64 subgroupAdd" matching the CPU's fp64-across-blocks order is gone | n/a | the 18→21-token envelope was measured across this history; porting a shader from upstream silently drops it |
| bf16 rounding | round-at-storage-only, at exactly the CPU's points (24 shaders: `bf16r`, `glue1/2/3`, `glue_qn_rope`, `dec_*`, `mhc_*`, `comp_scan*`, `idx*`) | same contract, `chain_dsv4` mode 7/mode 8 | two implementations of one contract |
| denormal flush | RADV fp32 subnormals flushed; accepted benign because flushed values < 1e-30 die under the phase-2 QDQ 1e-4 block floor | n/a | **host-specific waiver**, re-measure per ICD |
| bitwise gates | only same-computation pairs (recorded segment vs per-op dispatch, S-invariance, byte/decimal load parity, exact decode tables) | — | envelope for all different-order comparisons |

**Pairs needing re-proof** (distinct obligations): `qmatmul[f=8]` + upload E8M0 expansion; `qdq`/`qdq_id` (incl. the `_pre` hoist); `qdq_gather`/`qmatmul_pf4*`; `moe_swiglu`+`moe_merge` and upstream's `expert_act`/`expert_sum`; `glue1/2/3`, `glue_qn_rope`; `dec_fin/dec_qa/dec_rows`; `comp_scan*`; `idx*`; `mhc_*` sinkhorn chain; `kv_ring_append`; `sparse_attn*`; `attention_absorb`; `wo_gather`/`wo_in_gather`; `rmsnorm`; `bf16r`.

**Evidence re-recording — all of it.** The golden harness's upstream leg is `.golden/upstream`, a git worktree of the fork repo pinned at `dd7df2c9` (the old merge base); `.golden/cache/` holds one 61 KB dir keyed by that SHA. Re-pinning to `5d56c05a` invalidates every artifact. Measured cost (2026-09-16): 41.0 min per long-prompt leg, **full gate ≈ 4.1 h** uncached, 41.8 min `--record-only --pinned-only`. The **split contract** must be re-adopted: oracle leg = CPU parity only (it calls `target_batch(NULL,…)`, so every GPU op refuses and the leg is effectively CPU); GPU parity comes from the serve-arm cell-hash A/B (`scripts/vk_prefill_cell_ab.sh`, `COLI_V4_CELL_HASH`) — the gate that caught #40, which the oracle missed.

---

## 5. Shader / toolchain

| | upstream | fork |
|---|---|---|
| files | 97 | 113 |
| names shared | 5: `qmatmul.comp/.spv`, `attention_absorb.comp`, `qmatmul_gate_up.comp`, `rmsnorm.comp` | |
| `.spv` policy | committed; `glslc --target-env=vulkan1.2`; `qmatmul_coop.spv` has an explicit *keep the committed bytes if glslc can't compile it* fallback | committed, same rule, plus 8 documented per-file recipes that must reproduce byte-identically (`glue1` v1.2, `glue2` plain, `glue3` plain+`spirv-opt -O --strip-debug`, `comp_scan`, `idxprep`, `idxsel` plain, `wo_gather`/`wo_in_gather` v1.2); no coop variant at all |
| glslc version | not pinned (`GLSLC ?= glslc`) | not pinned |
| pipeline cache | **no `VkPipelineCache`**; command buffers cached in `G.cmd`, re-recorded when `bound_S/I/O/gemm` change | same pattern |
| coopmat | `qmatmul_coop.comp` when `VK_KHR_cooperative_matrix` (`path == 2`) | absent — gfx1030 has none, subgroup 64 |
| fp8 ALU | none; e4m3 in ALU (`fmt=12`) | none; e4m3 in ALU (`fmt=8`) |
| fp64 in SPIR-V | none in `chain_dsv4.comp`; fp16x2 only | none; fp64 cross-block is on the host |

**Coexistence hazard**: 3 `.comp` names claim incompatible push constants and `fmt` numbering, and each tree ships its own `qmatmul.spv` — whichever `.spv` is committed, one backend misinterprets it at runtime with **no compile error**. Fix requires namespace separation + one `fmt` table + a build-time assertion that the loaded SPIR-V's push-constant size matches `sizeof(struct P)`.

---

## 6. Environment / config

| | upstream | fork |
|---|---:|---:|
| distinct `COLI_*` in `c/*.[ch]` | 611 | 391 |
| shared / fork-only | — | 234 / **157** |
| "registry" | none in code — `docs/ENVIRONMENT.md` is generated by scanning every `getenv()` site (baseline `dev @ def8419`); no dumper, no strict mode | same model **plus** `scripts/env_doc_drift.sh` (+ `--check`) over the `COLI_DSV4_VK_*`/`COLI_VK_*`/`COLI_V4_*`/`V4_*`/`DSV4_*` namespace with a 46-entry allow list |

- **Collisions**: 234 shared names; semantic equality is *not* statically verified (UNCERTAIN). Gate = `env_doc_drift.sh --check` plus a per-name diff of the `ENVIRONMENT.md` sections.
- **Removed levers still documented**: the 2026-10-11 GPU-FOLD change made 19 `COLI_DSV4_VK_*`/`COLI_VK_MHC_*` composition knobs silent no-ops (`_DEC2*`, `_FFN_OPENER_*`, `_FFN_TAIL_DEC`, `_COMP_{DECODE,SCAN_DEC,FOLD_DEC,RESIDENT}`, `_SHARED_DEFER`, `_MHC_CELL_DEC`, `_ATTN_CELL_DEC`, `_FUSED_DENSE`, `_BANK_{ID,PAIR}`, `_BOOT_PREFILL`, `COLI_VK_MHC_{PREFUSED,DECODE}` — full list in `TEST.md` §6). A port must not resurrect them as documented levers.
- **Strict-fatal vs refusal — incompatible contracts.** Fork: `COLI_VK_STRICT=1` (`backend_vulkan.c:2366,2382,17138`) upgrades capability degradation from observe-only to FATAL, and a `VK=1` build is mandatory-tier so boot failure aborts. Upstream: `[VK] fence wait failed: %d — disabling GPU offload, staying on CPU` / `G.ready = 0; return 0` (`backend_vulkan.c:2368–2374`), and Vulkan is compiled out entirely without `COLI_VULKAN` in most engines. Both cannot be true in one binary.

---

## 7. Integration strategy scoring

1 (worst) – 5 (best).

| option | effort | risk | reviewability | upstreamability | maint. | total |
|---|---:|---:|---:|---:|---:|---:|
| **(a)** fresh branch off `upstream/dev`, port slice-by-slice as PRs | 3 | 4 | **5** | 4 | **5** | **21** |
| (b) port modules only, reimplement engine seams | 2 | 3 | 4 | 3 | 3 | 15 |
| (c) rebase the fork onto `upstream/dev`, drop superseded code | **1** | **1** | 1 | 1 | 2 | 6 |
| (d) maintain the fork as a patch series | 3 | 2 | 2 | 2 | 2 | 11 |

**Why (c) fails arithmetically**: 356 commits onto +2,399, 49 doubly-changed functions, 217 vs 48 `GPU_TIER` sites, a 16k-line addition into a file where only 68/371 function names survive, 3 shader names with incompatible ABIs. The rebase does not conflict — it produces a binary.

**Recommendation: (a), shim-first.** (b) is what (a) degrades to for engine glue, so it is not a separate strategy; (d) is (a) with worse tooling and no per-slice gate.

| phase | scope | exit gate |
|---|---|---|
| **P0 — namespace & pin** (1–2 wk, no features) | rename fork shaders to a `dsv4_` prefix; one shared `qmatmul.comp` with one `fmt` table; re-pin `.golden/upstream` to `5d56c05a` and re-record; land `env_doc_drift.sh` + `vk_l2_targets_check.sh` | L0 parity green; `.golden` re-recorded once; no double-claimed shader name |
| **P1 — seam** | `backend_cuda_dsv4.h` deltas (add 2 upstream symbols; keep the fork's 80 behind `#ifdef COLI_V4_GPU_TIER_VK` + `.cu` refusal stubs); `dsv4.def`/`COLI_DSV4_ABI_VERSION`; guarded include swap in `deepseek_v4.c` | `nm` shows zero undefined `dsv4_cuda_*`/`ds4vk_*`; an injected new upstream call fails the link loudly |
| **P2 — primitives** | `qmatmul` fmt=8 + E8M0 expansion + activation QDQ + `ds4vk_fp8_ref_matmul` | L1 green; expansion and QDQ bitwise |
| **P3 — decode ops** | qkv/wo/route/head/mhc/kv_ring/attention/indexer | L2 decode suites green vs the *upstream* CPU functions |
| **P4 — prefill/batch** | cell prologue/tail/join, comp_scan, glue1-3, dec2, ffn opener/tail, expert bank + pf4/i8/mm8 | L2 batch suites green |
| **P5 — engine seams** | the 164 extra `dsv4_cuda_*` sites, `V4GpuExpertMirrorCache`, store/prefetch hooks, coalesced with upstream's `coli_v4_dense_*`/`expert_store_*` hooks | L3 tiny oracle token-identical ×3 legs; cell-hash A/B green |
| **P6 — evidence & perf** | golden re-record, stage-oracle bundles, L5 A/B | full gate ≤ ~4.1 h, green |

Each phase is one PR carrying its own L0 gate, so an abandoned phase leaves a green tree.

---

## 8. Validation matrix

| layer | what | pass/fail | needs 167 GB ckpt |
|---|---|---|---|
| **L0a** build parity | `make -C c check`, `test-c`, `make -f Makefile.deepseek-v4 deepseek-v4` (VK=0) | exit 0; compile-flag diff vs upstream **empty**; identical output stream | no |
| **L0b** exclusivity | `VK=1 CUDA=1` | **must fail** with a clear Makefile error (never silent VK-wins) | no |
| **L0c** seam | `nm` over the VK=1 binary | zero undefined `dsv4_cuda_*`/`ds4vk_*`; injected call ⇒ link error | no |
| **L0d** boot parity | validation prompt, tier vs VK=0 | byte-identical output; tier reported | no |
| **L1** primitives | `test-vk-dsv4`: fmt=8 matmul + E8M0 expansion + QDQ + ref matmul | expansion & QDQ **exact**; production matmul within the CUDA envelope (global maxabs/maxref ≤ 1e-2; floor-maxrel 1e-5…1e-2 on cancellation rows); no NaN leakage (`nn_byte()`) | no |
| **L2** per-op | all 40 `VK_L2_TARGETS` via `test-vk-all`; `verify-vk-l2-targets` first | every suite green; limits from `tests/vk_envelope.h` (dense batch abs 1e-2, attention 1e-3, sparse 2e-3, decode rel 5e-2, grouped 1e-2, pf4 rel-L2 1e-2, router rel 1e-4, aggregate 1e-3, mHC 1e-5) | no |
| **L3a** tiny oracle | `deepseek-v4-tiny-check` ×3 legs | token-exact 16/16 | no |
| **L3b** e2e reasonableness | `check-e2e-reasonableness VK=1` | every completion non-degenerate; no all-zero, hard-recovery or GPU-failure marker | **yes** |
| **L3c** golden | `scripts/vk_golden_parity.sh` (pinned pass = hard gate) | greedy output byte-identical within a config; envelope 16 tokens (21 long-prompt) | **yes** |
| **L3d** GPU-vs-CPU | `scripts/vk_prefill_cell_ab.sh` (`COLI_V4_CELL_HASH`, periodically `CPU_BASELINE=1`) | cell hashes equal on every layer × token | **yes** |
| **L4** failure | `test_dsv4_vk_boot_degrade.py` with `COLI_VK_SHADERS` → a dir without `.spv` | aborts **non-zero** with the mandatory-tier message; session never runs | no |
| **L5** perf | `bench/benchmark.py`, 8 interleaved runs, `power_dpm_force_performance_level=high`, cpuset/OMP disclosed | no regression vs the recorded baseline on TTFT + prefill tok/s; decode secondary | **yes** |
| **L6** hygiene | `env_doc_drift.sh --check`, `vk_l2_targets_check.sh`, `.spv` recipe reproduction | exit 0 each | no |

### Gates for the known failure classes

| class | gate | signal |
|---|---|---|
| shader compile / wrong `.spv` | L0d + push-constant-size assertion + `.spv` byte-reproduction check | silent 0-refusal or garbage logits; boot abort |
| CPU-fallback divergence | L2 with `COLI_DSV4_VK_OPS=<one group>` flipped vs all-CPU | any text diff |
| `--oracle` leg silently CPU (#19 trap) | assert the GPU leg's log shows `moe-batch=on` / non-zero allocs; fail otherwise | gate passes vacuously |
| cache corruption / stale `.coli_kv` | L3c warm-start replay A/B; one warm-cache A/B (REVIEW A2) | divergent text on resume |
| VRAM wedge / TDR | L2 mirror-refs (all-leased refusal, evict-during-compute), L4, bounded fence wait | non-zero exit naming the op; never a silent CPU slide |

**Minimum set without the checkpoint**: `make -C c check` → `test-c` → `make -f Makefile.deepseek-v4 test-vk-all VK=1` → `deepseek-v4-tiny-check` (3 legs) → `deepseek-v4-vk-boot-degrade` → `env_doc_drift.sh --check` → `vk_l2_targets_check.sh`. Covers L0a–d, L1, L2, L3a, L4, L6 — everything except real-checkpoint golden parity, the cell-hash A/B and perf. Per `TEST.md` §1 the synthetic layer is the *primary* gate; the real-checkpoint oracle is the release gate, not the iteration loop. `check-e2e-reasonableness` and `test-vk-dsv4-stage-oracle` skip exit-0 without checkpoint/bundles — safe to include, prove nothing.

---

## 9. Risk register

| # | risk | L | I | mitigation | decision? |
|---|---|---|---|---|---|
| 1 | **Two Vulkan stacks** — fork's per-op `dsv4_cuda_*` tier vs upstream's `vk_tier`/`vk_chain` recording tier, with opposite failure semantics | H | H | Decide at P0: one survives. Recommendation: keep the per-op ABI (40 gates), port upstream's dense/expert gains as *ops behind the ABI*, delete the second chain | **YES** |
| 2 | `qmatmul.comp` name/`fmt`/push-constant collision | H | H | Namespace rename + single `fmt` table + `.spv`↔push-constant build assertion | no |
| 3 | Engine text-merge infeasible (49 collision fns, 217 vs 48 ifdefs, 7,752-line GPU unit) | H | H | Reject (c); port call sites in coalesced P5 slices, one op group per PR | **YES** (accept cost) |
| 4 | `.golden` pinned at `dd7df2c9`; re-record ≈ 4.1 h/run | H | M | Re-pin in P0, budget two full re-records, `--pinned-only` for iteration | no |
| 5 | Golden gate is CPU-only in practice (`target_batch(NULL,…)`) — GPU divergence passes silently (already realised as #19/#40) | M | H | Keep the split contract; add a log assertion that the GPU leg actually allocated | no |
| 6 | Missing upstream ABI symbols → undefined refs | H | M | P1: implement `device_unified` (upstream semantics), stub `expert_bank_upload_aux` as a loud refusal | no |
| 7 | Rounding/fmt drift on ported shaders (fp64 removal, bf16 points, E8M0) | M | H | Bitwise only for same-computation pairs; envelope elsewhere; re-run stage-oracle with freshly packed bundles | no |
| 8 | RADV denormal-flush waiver is host-specific (< 1e-30 benign under the 1e-4 QDQ floor) | M | M | Re-measure per ICD; encode as a named waiver with the measured floor | no |
| 9 | Env surface: 234 shared names unverified; 19 removed levers; `COLI_VK_STRICT` vs refusal | M | M | `env_doc_drift.sh --check` as a merge gate; per-name `ENVIRONMENT.md` diff; publish strict/refusal per build | **YES** (which semantics ships) |
| 10 | `dsv4.def` (83) vs header (161) — Windows DLL cannot resolve ~78 | M | M | Decide the export set at P1: export the stubs, or move them behind `COLI_V4_GPU_TIER_VK` and out of the header | **YES** |
| 11 | **Licensing** — Apache-2.0 both sides; weights not redistributed (checkpoint is a local ~167 GB download via `download_fp8.py`). Provenance risk sits on ported artifacts: `.golden` fixtures, `.stage_oracle` bundles (~230 MB, gitignored), upstream's `THIRD_PARTY_NOTICES.md`. Upstream has `NOTICE` + `THIRD_PARTY_NOTICES.md`; **the fork has no `NOTICE`** | M | M | Add `NOTICE`; never commit checkpoint bytes or bundles; keep the fork's own Apache header on fork-authored files and upstream's elsewhere; re-run upstream's third-party inventory per slice | **YES** |
| 12 | Toolchain drift — no pinned `glslc`, 8 fork-specific byte recipes, coop fallback upstream-only | M | L | Pin `glslc` in CI/nix; `.spv` byte-reproduction check; ensure `qmatmul_coop` is never compiled/selected on gfx1030 | no |

Tail (not scored): `COLI_V4_UNIT_SEGMENT_ADAPTER` missing from the fork's unit list; upstream's GGUF path changes `ColiDeepSeekV4TensorSpec` layout, so a fork-built `.o` against an upstream header is an ODR hazard `V4_FLAGS_STAMP` cannot see; and the fork's uncommitted WIP (`v4_ckpt_min_tokens` 512→64, `REVIEW.md`, `docs/deepseek-v4.md`, two untracked scripts) must be committed or discarded before the port branch is cut.

---

## Commands used

`git rev-list --count dd7df2c9..<rev>`; `git diff --numstat/-stat/-name-status dd7df2c9 <rev> -- <hot files>`; `git diff -U0 <range> -- c/deepseek_v4.c | grep -E '^@@'` (function collision set); `grep -o 'dsv4_cuda_[a-z0-9_]*' c/backend_cuda_dsv4.h | sort -u` + `comm`; `diff c/shaders/qmatmul.comp <up>/c/shaders/qmatmul.comp`; `diff c/Makefile.deepseek-v4.units <up>/...`; `grep -rho 'COLI_[A-Z0-9_]*' c/*.[ch] | sort -u` + `comm`; `grep -c` for `COLI_V4_GPU_TIER` and `dsv4_cuda_` in both `deepseek_v4.c`.

## Open uncertainties

- Commit counts: 2,399 measured vs 1,919 in the brief.
- Semantic equality of the 234 shared `COLI_*` knobs is not statically decidable here.
- `V4_SEGMENT_UNIT` appears only in the units file; `Makefile.deepseek-v4` never references `SEGMENT` — another Makefile may consume it.
- The 4.1 h full-gate figure is the fork's own 2026-09-16 measurement on this host, assumed to carry over.
