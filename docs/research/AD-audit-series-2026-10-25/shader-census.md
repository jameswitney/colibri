# Shader/kernel census — fork vs port at the standing configs (CPU-only, read-only)

**Date:** 2026-10-25 · **Lane:** audit-shaders (manager-run campaign) · **No GPU was used** — every
number below is quoted from committed logs / research docs or derived arithmetically from code.

**Sides (both read-only):**
- **Fork** `/root/Projects/colibri-ds4-vulkan` @ `d11fba5b` — the GPU-FOLD engine: host-stepped
  discrete shaders driven through `c/backend_vulkan.c` (23.8 k lines) + `c/backend_vulkan_dsv4.c`
  (the `dsv4_cuda_*` ABI shim) + `c/deepseek_v4.c`. Standing config = the fork's defaults (the
  `fork-full-r3.log` run on the parity rig is the reference: `cell-pipeline=on`, `moe-ram=on
  ring=3.19 GiB qd=16 take=par`, `moe-batch=on bank=256-experts`, `v5-cache slots=1982
  slab=12.8MiB`, `idxpool f16 ON`, mm8 `select=auto` → frozen F tile).
- **Port** `/root/bench-worktrees/up2276-merge` @ `0c847722` (`port/up-2276`) — the chain engine:
  `c/deepseek_v4.c` + `c/deepseek_v4_chain.h` building one-frame chains (`c/vk_chain.c`) over the
  `chain_*.comp` built-ins, plus the expert tier (`c/vk_tier.c`) and the expert batch
  (`c/backend_vulkan.c` XB family). Standing configs (the campaign's, all measured on the same rig):
  - **ttft set** (prefill arms): `COLI_VK_PROFILE=RDNA2` → ttft preset = `COLI_VK_MM8=1
    COLI_VK_CHAIN_GEMM_ROWS=-1 COLI_VK_TIER_STREAM_SLOTS=256 COLI_VK_TIER_GEMM_ROWS=4` +
    `COLI_VK_TIER_STREAM_BYPASS=1 COLI_VK_TIER_HOST_GB=4` (`c/backend_vulkan.c:1112-1115`;
    resolved in `s3-c3-r1.log:2`).
  - **decode set** (V-g1 legs): `COLI_VK_MM8=1 COLI_VK_TIER_HOST_GB=8 COLI_VK_TIER_PROMOTE=32`.

**Model geometry** (DSV4-Flash, from `fork-full-r3.log` inventory): 43 layers; `wq_a` 1024×4096,
`wq_b` 32768×1024, `wkv` 512×4096, `wo_a` 8192×4096 (8 block-diagonal groups of 1024×4096),
`wo_b` 4096×8192 — all fp8 (fork fmt 8 / port fmt 12, e4m3 + UE8M0-derived block scales);
compressors bf16; router 256×4096 f32; shared expert 2048/2048/4096 fp8; head 129280×4096 bf16;
experts gate/up I=4096 O=2048, down I=2048 O=4096 in fp4-e2m1 (fork fmt 10 / port fmt 7);
64 heads × hd 512, window W=128, `index_topk`=512, so a decode attention list is n≈640 rows.

---

## 1. Inventories

**Fork:** 51 `.comp` / 62 `.spv` in `c/shaders/` (committed). The build list is
`VK_SPV` in `c/Makefile.deepseek-v4:228` (52 entries incl. `_f16`/`_ts4` variants). DSV4
op-surface families: `qmatmul{,_mm8,_mm8_bf16,_mm8_reduce,_gate_up,_pf4*,_s1_fp4,_s1g}`,
`sparse_attn{,_f16,_fa,_fa_f16,_fa_dec,_fa_dec_f16}`, `idx{prep,proj,score,score_tiled,sel,sel2}`,
`comp_scan{,_par}(+_f16)`, `mhc_{rmsinv,collapse,sinkhorn,rmsnorm,post,pre_fused,dec_pre,dec_post,
ffn_tail}`, `moe_{swiglu,merge,reduce}`, `glue{1,2,3,_qn_rope}`, `dec_{qa,rows,fin}`,
`qdq{,_id,_gather}`, `wo_{gather,in_gather}`, `quant_q8`, `bf16r`, `kv_ring_append`, `rmsnorm`,
`attention_absorb`, `qmatmul` (generic).

**Port:** 59 `.comp` / 69 `.spv` + 3 `.glsl` (GGUF block-decode helpers) in `c/shaders/`. DSV4 runs
on the chain built-ins: `chain_{norm,rope,ew,gemv,gemv2,hgemv,attn,attnb,attn_dec,attn_full,
attn_coop,attn_flash,mhc,dsa,dsv4,moe,moe_gv,moe_rows,moe_i8,route,kvs,fetch,copy2d}` + the shared
`qmatmul{,_mm8,_mm8_reduce,_gemm,_grp*,}` family; the tier drives the XB expert batch
(`qmatmul_grp_mx/_bd/_q` + `chain_moe_gv`/`chain_moe`), all loaded lazily by name in `c/vk_chain.c`
(lines 45-68 table; 2693-2740 `vkc_moe_rows`).

**Byte-identical shared kernels:** `rmsnorm.comp`, `attention_absorb.comp`. Same-skeleton (format
numbering/scale layout differ): `qmatmul.comp` (the generic GEMV), `qmatmul_mm8.comp` — the port's
is the fork's issue-#46 kernel **ported with the same 9-tile spec-constant table and the same
split-K fill rule** (port `c/vk_chain.c:1346-1357,1372-1377,1414-1447` vs fork
`c/backend_vulkan.c:1035-1053,1213-1240`), `qmatmul_mm8_reduce.comp`, `qmatmul_gate_up.comp`.

**Format dictionaries** (the census' Rosetta): fork fmt 0=f32, 1=int8/row, 8=fp8-e4m3
(128×128-block scales, expanded to f32 at upload), 10=fp4-e2m1+**packed UE8M0** u8 scales/32-group,
16=bf16 ↔ port fmt 10=f32, 1=int8/row, 12=fp8-e4m3 (f32 scale per row per 128-input group),
7=MXFP4 e2m1+**f32** scale per 32-group (`c/vk_tier.c:1965-1969`), 11=bf16, 13=int8/32.

---

## 2. The census table — op class → kernel at the standing config

Decode = S=1 forwards; prefill = 2048-row chunks (`CHAIN_GEMM_ROWS=-1`). "measured" = a campaign
doc/log quotes the number; "inferred" = code geometry + arithmetic only.

| # | op class | fork kernel + geometry | port kernel + geometry | verdict |
|---|---|---|---|---|
| 1 | dense fp8 projections **prefill** (wq_a/wq_b/wkv/wo_b) | `qmatmul_mm8` tiled weight-stationary GEMM, spec-const tile F 128t/32×64/BK32 (auto m16 at O≥16384 only under env `auto`), split-K auto fill-2048 k≤8 + `qmatmul_mm8_reduce` (`backend_vulkan.c:1047,1099-1290`, cell sites `:8632-8680`) | **the same kernel, ported**: `qmatmul_mm8.spv` + `_reduce`, same tile table, same split-K rule; arm = fmt 12 ∧ S≥2 ∧ I%64==0 ∧ `COLI_VK_MM8=1` (`vk_chain.c:1513-1520`) — armed by both standing presets | **measured-equivalent** (port TTFT 257.7→229.5-239.8 s when landed, ENVIRONMENT `COLI_VK_MM8` row; X §4 "fork-class") |
| 2 | dense fp8 projections **decode** (S=1) | dec2 chain, ONE submit: `dec_qa` (wq_a GEMV + in-shader QDQ) + `qdq` + `dec_rows` (wq_b+wkv GEMVs, grid-stride occupancy-shaped) + `dec_fin` (per-head L2+rope+kv_norm) — bodies **verbatim `qmatmul.spv` fmt=8 S=1** (`backend_vulkan.c:15682` `ds4vk_dec2_qkv_impl`, `:13732` `ds4vk_record_fmt8_s1`) | per-op in one chain frame: `vkc_matmul` → fmt 12 not in `chain_gemv.comp`'s list (`vk_chain.c:1505-1507`) and mm8 refuses S=1 → **generic `qmatmul.spv` GEMV** `(O+7)/8 × S` (`vk_chain.c:1579`); QDQ/norm/rope as separate `chain_dsv4` mode-7 / `chain_norm` / `chain_rope` dispatches in the same frame | **same-class** (identical GEMV math class both sides; the port pays extra in-frame round-trips; both are 2.5–9.8× off the 315–325 GB/s floor — measured, L7 Step-0: fmt-12 bucket **57.3 ms/tok**; the fork's own census calls this split "already correct") |
| 3 | wo_a grouped (8×1024×4096) **prefill** | ONE fused mm8 dispatch grid.z=8 + T4 row-major bf16 hand-off into wo_b (`out_mode`), `qdq_gather`/`wo_gather` folded (`backend_vulkan.c:15035` `ds4vk_wo_record`, mm8 groups `:11516`) | 8 × `chain_hgemv` mode-0 dispatches (subgroup-per-row GEMV, weights re-read per row → Infinity-Cache-resident), per `deepseek_v4_chain.h:1212-1215` | **port-slower kernel** (GEMV vs tiled GEMM at S=2048) but **masked**: inside A1 device time that hides under the 105.6 s staging span (X §3); untested substitution |
| 4 | wo_a grouped **decode** | `qmatmul_s1g` — ONE dispatch grid.z=8, arithmetic e4m3 decode, x LDS-staged, bf16 store (`shaders/qmatmul_s1g.comp`, `backend_vulkan.c:1653-1666` default on) | 8 × `chain_hgemv` mode-0 in one frame (`deepseek_v4_chain.h:1212-1215`; `vk_chain.c` `vkc_mla_hgemv`, grid.x=min(H·n/8,4096) × S) | **same-class** (fork's own A/B: `WO_S1G` GPU-time-neutral vs its 9-dispatch loop — B-inventory; port MLAW decode bucket **71.1 ms/tok** vs a ~4.3 ms/tok bandwidth floor for 1.34 GiB fp8/tok — the whole class is off-floor on both sides) |
| 5 | norms / rope / QDQ glue / bf16 rounds | `glue1` (norms), `glue2` (x-QDQ + kv roles), `glue_qn_rope` (q L2+RoPE fused, 1 WG/(token,head)), `glue3` (inverse rope + bf16), `bf16r` — several ops per dispatch | per-op `chain_norm`, `chain_rope`, `chain_dsv4` mode 7 (bf16/e4m3/e2m1/Hadamard roundings), `chain_ew` — one dispatch per op, all inside the layer's one frame | **same-class** (compute identical class; the fork fuses more ops per dispatch — matters at submit granularity, not in the port's frame model; port whole-run buckets: norm 59 ms, rope 81.5 ms, ew 891 ms) |
| 6 | attention (V4 sparse, MQA over window+selected comp rows, sink) | `sparse_attn_fa{,_dec,_f16}` — llama.cpp FA port: 256 t, Br=8 heads/WG, Bc=16, K/V staged once in LDS (~54 KB), online softmax, subgroup-tree dots, **f16 KV storage** (KV_F16 retired ON, `backend_vulkan.c:4747`); decode tile Br=2 (`:5267`); dispatch (tokens, heads/Br); gates `:5236-5336`; **measured ~10 ms/tok at decode** (fork decode-residency review §1) | `chain_dsv4.comp` mode 0 — ONE workgroup per (head,row), scalar per-thread 512-length dots for scores, second scalar pass for values, **fp32 KV**, no LDS K/V staging, list read 2× per head → KV VRAM read amplification ≈ 2·H = 128× vs the fork's H/Br = 8× (`vk_chain.c:3509` loads; `deepseek_v4_chain.h:1207`); decode bucket **attn 63.8 ms/tok** (V-g1/gemv8-step0); whole-run attention device **42.9 s** (516 dispatches) | **port-slower kernel — UNTESTED substitution** (est. −40…−55 ms/tok decode; ≈ 16× the row re-reads × 2 the width (fp32 vs f16) ⇒ ~32× the KV bytes per attended row) |
| 7 | indexer (DSA: q-proj, key pool, scores, top-k) | `idxproj` (fp8 replica) + `idxscore_tiled` (LDS-tiled, default on `backend_vulkan.c:5854`) over an **f16 key pool** (idxpool f16 ON) + `idxsel2` (8-bit radix; the only path) — the per-token deferred "train", ONE submit at decode (`COLI_V4_IDX_DECODE_TRAIN` default on) | in-frame: `vkc_matmul(iwq/iwp)` + `chain_dsv4` modes 3/9 (score; one WG/row), 4 (candidate blocks), 5 (top-k; one WG/row) (`deepseek_v4_chain.h:1163-1176`); f32 key pool | **same-class** (both one-workgroup-per-row small ops; the port's is in-frame so submit-neutral; fp32 vs f16 pool halves the port's key-read efficiency; untested but small) |
| 8 | compressor (kv/wgate projections + rolling-group scan/pool) | projections: `qmatmul_mm8_bf16` (frozen 32×64 BK32); scan: `comp_scan_par` 2-pass parallel + `_f16` pool (default) (`backend_vulkan.c:3193`); at decode the pooling/state stayed **CPU** (the fork's own census: "no decode shader exists") | projections: `vkc_matmul` fmt 11 → the tiled fp32 GEMM `qmatmul_gemm.spv` (fmt-11 arm `qmatmul_gemm.comp:101`, tiles {128×32, 64×64} BK32 — the GEMM arm fires at S≥2 before the vectorized GEMV, `vk_chain.c:1496-1570`); scan: `chain_dsv4` mode 2 — **ONE workgroup** for the whole rolling-group scan (`deepseek_v4_chain.h:1124`, `chain_dsv4.comp` mode-2 header); then per-pooled-row norm/rope/round ops | **projections same-class** (both tiled; the fork's is the bf16-specialized twin); **scan port-slower** (1-WG serial vs 2-pass parallel, f32 vs f16 pool) but masked under A1/staging at prefill; the port is the only side with the scan **on device at decode** (fork does it on CPU) |
| 9 | mHC pre/post (hyper-connections, attn+ffn each layer) | device-resident family: prefill `mhc_pre_fused` (fn GEMV + rmsinv + sinkhorn + collapse + rmsnorm, single submit); decode `mhc_dec_pre` (ONE workgroup: RMS-inv+Sinkhorn+collapse+norm) + `mhc_dec_post` + `mhc_ffn_tail` (MoE merge + post expand in ONE dispatch) — all default ON (`backend_vulkan_dsv4.c:329,345`; `backend_vulkan.c:232-311`) | in-frame per-op: `vkc_matmul(fn)` (fmt 10 f32) + `chain_mhc` modes SPLIT/COLLAPSE/POST/MEAN ×2 (attn+ffn) per layer (`deepseek_v4_chain.h:1095-1107`); decode bucket **mHC 36.1 ms/tok** | **port-slower (fusion), UNTESTED** — the fork's fuse was worth +19 % decode when it landed (its own record); est. −20…−30 ms/tok |
| 10 | shared expert | prefill: `mm8` sh_gu/sh_dn (split-K'd, `backend_vulkan.c:11728-11754`); decode: 3 GEMV submits riding the group's fused tail (`:12061-12093`) | `v4c_shared` in the A2 frame: 2× `vkc_matmul` (fmt 12) + `chain_dsv4` mode-8 SwiGLU + 1× `vkc_matmul` (`deepseek_v4_chain.h:1221-1229`); A2 device **10.6 ms/tok** (V-g1) | **same-class** |
| 11 | routed experts **prefill** (chunk scale) | expert-major fused bank: per-layer 256-expert VRAM bank, `qmatmul_pf4_f16` (tiled weight-stationary, packed-f16x2 acts — "bank ON" in the rig log) per (expert, gate/up/down) + `moe_swiglu` + `moe_merge`/`moe_reduce` + `qdq_id` device gather/reduce (`backend_vulkan.c:13220` bank em group) | tier stream: cold experts ≥4 rows staged through 256 slots and computed by the **grouped GEMM** — `chain_moe_rows` (count/plan/scatter/sum) + `qmatmul_grp_gate_up_mx`/`qmatmul_grp_mx` via `vkCmdDispatchIndirect`, ONE dispatch per pass per step (`vk_chain.c:2728`); the ≤3-row tail stays on the CPU (`host_rows`, `vk_tier.c:2099`) | **same-class kernels** (both tiled weight-stationary MXFP4 GEMMs; the port even has fewer dispatches); measured separately, never head-to-head: port 47.7/99.1 ms per layer-visit at 512/2048 rows (T-l2-arms §K1), device 19.4 s of a 155 s TTFT — **not the TTFT bottleneck** (staging 105.6 s owns it, X §3) |
| 12 | routed experts **decode** (row scale) | fused single-submit group: QDQ + `qmatmul_s1_fp4` per-expert S=1 GEMVs (arithmetic e2m1+UE8M0 decode, x LDS-staged, no bounds checks — `backend_vulkan.c:10788-10800`, `shaders/qmatmul_s1_fp4.comp`) + gate/up + swiglu + down + merge in ONE submit (`coli_vk_expert_dsv4_fused`, `:11351`) — all VRAM-tier experts device-side | **the kernels exist and are fork-class**: `chain_moe_gv` (fmt-7 gate+up fused per unit / down per pair) + `chain_moe` mode 2 rank-order sum = **292 µs/layer at S=1** (K1, 4.5× faster than the grouped rows route) — but at the standing decode set only **13–22 % of routed experts are device-served** (`s3-c3-r1.log:43`: 2124/16254 = 13.1 %); the rest run on the host CPU (`host_rows` AVX2, `vk_tier.c:2099`) = **822 ms/tok** (V-g1) | **measured-equivalent kernels; port-missing placement** — the substitution (device MoE for the host step) was measured and falsified at this rig's budget: dmoe-hybrid −1.4 %/layer (U), bank D/K MISS (AA), layer-outer F MISS (AC). This is Option B, not a kernel |
| 13 | router / gate | gate matvec GPU (f32 GEMV) + **host top-6** (`backend_vulkan_dsv4.c:1092` `ds4vk_route_top6`) | standing: **host** matvec + top-6 inside `coli_v4_moe_routed` (part of the MOEH/glue mass); the in-frame form exists and is armed only under `COLI_VK_DMOE` (`vkc_route` + `vkc_matmul(gate)` fmt 11, `deepseek_v4_chain.h:1430-1436`) | **same-class machinery, port runs it on host at standing** (~4 MiB f32/layer/tok host read; part of the 519 ms/tok glue; untested, small) |
| 14 | output head (129280×4096 bf16) + final mHC/argmax | **GPU**: bf16 matvec + GPU argmax (`dsv4_cuda_head_argmax`, `backend_vulkan_dsv4.c:1656`; rig log "head argmax moves to GPU"), fused final tail `dsv4_cuda_final_argmax` (`:1683`) | **HOST**: "the final streams come back to the host, which runs final_hidden and the head as its C does … the head stays on the host" (`deepseek_v4_chain.h:41,85`); measured **head 72.9 ms/tok** (V-g1 §2 CLI head) | **port-missing (host path), UNTESTED** — est. −60…−70 ms/tok (1.06 GB bf16/token: ~2.6 ms at a 400 GB/s VRAM floor vs 72.9 measured host) |
| 15 | KV ring append / ring storage | `kv_ring_append` device append (2026-10-15); **f16 ring + comp pool** (KV_F16 ON) | `vkc_copy_regions` in-frame copy; **f32** ring/pool (`deepseek_v4_chain.h:1200-1205`) | **same-class op; port stores 2× the KV bytes** (feeds row 6's amplification) |
| 16 | expert slab format (capacity, not compute) | fmt 10 = e2m1 + **packed UE8M0 u8 scale / 32-group** → **12.75 MiB/expert** (rig log `slab=12.8MiB`; `scale_bytes` `backend_vulkan.c:2218`; fork fp4-bank-review §1 table: 15→12.75 MiB, Phase 1 landed) | fmt 7 = e2m1 + **f32 scale / 32-group** → **15.0 MiB/expert** (`vk_tier.c:1002` "277 experts of 15.0 MiB"; `qmatmul_grp_mx.comp` "one float scale a 32-input group") | **port-slower format: +17.6 % bytes/expert** — see §3 lead 1 |

---

## 3. The four named leads, verified

1. **Expert slab 12.8 vs 15.0 MiB — CONFIRMED, and it is the scale bytes.** Fork per expert:
   weights 3×4 MiB (e2m1 nibbles) + scales 3×256 KiB (**1 UE8M0 byte per 32-weight group**, packed
   4/word, decoded in-shader from bits — `qmatmul.comp`'s `e8m0_to_f32`, `qmatmul_s1_fp4.comp`'s
   `mx4a`) = **12.75 MiB** (upload line `bytes=4456448` = 4.25 MiB/tensor in `fork-full-r3.log`).
   Port: weights identical + scales 3×1 MiB (**f32 per group**, `qmatmul_grp_mx.comp`) = **15.0 MiB**
   (Q-l2 "an expert is 15.0 MiB"; tier print `vk_tier.c:1002`). The expansion is exact (UE8M0 is a
   power-of-two exponent), so the fork's packing is numerics-neutral. **What it buys:** +17.6 %
   experts per byte of residency — whatever the effective budget, e.g. the tier's 277-expert
   fit would hold ~326, the 4 GiB host pool 272→~320 — and −17.6 % on every stream/promote/upload
   byte: the measured 183.25 GiB prefill stream (X) would be ~155.8 GiB ⇒ at the measured
   1.74 GB/s end-to-end staging rate that is **≈ −15…−16 s TTFT**, plus −17.6 % promote traffic
   at decode (612 MiB/window class). UNTESTED on
   the port (it needs a fmt-7 scale repack at load + in-shader u8 decode in `qmatmul_grp_mx`,
   `chain_moe_gv`, `chain_moe`, `chain_moe_rows`, `qmatmul`).
2. **The fork's s1 fp4 GEMV family vs the port's decode GEMV — the port already has the
   equivalent.** Fork: `qmatmul_s1_fp4` (dedicated S=1 fmt-10 GEMV, LUT-free arithmetic decode) +
   `qmatmul_s1g` (the wo_a grouped one-dispatch form, measured GPU-time-neutral in the fork's own
   A/B). Port: `chain_moe_gv` + `chain_moe` mode 2 measured **291.8 µs/layer at S=1** (K1,
   `k1-moe-rows.log`) — 4.5× faster than the grouped-rows route, i.e. the decode expert *kernel*
   is fork-class; and `chain_hgemv`'s fmt-12 mode-0 rows form is the wo_a counterpart. The decode
   expert gap is **not the kernel** (row 12): it is that 79–87 % of experts are computed on the
   host (`vk_tier.c:2099` `host_rows`, AVX2 int8 dot) — 822 ms/tok (V-g1).
3. **mm8 dispatch conditions — identical after the port.** Fork: fmt 8 ∧ S≥2 (`coli_vk_matmul`,
   `backend_vulkan.c:4265`, `ds4vk_mm8_dispatch` refuses `S<2`/`groups<1`), variant table F/M/S/
   M16/F64/FTM4/FTN4/MWM4/MBN128 with zero-config default = frozen F (m16 only at O≥16384 under
   `MM8_VARIANT=auto`), split-K auto (fill 2048, k≤8, word-aligned divisor invariant). Port: fmt 12
   ∧ S≥2 ∧ I%64==0 ∧ `COLI_VK_MM8∈{1,-1}` (`vk_chain.c:1513-1520`), the **same tile table**
   (`:1346-1357`), the **same split-K rule** (`:1414-1447`), default frozen F. Both presets arm
   `MM8=1`. The fork's bf16 twin (`qmatmul_mm8_bf16`, compressors) has no direct port: the port's
   fmt-11 compressor pair takes the generic fp32 tiled GEMM (`qmatmul_gemm.spv`) — same class,
   not the bf16-weight-specialized twin (row 8).
4. **sparse_attn FA vs the port's chain attention — the port runs the plain kernel.** Fork:
   `sparse_attn_fa` (+`_dec` Br=2, +`_f16` KV), LDS-tiled, subgroup dots, online softmax, sink
   handling; default ON whenever the shape matches (dim 512, heads%8==0 — always true here); fork
   measures ~10 ms/tok at decode. Port: `chain_dsv4` mode 0 (1 WG per (head,row), two scalar passes,
   fp32 KV, no LDS staging) at BOTH prefill and decode; 63.8 ms/tok decode bucket, 42.9 s whole-run
   device. The fork's kernel was never ported; nobody has measured the substitution (the campaign's
   attention work was dense-model `chain_attnb/_full/_flash`, not the V4 sparse form). **This is the
   census' clearest untested kernel deficit.**
5. **mHC fused family — partially ported.** The port has the mHC *ops* on device (`chain_mhc`
   SPLIT/COLLAPSE/POST/MEAN + the fn GEMV in-frame), but not the fork's decode *fusions*
   (`mhc_dec_pre` one-workgroup whole pre-tail, `mhc_dec_post`, `mhc_ffn_tail` merge+expand), which
   the fork measured at +19 % decode when landed. Port bucket 36.1 ms/tok. UNTESTED.

---

## 4. Ranked missing-optimisation candidates

Ranked by (estimated affected decode ms/tok or TTFT s) × confidence. "Affected" = the measured
bucket the substitution would attack, not a promise.

| rank | candidate | fork anchor | port anchor | affected (measured → est.) | tested? |
|---|---|---|---|---|---|
| 1 | **Output head + final tail on device** (bf16 GEMV + argmax, fused final mHC mix) | `backend_vulkan_dsv4.c:1656,1683`; rig log "head argmax moves to GPU" | `deepseek_v4_chain.h:41,85` (host head); V-g1 CLI head **72.9 ms/tok** | 72.9 → ~3-5 ms/tok (**−60…−70**) | **UNTESTED** (never in the ladder; the chain's tail deliberately keeps the head host-side) |
| 2 | **V4 sparse-attention FA tile (+f16 KV ring)** | `c/shaders/sparse_attn_fa{,_dec,_f16}.comp`; `backend_vulkan.c:5236-5336,4747`; fork ~10 ms/tok | `chain_dsv4.comp` mode 0 (`vk_chain.c:3509`, `deepseek_v4_chain.h:1207`); bucket **63.8 ms/tok**, run 42.9 s | 63.8 → ~10 (**−40…−55**) decode; TTFT ~0 today (hidden under staging), surfaces only post-Option-B | **UNTESTED** |
| 3 | **fmt-7 UE8M0 scale pack (12.75 MiB slab)** | `backend_vulkan.c:2218` (`scale_bytes`), in-shader `e8m0_to_f32`/`mx4a` decodes | `vk_tier.c:1002` (15.0 MiB), `qmatmul_grp_mx.comp` f32 scales | capacity +17.6 % (e.g. 277→~326 tier experts at the same bytes), stream 183.25→155.8 GiB ⇒ **−15…−16 s TTFT**, −17.6 % promote bytes | **UNTESTED** |
| 4 | **mHC decode fusions** (`mhc_dec_pre`/`dec_post`/`ffn_tail` class) | `backend_vulkan_dsv4.c:329,345`; `backend_vulkan.c:232-311`; shaders `mhc_dec_{pre,post}.comp`, `mhc_ffn_tail.comp` | `deepseek_v4_chain.h:1095-1107` per-op; bucket **36.1 ms/tok** | 36.1 → ~8-15 (**−20…−30**) | **UNTESTED** |
| 5 | **Routed-expert device residency (the fold)** — *not a kernel*: the port's `chain_moe_gv` is fork-class (292 µs/layer, K1) | `backend_vulkan.c:11351` fused group, `:13220` bank | `vk_tier.c:2099` host rows (**822 ms/tok**, V-g1); device share 13-22 % | −790 ms/tok ceiling | **TESTED, falsified at this budget** (U hybrid −1.4 %/layer; AA bank MISS +341 s; AC fold MISS +401 s; = Option B, owner decision) |
| 6 | **wo_a decode/class GEMV occupancy** (MLAW 71.1 ms/tok vs ~4.3 floor; fork's `s1g` was neutral in the fork's frame) | `qmatmul_s1g.comp`, `backend_vulkan.c:1653` | `deepseek_v4_chain.h:1212-1215`, `vk_chain.c` `vkc_mla_hgemv` | up to −60 if the class can be brought to floor; fork evidence says the s1g form alone is **neutral** | PARTLY (fork-side A/B neutral; port side untested) |
| 7 | **fmt-12 S=1 GEMV floor** (57.3 ms/tok; 2.5-9.8× off floor per shape: 4096×8192 469 µs, 32768×1024 288 µs, 2048×4096 72 µs — gemv8-step0-prof-8) | same kernel class (dec2 bodies verbatim) | `vk_chain.c:1579` generic `qmatmul.spv` | −35…−45 if a `chain_gemv`-class fmt-12/13 path lands | **MEASURED, declined by rule** (L7A NO-GO: 13.1 % < 25 % bar — re-rank only after the fold, when the share grows) |
| 8 | **Compressor prefill scan** (1-WG serial `chain_dsv4` mode 2 vs `comp_scan_par` 2-pass + f16 pool; projections already same-class tiled GEMMs) | `backend_vulkan.c:3193` (`comp_scan_par`) | `deepseek_v4_chain.h:1124`, `chain_dsv4.comp` mode 2 | ~0 TTFT today (hidden in A1 under staging, X §3); matters only post-Option-B | UNTESTED (masked) |

Decode arithmetic check (V-g1 leg a-r1): port wall 1619.5 = chain waits 235.0 (A1 device 228.6 =
MLAW 71.1 + attn 63.8 + fmt12 57.3 + mHC 36.1) + tier MoE CPU 821.9 + glue 518.8 + head 72.9 −
overlap 29.1. Candidates 1+2+4+7 sum to a **kernel-level ceiling of ≈ 155-205 ms/tok** (≈ 0.61 →
≈ 0.68-0.71 tok/s at the standing decode set); everything beyond that is placement (candidate 5)
and glue discipline — consistent with the campaign's standing decomposition.

---

## 5. Stop-finding: is the gap kernels?

**No — and the table is the evidence.** Of the 16 op classes, 9 are same-class or
measured-equivalent **including every class the campaign suspected** (mm8 = ported and measured
fork-class; decode dense GEMV = literally the same kernel class; decode expert GEMV = fork-class
at 292 µs/layer; prefill expert GEMM = same-class tiled MXFP4 with *fewer* dispatches on the port;
shared/router/glue = same-class). The kernel-level residuals the census finds are **new, concrete,
and none of them is the gap**: head (72.9), attention (63.8), mHC fusion (36.1) — together
≈ 155-205 ms/tok of the **~750 ms/tok** decode gap and **~0 s of the ~50 s** TTFT gap at the
standing shapes. The dominant masses remain exactly what the campaign measured them to be:
**decode = routed-expert placement** (822 ms/tok host compute with fork-class device kernels
idle beside it — Option B) and **prefill = staging serialization** (105.6 s at 1.74 GB/s effective
while the fork's bank/ring overlaps the same bytes — X §3, architecture not kernels). The hunt for
placement/submission remains the right frame; the census adds at most three cheap kernel slices
(head, FA, mHC fuse) worth ≈ 0.07-0.10 tok/s combined if chased after — or alongside — the fold.

---

## 6. Sources

Code: fork `c/backend_vulkan.c`, `c/backend_vulkan_dsv4.c`, `c/Makefile.deepseek-v4`,
`c/shaders/*.comp` @ d11fba5b; port `c/vk_chain.c`, `c/deepseek_v4_chain.h`, `c/vk_tier.c`,
`c/backend_vulkan.c`, `c/shaders/*.comp` @ 0c847722. Logs: `/root/bench-colibri/up2276/fork-full-r3.log`
(fork standing rig run), `s3-c3-r1.log`, `gemv8-step0-prof-8.log`, `k1-moe-rows.log`. Research docs
(port `docs/research/`): O (fork lines, MX GEMM, fold attribution), Q (15.0 MiB), T/U (L2 arms, K1),
V (decode decomposition), X (prefill decomposition), AA/AC (bank/S3 falsifications); campaign specs
`/root/colibri-upstream-port/specs/L7-f8-decode-projections.md` (fmt-12 GEMV floor + fork dec2/s1g
anchors); fork `docs/fp4-bank-review.md` (slab table), `docs/decode-gpu-full-residency-review-2026-10-02.md`
(fork's own decode census, ~10 ms/tok attention, GPU busy 132-175 ms/tok), `docs/ENVIRONMENT.md`.
