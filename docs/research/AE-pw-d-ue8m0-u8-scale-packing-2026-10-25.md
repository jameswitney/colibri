# AE — the tier's UE8M0 u8-scale packing (PW-D, the parity wave's first slice)

**Date:** 2026-10-25 · **Lane:** pw-d (`port/pw-d`, from `0c847722`) · GPU used for gates only (no bench
arms — the window is the manager's). Pre-registered expectation (CAMPAIGN.md's PARITY WAVE): tier
capacity +17.6 % (277→~326 residents), TTFT −15…−16 s from the stream bytes; lossless ⇒ unconditional,
token-exactness the proof.

## 1. The slab reconciliation the audits asked for (15.0 MiB vs 28.8 MiB)

The two census figures count different things; both are real, neither is a miscount of the other:

- **15.0 MiB** is the tier's **per-expert device payload** — `expert_bytes_at` (`c/vk_tier.c`) over
  `scale_floats()×4`: 12 MiB of e2m1 nibble codes (3 tensors × 4 MiB) + **3 MiB of f32 scales**
  (4 B × 128 groups/row × 2048 rows per tensor). This is what the budget line divides
  (`budget … = N experts of 15.0 MiB (fmt 7 …)`) and what the placement census's "2.26×" should have
  been measured against.
- **28.8 MiB "effective"** is the placement census dividing the **whole tier device pool** (7.81 GiB,
  which holds the resident experts *and* the 256 stream slots' pool) by the resident count 277:
  (277 residents + 256 slots) × 15.0 MiB = 7.81 GiB exactly. It is a tenure/bookkeeping ratio — the
  stream slots' bytes charged to the residents — not a property of the format. That census's "fmt 7
  fp8 gs 32" is also a mislabel: fmt 7 is MXFP4 e2m1 (the codes are already 4-bit, same as the fork's;
  only the scales differed).

So the audit's packing finding stands with the right number: the port's resident MXFP4 expert carries
**f32 scales** where the fork's carries **1 ue8m0 byte per 32-group** (its upload line
`bytes=4456448` = 4.25 MiB/tensor) — 15.0 vs **12.75 MiB** = **+17.6 % bytes per expert**, and the
capacity/stream/promote economy moves by exactly that factor.

## 2. The numerics verdict: LOSSLESS, landed unconditionally

The engine's on-disk (RAM/store) form for the tier's MXFP4 experts **already is ue8m0**:
`VktFmt {VKT_SRC_MXFP4_E8M0, 32}` (`deepseek_v4.c`'s `v4_vk_tier_start`; the store's slab = "a scale
byte then 16 code bytes per 32 values"). The old device path expanded each byte at upload —
`convert()`: `uint32_t u = (uint32_t)e << 23` — i.e. the byte's value lands **in the float's exponent
field**: exactly 2^(e−127), a power of two, sign 0, mantissa 0. The shaders' packed decode is the same
construction read back: extract byte e from the scale word, `uintBitsToFloat(e << 23)`. The round trip
**ue8m0 → f32 → ue8m0 is the identity on all 256 byte values**, so packing changes bytes, never values
— the D-series' lossy-env law does not apply, and the form landed with **no env**.

Proof, three layers (all green on the RX 6900 XT / RADV):

1. **Host identity** — `tests/test_vk_tier.c`'s `packed_scales`: every byte 0..255 through both
   directions of the construction; plus the byte-arithmetic checks (scale words hold O·⌈I/gs⌉ bytes
   padded <4; fmt 7 holds exactly 4× the bytes; `vkt_expert_bytes` prints
   **"ue8m0-packed 12.75 MiB, f32 scales 15.00 MiB (x 1.1765)"** at DeepSeek V4's geometry).
2. **Device bit-identity** — the new `run_xbatch_mx_pack` case in the VK_TEST harness
   (`backend_vulkan.c`): one set of codes and scale bytes drives both forms (fmt 15 packed and fmt 7
   with the bytes expanded to f32), rows 1/3/2/20 across the GEMV / chain_moe_gv / GEMM routes:
   **"fmt 15's 26 rows identical to fmt 7's bits, worst relative error 1.77e-05 against the double
   reference."** (The first cut of this case compared two different random draws and "passed" vacuously
   — the shared-data rewrite is what makes it a proof.)
3. **Token-exactness** — `deepseek-v4-tiny-check` (23 PASS lines) and `-dmoe` (63 PASS lines, the tier
   booting `fmt 15 gs 32, down fmt 15 gs 32` on every leg): greedy tokens unchanged against the
   fixture's oracle through the decode, prefill, dmoe/bank/rows and composed legs.

## 3. The seam

A new device format, **fmt 15 = e2m1 nibbles + packed ue8m0 scale bytes (4 to a word)** — fmt 7 (f32
scales) stays for `VKT_SRC_MXFP4_F32` sources and the generic dense APIs, so nothing existing moves.
The scale buffer keeps the pool's 4-byte unit: `scale_floats(15)` counts the **words** the bytes take,
so every existing `×sizeof(float)` byte count, copy, refill and promote path holds unchanged.

- **Upload** — `vk_tier.c` `dev_fmt`: E8M0 → 15 (Vulkan); `convert()`: the bytes verbatim, word pad
  zeroed. The stream slots, host pool and per-layer forms all follow the form table.
- **Every consumer that reads resident experts** — one byte-extract branch each
  (`floatBitsToUint(scale[b>>2])` → `bitfieldExtract` → `e<<23`):
  `qmatmul_grp_mx.comp` (+`_gate_up_`) — the grouped GEMM, mode 4 and the chain's `vkc_moe_rows`
  (the format read per expert from the table's `[10]`, which both the batch and `chain_moe_rows.comp`
  already write); `chain_moe_gv.comp` (FMT spec-constant 15, the XB's cgv slot 5);
  `chain_moe.comp` (`block_15`, the generic runtime dispatch + `vpw`/`grouped`/`word_dot`);
  `qmatmul.comp` + `qmatmul_gate_up.comp` (the per-expert GEMV route); `qmatmul_gemm.comp` (the fp32
  tiled GEMM route); `qmatmul_coop.comp` (the cooperative-matrix route); `qmatmul_grp_gemv.comp`
  (the grouped GEMV, mode 2). Host gates extended symmetrically (mode-4/mode-2 eligibility, cgv's
  format table `[5][2]`, `coop_fmt`, the tile check, refill/payload/alloc byte counts); the generic
  `upload_tensor`/import paths **refuse** fmt 15 (its scales are bytes, not the `float*` those APIs
  take — the tier's convert is its only writer).
- **CPU host rows** — `vk_tier.c` `host_rows`/`dev_dequant` decode the bytes (the int8-dot path
  expands into the existing `half[]` scratch, halved like fmt 7's doubled values); the tier check's
  hybrid legs stay bit-identical to the engine's arithmetic with fmt 15 live.
- **CUDA keeps fmt 7** — `cu_tier.c` is this file compiled again under `COLI_CUDA`; its ops table
  (`cu_xb.cu`) has no fmt 15, and there is no nvcc on this rig to build or prove one, so
  `#ifdef COLI_CUDA` pins the E8M0 source to fmt 7 there: the CUDA tier's behaviour is exactly today's
  (syntax gate green). Teaching `.cu` the packed form is a follow-up that needs a CUDA rig.

## 4. Capacity arithmetic (the pre-registration, corrected)

At the same GiB the tier holds 15.0/12.75 = **1.1765× the experts** — but both the residents *and*
the stream slots shrink, so the residents' count grows by more than the pre-registered ~326 (which
scaled the residents alone): at the census rig's 7.85 GiB with 256 slots,
fit_raw goes 536→630 and the residents 277→**~374** (with the slots shrinking 256 slots × 12.75 MiB);
holding the slots' *count* fixed instead gives the residents-only 277×1.1765 ≈ 326. Both readings hold
the same bytes; the bench window reads the real line. The tiny gate prints the new class directly:
`budget 14.10 GiB = 12 experts of 25.5 KiB (fmt 15 gs 32 …)` — 25.5 KiB where the f32 form was 30.0
(the same 12 experts in 0.85 of the bytes). Every stream/promote/upload byte for MXFP4 experts drops
17.6 % — the −15…−16 s TTFT expectation is the manager's window to measure (the prefill stream's
183.25 GiB becomes ~155.8 GiB at the same 10,482 experts).

## 5. Gates (all green, run 1)

`vk-tier-check` (both modes: the full scenario set incl. the new `packed_scales` unit, the
MXFP4-ue8m0 mode-4 stream case, hybrid/host-pairs with fmt 15 live) · `vk-chain-check`
(11,966 frames) · `vk-strict-check` ×3 (flake protocol: no flakes) · `deepseek-v4-tiny-check`
(23 PASS) · `-dmoe` (63 PASS, tier on fmt 15 through the chain's rows/bank paths) · `serve-framing` ·
`cu_tier` syntax (`-fsyntax-only -DCOLI_VULKAN -DCOLI_CUDA`) · the VK_TEST harness with the new
fmt-15 xbatch cases (GEMV/cgv/GEMM, SwiGLU and SiTU) — **PASS**, outputs digest
`e71dff75c0df60cb` / imports `34df89280461294a` **identical staged and mapped**. The
`bank_layer_case` scenario gained a reseed + a forced routed trio: its whole-table expectation was
stream-luck (my added grouped case moved the harness's rand stream and exposed it; the base's own
draw happened to cover — the case now covers deterministically). `vulkan_engines.sh shader` is
environment-blocked on this rig (no Lavapipe ICD; the pre-existing condition earlier lanes recorded)
— its shader coverage ran directly here instead.

## 6. Residual risks

- The cooperative-matrix branch (`qmatmul_coop.comp`) is written to fmt 7's shape but **no device on
  this rig has cooperative matrices** — it is compile-checked only. The RADV/NVIDIA paths that matter
  for parity are the GEMV/GEMM/mx ones, all gate-proven.
- The CUDA tier keeps fmt 7 (§3) — no behaviour change, but the packing win does not reach CUDA rigs
  until `cu_xb.cu` learns the form.
- One harness-only fix folded in: `xmat_make`/the mx-pack case's byte-count arithmetic
  (`O*(I+gs-1)/gs` → `O*⌈I/gs⌉`; the naive form overcounts by `O*(gs-1)/gs` bytes — it corrupted the
  first cut of the equivalence case, which is how it was found).
