# Changelog

All notable changes to colibrì are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- `COLI_VK_TIER_STREAM_RING` (default off): the stream's prefills move off the engine
  thread onto a ring worker — the fork's `v4_ram` class on the port's slots (the parity
  census's rank-1 never-tested row, the mechanism behind the measured STAGE 105.6 s prefill
  bucket). The prefetch call for layer L joins the running job (the take) and hands the
  worker layer L+1's predicted set (`T.pred`), read through a bypass stage pool of the ring's
  own and uploaded into the half of the streaming slots the running step is not reading; a
  step of another layer runs beside the job, every miss (a cold layer, an unpredicted
  expert, a refused read, a failed worker) takes the inline fill at the step,
  `COLI_VK_TIER_SYNC=1`'s deterministic drain includes the ring, and the teardown cancels
  between reads. Unset: the ring's reader is never called, the inline prefetch byte-identical
  (proven by a base-vs-arm tiny A/B). Evidence:
  `docs/research/AN-pw-b-stream-ring-2026-10-26.md`; measured at the campaign shape by the W2
  bench window (STAGE 106.3 → 1.1 s but TTFT +50.6 s — empty plans strand the fills on the
  inline path: `docs/research/AO-pw-w2-2026-10-26.md`).

### Fixed

- `vk-tier-check`/`vk-strict-check` at the W1 hotfix tip (test-only, PW-A2's close): `d73b82e1`
  made fmt 15 opt-in (`COLI_VK_TIER_FMT15`) without updating PW-D's `packed_scales` unit case,
  which asserts the packed-form byte shrink (12.75 vs 15.00 MiB, ×1.1765) through
  `vkt_expert_bytes` — un-armed that now returns the f32 form's bytes, so the case (and the
  strict gate's unset leg, which re-runs the same binary) failed at every post-hotfix head.
  The case now keeps its env-independent half (ue8m0↔f32 identity, scale-word counts) in every
  leg and runs the shrink half in a new armed third leg of `vk-tier-check`
  (`COLI_VK_TIER_FMT15=1 … fmt15`, the host-pairs pattern, the env set before
  `tier_fmt15()`'s one-time cache) — which holds whichever way the default later lands.

### Notes

- The parity wave's decode-disk lane (PW-A2, "zero-disk decode") closed **premise-falsified,
  no code change** — the fork's `bytes=0` decode line is its *store lease counter only*: beside it
  the same log reads `v4_direct … payload_bytes=199.82 GB`, and net of the 11,008-record prefill
  ring pass (147.2 GB) the fork reads **52.7 GB at decode** — at parity with the port's measured
  decode window (53.9–59.3 GB, 59–63 % of its ~92–98 GB run total; the split is derived exactly
  from the landed decode-only `hit_rate_d` counters). "Zero-disk decode" was never the fork's
  property — this is the placement census's second counter-class error (its §4 caught the same
  population error in the hit-rate row and kept it in the bytes row; §1.2 row 8 stands corrected).
  The mechanism is dead twice over on the tree's own evidence: the decode working set is
  **~4,000–4,440 distinct experts (~102/layer) against the store's 48 slots/layer** (25.70 GiB
  exactly spent — a perfect-oracle preload saves ≤ 2,064 of the ~4,400 loads), and the S7 arms
  already measured the mandated `.coli_mfu` rank: the full-store seeded prewarm moved
  decode-window misses 4,435 → 4,534 (worse), pin tenure worse still (`hit_rate_d` 68.1 → 62.9) —
  the boot prewarm's real, kept win is TTFT −5.4 s via page-cache warming, which a prompt-end
  preload cannot get. Where the lever actually is: the fork *hides* the same ~53 GB behind six
  async MoE read+compute lanes (census row 7, never-tested on the port, fork-priced +23 % decode)
  — handed to the campaign as the re-briefed PW-E. Evidence and arithmetic:
  `docs/research/AK-pw-a2-zero-disk-decode-2026-10-25.md`.
- **PW-Dfix (2026-10-26): the W1 fmt-15 P0 is found, fixed, and fmt 15 is the default
  again.** The defect was never the packed form itself: `host_pairs` — the tier's hybrid
  CPU path that computes host-pool experts in place — advanced each output row's *scale*
  pointer by the f32-scale stride, so fmt 15's packed ue8m0 bytes were read 4× too deep
  (past the 256 KiB scale range into the host pool's other bytes; a byte ≥ 0xC0 decodes to
  a scale ≥ 2^65, garbage bytes to 2^127 — non-finite expert rows, and one layer below the
  router fails exactly as the window saw; a 1-expert pool reads past the mapping and
  segfaults). Row 0 is always correct — a decode-class step's single-row hybrid pair
  passes — and no unit geometry leaves the scale range, which is how every gate stayed
  green while the model died (the green runs also leaned on `rel()`'s NaN comparison being
  false: a NaN row never raises a `worst`). Fixed by `host_scale_row` (vk_tier.c: the byte
  stride for fmt 15, the f32 stride for every other format); the same class found and
  closed in `qmatmul_grp_gemv.comp`'s writer tail (`fmt != 15` added to the per-row scale
  guard — latent, the grouped GEMV needs cooperative matrices this rig lacks).
  `COLI_VK_TIER_FMT15` is now the **default-on** form with `0` as the fmt-7 escape hatch;
  the model-scale evidence: the new `deepseek-v4-smoke` gate PASSes at defaults, with
  `COLI_VK_TIER_FMT15=1`, and with `=0`, where the pre-fix tree failed the same legs
  deterministically (rc=1, "chained block failed in MoE"). The regression test is the
  minimized repro (`model_hybrid_case`, test_vk_tier.c: fmt 15 at hidden 4096/inter 2048
  with the hybrid forced — 18 rows, 32768 non-finite values pre-fix, clean post-fix).
  Full record: `docs/research/AJ-pw-dfix-2026-10-26.md`.

- The parity wave's first kernel slice (PW-C1, "move the LM head matmul to the
  device") closed **premise-falsified, no code change**: the head matmul already
  runs on the Vulkan device at the standing config — the prompt tail and every
  decode token, through the per-matrix hook landed in `9f4eb917` (2026-10-02) —
  in the fork's own placement (GPU bf16 matvec + score readback + host argmax,
  identical tie-break). The audits' "port keeps the head (and the router matvec)
  on the host" read the DHO host-RAM-copy placement line and the chain header's
  in-frame-ownership comments as compute placement. The measured 72.9–88.1
  ms/tok DPROF/CLI head term is the per-op wall of the device call (submit,
  fence wait over queued chain/tier work, the 1.06 GB bf16 GEMV, readback), not
  host compute; the pre-registered −60…−70 ms/tok does not exist as a placement
  win. Evidence and the audit-series corrections: `docs/research/AF-pw-c1-head-2026-10-25.md`
  (gdb call census at tiny, exact GPU-matmul count decompositions at two chunkings,
  the 1010.0 MiB + 86.0 MiB close-line arithmetic).

### Added

- `COLI_VK_CHAIN_MHC_S1` (DeepSeek V4's chain, default off): the S=1 mHC slice of the
  parity wave (PW-C3) — the fork's single-dispatch decode mHC pair (`mhc_dec_{pre,post}.comp`,
  its Level-1 fusion) as `chain_mhc_dec.comp` on `chain_mhc`'s own buffers, offsets and
  `hp` layout. A one-row forward's mHC site drops from eight dispatches (the fn matmul,
  SPLIT, COLLAPSE, two bf16 rounds, the branch norm, POST and its round — the multi-
  dispatch class the fork measured regressing at one row, 0.315 -> 1.161 ms/call) to
  three (the matmul, one 256-thread workgroup for the whole pre tail, one thread-an-
  output post with the round folded). The fork's own numbers for the pair: the op tick a
  wash (0.317-0.321 vs the host loop's 0.306-0.311 ms/call), its +19 % decode win living
  in the serialized host path the port's in-frame chain never had — so this is the
  in-frame consolidation slice, not that number. Thresholded class against the standing
  chain per D11 (the fused bodies' single-rounding fmas, fma reduction trees, the other
  multiply order in the branch norm): unit-oracle at S=1 measures 5.8e-11 on the state
  and bit-identical outputs at the model geometry, the tiny oracle token-exact with the
  lever on; any refusal (streams > 8, hidden > 4096, a missing pipeline, the lever
  unset) records the standing chain, byte-identical by construction. The lane also
  re-armed `test_vk_tier`'s `packed_scales` around `COLI_VK_TIER_FMT15` — the W1 hotfix
  (`d73b82e1`) made fmt 15 opt-in and left the test expecting the packed bytes by
  default, which had `vk-tier-check`/`vk-strict-check` red at the branch point (proven
  on the base tree; PW-D's debt, not the mHC change). Report:
  `docs/research/AL-pw-c3-mhc-s1-fusion-2026-10-25.md`.
- `COLI_VK_TIER_FMT15` — the P0 hotfix of the W1 bench window (2026-10-25): PW-D's
  ue8m0-packed scales (device fmt 15) landed unconditional after a lossless proof at unit
  scale, but the window's first model-scale arms found the packed form corrupts
  resident-expert compute at the model's shapes (the router's input goes non-finite one
  layer below a resident expert; bisected clean→broken exactly at the PW-D merge, with
  PW-C2's tip clean beside it — `docs/research/AI-pw-w1-2026-10-25.md`). Every unit/tiny gate had
  stayed green: their geometries cannot reach the model's, a class of miss the window
  itself now prices. The hotfix keeps all the fmt-15 code and makes it opt-in —
  `COLI_VK_TIER_FMT15=1` arms the packed form (+17.6 % tier capacity at the same bytes
  once its resident-path defect is found and fixed); unset, the f32-scale fmt 7 is the
  standing default again, byte-identical to the pre-PW-D tier. **Superseded by PW-Dfix
  (2026-10-26)**: the defect is found and fixed (the hybrid path's scale stride, not the
  packed form) and fmt 15 is the default again — see the Notes above and
  `docs/research/AJ-pw-dfix-2026-10-26.md`.
- `deepseek-v4-smoke` — the model-scale smoke gate (make target,
  tests/deepseek_v4_smoke.sh): the W1 window's institutional lesson made standing — a
  slice that changes a tier/chain default owes one ~2-minute generation on the real model
  before merge. Runs DeepSeek V4 Flash (MODEL, default the rig's path) on a ~100-token
  prompt for 16 tokens; checks rc=0, a coherent generated_text, and the failure lines
  ("chained block failed", "device is lost", a nonzero failed counter); skips cleanly
  when the model, the Vulkan device or the build is absent, fails when the card has other
  holders.

- `COLI_VK_TIER_DECODE_GROW` (the Vulkan expert tier, default off): demand-growing decode
  residency — the tier's resident set stops being the warm start's fixed one. At the first
  decode-class step the tier probes what the device actually has free (the boot budget could only
  guess at what the chain, the KV mirror and the head take; by now they have taken it) and grows its
  budget into that first, then — only beyond it — retires stream slots one place at a time as decode
  demand installs (`COLI_VK_TIER_DECODE_GROW_GB` bounds both sources,
  `COLI_VK_TIER_DECODE_GROW_RESERVE_GB`, default 0.5, is what the probe leaves for what still
  allocates at decode). The installs rank by the engine's decode-only counts (the `.coli_mfu` table,
  handed over as `VktConfig.decode_heat` through `coli_v4_expert_store_mfu_history`): the cutoff is
  the K-th largest count over the experts the device does not hold — the fork's `cache_reorder`
  rule — and an expert at or above it installs into a grown place, never a victim's (no eviction,
  the warm set stands), while one below it installs not at all at a decode step: the grown room is
  the rank's. `vkt_wants` mirrors the gate and `promote` takes it too where grown room exists, so
  the merged-history warm cannot spend the growth before decode's hot; prefill keeps the standing
  note path. The census's asymmetry answered: the fork's decode grew ~8.3 GiB of MFU-ranked demand
  installs (`gpu_cap=954`) where the port's set was fixed (277 residents, `evictions 0`, decode
  device share 13–22 %). Unit proof (`test_vk_tier` `decode_grow`): free-VRAM growth 6 -> 8 by
  decode-only rank with the below-cutoff routed experts never installed (cutoff 40), slot-beyond
  growth 6 -> 9 with slots 6 -> 3 and the cap refusing the fourth install (cutoff 30), the default
  growing nothing; the report line's `decode grow:` clause is the engagement print. Evidence:
  `docs/research/AH-pw-a1-decode-grow-2026-10-25.md`.
- `COLI_VK_CHAIN_ATTN_FA` (DeepSeek V4/V4.1's chain): the fork's `sparse_attn_fa` tile
  ported onto `vkc_dsv4_attn`'s contract (`chain_dsv4_fa.comp` — same bindings and push
  constants as `chain_dsv4.comp` mode 0, so the one call dispatches either): a workgroup
  Br query heads of one token streams the row list in Bc tiles with the K/V rows staged
  once in LDS (K == V), an online softmax and llama's sink end block, against mode 0's a
  workgroup a (head, row) re-reading every row twice per head (the shader census' ~32x
  the KV bytes). Four builds from the one source, the fork's four: Br 8 prefill, the
  Br 2 decode twin at tokens == 1 (a head's numerics unchanged, heads/2 workgroups),
  each with a KV_F16 twin reading the f16 mirror `chain_dsv4_fa_gather.comp` writes a
  dispatch ahead — the fork's storage-only fp16 (its standing arm) as a read-side mirror
  over this port's fp32 stores: half the KV read bytes, the same numerics class, nothing
  permanent, no writer touched. `1` = tile + mirror (the fork's standing class), `2` =
  tile over fp32 (its KV_F16=0 arm); unset/0 = mode 0, byte-identical, the FA modules
  not even loaded; every refusal (head dim != 512, heads % 8, unaligned q/o/w/c offsets
  or strides, a missing pipeline) falls back to mode 0 — never a misread — and the
  KV-split path (`chain_kvs.comp`) is untouched. Thresholded class where it engages
  (the unit oracle: 4.1e-3 f16 / 6.5e-3 worst against the 8e-3 mode-0 bar, the fork's
  own gate 2e-3; token-exact at tiny holds — the tile cannot engage at the tiny
  fixture's head dim 32). RX 6900 XT, the model's decode geometry: 1920 -> 228 us a
  layer-dispatch (8.4x, ~= the fork's ~10 ms/tok over 43 layers vs the 63.8 ms/tok
  bucket), a 256-row chunk 304 -> 6.0 ms (51x). `VkcStats.attn_fa` counts engagements;
  the grown-scratch pattern (`adec_scratch`) refactored to a second user.
  Report: `docs/research/AG-pw-c2-fa-flash-attention-2026-10-25.md`.
- **fmt 15 — the tier's MXFP4 experts with packed ue8m0 scales** (the parity wave's PW-D
  slice): `VKT_SRC_MXFP4_E8M0` experts (DeepSeek V4/V4.1, Kimi K3, MiMo) now keep their
  group scales on the device **as the ue8m0 bytes the store holds them in** — 1 byte a
  32-input group, 4 to a word — instead of expanding each to f32 at upload. The round
  trip is the identity (the byte's value is the float's exponent field: 2^(e−127),
  exactly what the old expansion wrote), so the packing changes bytes, never values:
  a DeepSeek V4 expert's device payload drops **15.0 → 12.75 MiB (−17.6 %)** — the fork's
  own slab class — and every stream, promote and upload byte for MXFP4 experts drops
  with it; at the same budget the tier holds 1.1765× the experts (both residents and
  stream slots shrink; 277→~374 residents beside 256 slots at the census rig's 7.85 GiB).
  A new device format number rather than a redefinition: fmt 7 (f32 scales) stays for
  `VKT_SRC_MXFP4_F32` sources and the generic dense matmul APIs (which take `float*`
  scales and refuse the packed form); every resident-expert consumer reads the bytes
  with one extract branch — `qmatmul_grp_mx`(+gate_up), `chain_moe_gv`, `chain_moe`,
  `qmatmul`, `qmatmul_gate_up`, `qmatmul_gemm`, `qmatmul_coop`, `qmatmul_grp_gemv` — and
  the CPU host-rows path decodes them the same way. Proof: the packed form's device rows
  are **bit-identical** to the f32 form's over the same codes and scales (the new
  `run_xbatch_mx_pack` case), the ue8m0⇄f32 identity is unit-checked over all 256 bytes,
  and the tiny oracle is token-exact with the tier on fmt 15 (decode, prefill, dmoe,
  bank and the composed legs). The CUDA tier keeps fmt 7 (its ops table has no packed
  form yet); no env, no gate. Report: `docs/research/AE-pw-d-ue8m0-u8-scale-packing-2026-10-25.md`.
- `COLI_VK_CHAIN_ORDER=layer` (DeepSeek V4's chain) + `COLI_VK_DMOE=all` (the dmoe arm's
  multi-layer form): the prompt loop reordered layer-outer — the fork's own prefill
  order ("A true prefill is layer-major: every prompt position crosses this layer before
  the next one begins"), behind a default-off env whose unset value runs today's chunk
  loop untouched. The layer-outer pass lowers each layer's attention mirrors at its own
  head (against a pre-pass snapshot of the window rings — the live `slot_pos` follows the
  earlier layers' chunks), keeps the prompt's streams resident across the layer's pass
  (`ch->xall`; each layer-chunk unit copies its rows in and out of the chunk's scratch),
  and lays the chunks' lists and RoPE tables side by side on the device so a later
  layer's unit reads the chunk it is visiting (`V4cFwd.lbase`). The unit is the chunk
  path's layer body verbatim — the same frames, the same per-row GEMV batches — so at
  `COLI_VK_CHAIN_GEMM_ROWS=0` the reorder is bit-neutral by construction (verified
  bit-equal against the chunk order at the tiny gate) and the default is byte-identical.
  The loop drives the bank's rotation (`vkt_bank_switch` at each layer head, over the
  quiescent tail the layer before left): one bank — or one stream-slot window — serves a
  layer's every chunk before it moves, the at-most-once refill holding per tenure; that
  is the regime S1's chunk leg measured the absence of (chunk-outer order needs the slots
  for the other 42 layers every chunk, so the 3.75 GiB carve and the streaming could not
  coexist). `COLI_VK_DMOE=all` arms the chain's whole lo..L range in one prepare (each
  layer's gate looked up at its visit, hash layers and gate-less layers masked to the
  host's step), declining with one line without the layer order. The tier's books and
  DSpark's taps drain at the loop's wait points (a host-step unit's A1, the split's
  copy-back, each layer tail) where the frames that wrote them are through. Prompts of
  more than one chunk only; the reorder declines to the chunk order (one line) where the
  prompt's streams, lists and tables do not fit beside the chunk's scratch.
- `COLI_VK_TIER_BANK_LAYER` (the routed-expert tier) + `COLI_VK_DMOE_ROWS_MAX` (the
  dmoe arm's prompt path): the VRAM bank and its frame-split cap. The bank is the fork's
  eg2_bank discipline in the tier's own places — one layer's experts planned whole to
  the device, pinned for the tenure, and paid for by an explicit carve of the stream
  slots' budget (256 slots ≈ 3.75 GiB → DeepSeek V4's 256 MXFP4 experts at the standing
  arm), so the bank and the slots never add and a resident keeps its place; the boot
  line ledgers the trade and every decline (out of range, a hash layer, streaming off,
  no room) prints one line and leaves the plan the history's. Because banked experts are
  ordinary residents, `vkt_dev_table` counts them with no new gate code (the dmoe gate
  opens — the POOL_LAYER precedent), and the bank adds the tenure discipline the slots
  never had: a per-layer validity bitmap with at-most-once refill at the routed step
  (post-router, pre-issue, through the bypass group reader), and an explicit switch seam
  (`vkt_bank_switch`) that clears the bitmap, frees the old layer's places at a
  quiescent point and refills the new layer's under the same at-most-once rule — a
  rotation never re-reads what a tenure already read, and the engine's step never
  rotates the bank (the chunk-outer order would thrash a place a layer; the layer-outer
  reorder is what will drive it). `COLI_VK_DMOE_ROWS_MAX=R` caps the rows a dmoe frame's grouped GEMMs may
  carry, `vkc_submit` + `vkc_begin` between row groups (the `vkc_layer_recorded`
  pattern), each group routing its own rows into its own slice of the routed sum — the
  amdgpu hard-recovery boundary (~2–4 s of GPU work in one submission; the armed chunk
  lost the device at model scale) becomes a knob while the bits stay the whole chunk's
  (the split-vs-unsplit unit gate is bit-exact). Both default off, byte-identical; the
  unit gates cover the carve's ledger, the 2-layer rotation both ways, the declines, and
  the split at equal rows, and the tiny dmoe check runs a bank-armed leg token-exact.
- `COLI_VK_CHAIN_DPROF` (the chain, the tier, the V4 CLI bench): G1's slice S0 — the
  instrumented decode window that settles whether the ~200 ms/token fence-wait-versus-
  device-time gap is real before any code slice spends on it. `1` (default unset,
  changing nothing, the output byte for byte) arms three reports over one window:
  DeepSeek V4's chain opens it on a forward of one row (`vkc_dwin`, a decode step —
  the prompt's chunked forwards close it again) and stamps each frame at its submission
  with the role the record site names (`vkc_role`: the dense A1, the shared-expert A2,
  the dmoe path's frame when armed, the forward's closing tail), so the exit line
  `chain decode: N fwd, S submits, W waits, X ms wait (A1 … / A2 … / dmoe … / tail …),
  Y ms device (…), Z ms in vkQueueSubmit` attributes the host's fence waiting to the
  frame it waited for and the device time (the same timestamps `COLI_VK_CHAIN_PROF`
  reads; on without it the device split stays 0) to the same frames; the run's own
  chain line gains the fence-wait count it always counted and never printed
  (`VkcStats.waits`); the tier adds its decode steps' (`S <= VKT_UP_ROWS`, the share
  `vkt_report` already splits) waited / device / CPU ms and the MiB `promote` queues
  over PCIe — H1's traffic term; and the CLI bench prints `v4_dprof decode` with
  wall / block / head / other per token, `block` the one-row forwards' own span, so
  the unattributed pool behind the gap is a difference of printed numbers instead of
  a subtraction PORT_STATUS had to guess at. Counters only, filled where the existing
  ones already tick — no allocation in the frame, submit or join paths, cheap enough
  to leave on in an arm; the chain's test gains the window's case (frames inside it
  counted once each by role, their waits with them, frames outside it counted
  nowhere).

- `COLI_VK_TIER_POOL_LAYER` (the routed-expert tier): the L2 Stage C lever —
  `COLI_VK_DMOE`'s residency activator that is **not a device pin**. `=n`
  (default unset, changing nothing) plans layer n's experts into the host pool
  at the warm start, ahead of the heat history: no device place, no staging
  slot, no prefetch entry is spent, and `vkt_dev_table` counts them anyway (a
  pool resident keeps `dev` 0), so `vk_dmoe.h`'s all-or-nothing gate opens for
  a layer the device tier could never hold whole — the measured reason Stages
  A+B stayed inert at model scale (T-l2-arms-2026-10-24: every D-run declined,
  zero layer steps through the dmoe path, all timing deltas noise). All or
  nothing like the gate it serves: a pool that cannot hold all E of the layer
  places none of them and says so once. `hot_pin` pins the placed layer and
  `promote` skips it, so the tier's own promotions cannot move it up to the
  device and churn the residents there — the exact mechanism that made the
  device-pinned variant a measured negative (`98fcee51`: prefetch 12,644->1,890,
  TTFT x2 on 16 GiB). The pool must be on and hold the layer
  (`COLI_VK_TIER_HOST_GB`; ~3.75 GiB of system RAM for DeepSeek V4's 256 MXFP4
  experts), which is the trade: the layer's visits are PCIe-bound instead of
  device-resident. DeepSeek V4's `VktConfig.stage` stays unset on purpose (the
  staging carve is block-format-gated at two layers and fmt 7 never stages; the
  reasoning now sits beside the config for a future block-format V4). The
  tier's test gains the lever's case: exactly E of the layer planned into the
  pool ahead of the history, resident there with the device's mask empty, the
  table whole for the gate, still in the pool after the books' promotions with
  the device keeping its own residents, and a pool one place short placing
  nothing — the plan then identical, entry for entry, to the lever-free tier's.
- `COLI_VK_DMOE` + `COLI_VK_DMOE_ROWS` (DeepSeek V4's chain): the L2 Stage A
  wiring — DeepSeek V4 joins `vk_dmoe.h`, the shape upstream's own MoE engines
  (olmoe, qwen36, qwen38) already have. `COLI_VK_DMOE=n` (default `0`, changing
  nothing) arms one non-hash layer on the primary device: a step of up to 8 rows
  (decode, a short verify) whose tier holds all of that layer's experts routes
  and computes its routed experts in the dense chain's frame — the gate logits
  (`ffn.gate.weight`, the chain's GEMV) and the router through `vkc_route` with
  `route_bf16_impl`'s exact parameters (sqrt(softplus), the gate bias for the
  pick only, the weights score/sum x `routed_scaling_factor`, no eps), the
  experts through `vkc_dmoe_prepare/on/layer`, the shared expert recorded beside
  them, no wait and no host step at that layer, the join taking `dm.y`, the
  tier's books (`vkt_dev_count`) from the ids after the frame, and
  `vkc_dmoe_upload` at every frame start (after each host layer too — the epoch
  discipline, a layer the host steps through may evict what an in-flight
  frame's table names). A layer the tier does not hold whole keeps the host's
  step (the exit report says so whatever the run did), as do hash layers
  (`vkc_route` cannot express their token table), the second device and
  `COLI_VK_CHAIN_MOE=0`; the arm's parse runs before any `vkc_dmoe_*` call, so
  unset arms nothing and reserves nothing. `COLI_VK_DMOE_ROWS=1` (default `0`)
  lifts the 8-row cap through `vkc_moe_rows`' fmt-7 grouped GEMMs — the same
  chunking invariant `COLI_VK_CHAIN_GEMM_ROWS` documents, so it stays opt-in;
  the tier's `COLI_VK_TIER_PIN_LAYER` (0c6ddae2) is the arm's residency
  scaffolding. The experts' weighted sum is `chain_moe.comp`'s rank order
  against the CPU block's ascending expert id — the chain's float-reassociation
  class, gated by the token-exact oracle, not bit equality. Measured on the
  whole-layer pin variant: **a negative** — a 3.75 GiB all-or-nothing layer
  strangled prefetch and doubled TTFT on 16 GiB (prefetch 12,644->1,890,
  `docs/HANDOVER-2026-10-23.md` 2.3; the disk-load figures live only in the
  `98fcee51` message), so this lands as wiring and alignment, not a TTFT claim;
  the pool-placed lever (Stage C) is untried. New gate
  `make VK=1 deepseek-v4-tiny-check-dmoe` = the tiny check with the arm on
  (layer 1, and the chunk path for the 72-token case), token-exact; the tier's
  test gains the pin lever's plan/table row and the chain's gains `COLI_VK_DMOE`'s
  parse cases and V4's kind-2 router shape against the reference arithmetic.
- `vkc_moe_rows` takes fmt 7 (MXFP4): a prompt chunk's routed experts in the
  tier's native format, through `qmatmul_grp_mx.comp` (the expert batch's
  mode-4 GEMM, in floats — no matrix-unit variant exists for it) beside the
  block formats' and our formats' pipelines, its 36-byte push constant beside
  their 24-byte one. `vkc_moe_rows_ready(7, 7)` turns true and
  `VkcPrewarm.ex_mx` prewarms the pair like `ex_ours`'s. No engine routes a
  chunk through it yet — DeepSeek V4's `vk_dmoe` wiring is the next slice;
  until one asks, every engine's bits are unchanged. The chain's test gains
  the fmt-7 rows against `chain_moe`'s float form of the same experts (max
  |diff| ~1e-9) and DeepSeek V4's kind-2 router (`route_bf16_impl`'s math,
  ties included) against `chain_route.comp`.
- `COLI_V4_FROZEN_PCT` + `.coli_mfu` + `hit_rate_d` (DeepSeek V4): the
  engine-store MFU cache — the fork's cache approach on the port's store
  (S-store map, `docs/research/S-store-mfu-map-2026-10-23.md`). The fork's
  `mfu_table.{c,h}` is lifted as-is: a flat decode-only counter per expert,
  one `mfu_record` per routed selection of a decode/spec token (the token
  seam `v4_vk_token_issue` — the batch/prefill seam never counts), persisted
  as `<model>/.coli_mfu` at store close whenever anything was recorded,
  knob or no knob (the fork's rule: the file is the next run's seed; a run
  that recorded nothing writes nothing — CPU-only and prefill-only runs
  leave no file). On top of it: `COLI_V4_FROZEN_PCT` (default `0` = today's
  exact policy) freezes that percent of each layer's slots, victim-exempt
  and ranked by `.coli_mfu`, riding the existing pin machinery — a separate
  `frozen_count` beside `pin_count` (capped at `slots_per_layer - 6`, not
  the 16-slot pin cap, so 100% lifts to 42/48) in the same `pins[]` row, so
  no new victim selector and the `.coli_usage` pins keep their exact
  semantics; `COLI_V4_PREWARM` ranks a layer by `.coli_mfu` when the
  decode-only history has seen it (the merged usage otherwise) and
  re-stamps LRU age in reverse rank order after the fill — without it the
  fill order leaves the hottest seeds the oldest and the first misses eat
  exactly them (the fork measured this); and the store's stats gain
  `requests_decode`/`hits_decode`, printed as `hit_rate_d=` on the
  `v4_tokens` line always — the decode-only hit rate the campaign's verdict
  is pre-registered on. The mfu table's own decay knob is the fork's
  `COLI_DSV4_VK_MFU_DECAY_SHIFT` (default `0` = no load decay).
- `COLI_VK_TIER_STREAM_BYPASS` (DeepSeek V4): the stream fills' cache-bypassing
  reads and the engine's parallel batch reader — the S1+S2 pair of the L1
  byte-economy map (`docs/research/R-l1-byte-economy-map-2026-10-23.md`). The
  tier's `load_batch` hook existed unused; the engine now fills it, reading a
  group of up to 8 experts at once (the prewarm's parallel-lookup shape), and a
  cold expert of a stream fill is read straight from the disk into a bounded
  stage pool (8 x 16 MiB, 4096-aligned, process lifetime) through
  `coli_v4_expert_store_read_private` — the warm start's reader, which takes no
  lease, no LRU slot and no store counter — instead of through a lease, whose
  every fill evicted a slot the decode hot set or the rows16 pins could have
  kept (~192 GiB of one-shot experts a run through it; the store's hit rate
  stays a real measure of service). An expert the store already holds is still
  leased (a RAM hit beats the disk), `note_routed` keeps the `.coli_usage`
  history whatever loaded the expert, a bypass read that fails falls back to
  the lease, and the bytes are the lease path's bit for bit — so the arm is
  numerics-identical, only which cache sees the bytes differs. Default `0`
  wires no `load_batch` and changes no bit; the tier's run line now carries the
  `R` it settled at (an arm that moves the load path moves `bw_up`, so `R`
  moves with it — arms compare at the same `R`).
- `COLI_VK_TIER_HOT`/`_SCOPE`/`_UPDATE`/`_HOT_HASH`: the routed-expert tier's
  hot set — the history's top share of the resident places, ranked on the raw
  `.coli_usage` counts (the same ranking the warm start uses, never the scaled
  1..31 heat), marked on the slots and skipped by every victim path, so the
  adaptive tail's promotions cannot churn the warm start's head. Default `0`
  is byte-identical (the guards are pure skips); `COLI_VK_TIER_PIN_LAYER`, the
  dmoe arm's lever, is the explicit form (a whole layer pinned and planned
  first), and streaming's staging slots are clamped so they cannot eat the
  frozen section. The tier's report line gains the pin count (`pins N (hot P%
  of K resident places, scope, fixed or re-pinned)`) and a decode-only device
  share (`decode: N of M routed experts on the device`) — the run-level `device
  N of M` is dominated by a prompt's rows.
- `COLI_VK_PROFILE`: one knob for the measured operating points. `RDNA2`, the
  headline value, is the hardware profile tuned on the RX 6900 XT and applies
  the stage-aware best set itself (a queued prompt of 1,000 tokens or more
  takes the ttft set, a smaller one the decode set, a length the engine cannot
  know when the knobs are read — serve, streaming — the balanced set);
  `ttft`/`decode`/`balanced` force one stage's set, `auto` is `RDNA2`'s other
  name. The fills land in unset variables only (an explicit env var always
  wins), one `[VK] profile: ...` boot line says what was applied, and unset or
  `0` is byte-for-byte today's behaviour. The three sets, RX 6900 XT,
  2,515-token prompt / 64 tokens, 28 GiB plan (`bench/up2276/`): ttft
  187.7 s / 0.533 / 305.9, decode 239.5 / 0.670 / 333.5, balanced
  205.7 / 0.557 / 318.9 with the 24 GiB plan budget on the `--memory-gb`/
  `RAM_GB` path where no budget was named. Likely beneficial on other devices,
  but benchmarks are needed to confirm.
- `COLI_VK_MM8`/`COLI_VK_MM8_SPLITK`: DeepSeek V4's fp8 dense projections
  may run on the tiled weight-stationary GEMM `qmatmul_mm8.spv` — the weights
  staged once a tile, the group scale folded at staging, one fp32 accumulator
  an output over ascending k, so the same exact terms as the GEMV's sums in
  another order (a measured envelope, not bit-identical; every tile of the
  table bitwise the frozen one). Opt-in, the default `0` keeping a row's bits
  dependent on its inputs only; `-1` follows the backend's fill rule for
  prompt rows only, exactly `COLI_VK_CHAIN_GEMM_ROWS=-1`, so a verify's rows
  and every decode step keep the GEMV's bits. The split cuts a starved
  shape's reduction into k partial planes summed in ascending k
  (deterministic, never bitwise). On an RX 6900 XT, S 128, the six real
  projection shapes, best tile: the GEMV's 185–241 GMAC/s to 2,107–4,183,
  the most starved (wkv) 574 → 2,107 with the split (experiment record in
  `docs/experiments/mm8-2026-10-22/`).
- `COLI_VK_CHAIN_GEMM_ROWS`: DeepSeek V4's chain prompt rows may take the
  backend's tiled GEMM instead of the per-row GEMV (`-1` follows the backend's
  rule, `N` from N rows; a verify's rows and decode keep the GEMV's bits). On
  an RX 6900 XT a 2,515-token prompt's first token goes from 189.6 s to
  152.1 s median (prefill 13.3 to 16.5 tok/s; experiment record in
  `docs/experiments/gemm-rows-2026-10-20/`); the default stays `0`, keeping a
  row's bits independent of the chunking.
- The Vulkan tier's host pool can size itself from the engine's RAM plan:
  `VktConfig` carries `ram_planned`/`ram_budget`/`ram_spare`, and the pool
  takes at most what that plan leaves unclaimed. DeepSeek V4 passes its
  resolved budget; without the bound the pool granted 25.75 GiB of system RAM
  beside a 17.65 GiB plan and the kernel killed the process. Engines without a
  plan keep the old rule, now also less their cache growth still to come, and
  `COLI_VK_TIER_HOST_GB` still overrides the plan (with a line when it goes
  over). `COLI_VK_TIER_HOST`/`_GB` also gain their missing
  `docs/ENVIRONMENT.md` rows.

- `COLI_VK_STRICT=1`: an opt-in mode that makes a silently lost Vulkan
  capability fatal. One helper (`coli_vk_degrade`) now reports every point
  that would quietly leave the GPU off — a shader absent from the deployment,
  a fence wait that failed, the device lost mid-run, a staged upload's fence
  — naming the operation; under strict it aborts with exit 70 so a broken
  deployment cannot pass unnoticed. Legitimate refusals (a format or tile the
  device never had) and budget fallbacks behave exactly as before, and unset
  or `0` is byte-for-byte today's behaviour. `tests/test_vk_degrade.c` runs
  the class table with no device; `make vk-strict-check` runs the fault knobs
  against a real one.
- SSSE3 integer-dot tier in `c/idot.h`: `maddubs`/`madd` kernels for
  `dense_act_i8`, `dot_i8i8`, `dot_i4i8`, `dot_i4p_u` and `i4p_gidot_rows`
  give pre-AVX2 x86-64 CPUs (SSSE3, no AVX2/FMA) an accelerated path where
  they previously fell through to the scalar reference. Exact int32 sums,
  so every ISA path stays bit-identical to the scalar reference.
- `residency_sim.py --engine olmoe`: the offline residency simulator replays
  OLMoE `ROUTE_TRACE` files with OLMoE's own cache traversal (one expert per
  fetch, immediate admission into the per-layer LRU, 128-row prompt blocks in
  ascending expert id), so expert-placement policies can be compared on a model
  that runs on a CPU-only machine.
- `tok_load` hardening: `tokenizer.json` is validated before it is indexed —
  token ids must be finite integers in range (a negative id indexed below the
  allocation, a fractional one aliased a different token), the containers
  must have their shapes, and an `added_tokens` entry must carry `id` and
  `content` — so a malformed file fails at load with a message instead of an
  out-of-bounds write or a NULL deref
  (`c/tests/test_tok_load_validation.py`). The commit rode in on `main`
  (88c89479) before the port branches split, so no port slice carried it;
  recorded here for the ledger.

## [2.0.0] - 2026-10-06

169 pull requests since v1.12.1, 88 of them from contributors. Every MoE
engine now runs on any GPU a Vulkan driver can see: the routed experts on a
shared device tier, the dense layers on a device chain (all of them, or the
first N that fit), and a second GPU for more experts. Three model families
arrive (MiMo-V2.6, Qwen3-Coder, Qwen-Image-2.1) and one dense checkpoint
(Qwen3.8-27B). Qwen3.8 Flash Next gets int4 experts and speculative decoding
that is on by default. Every text engine serves up to 16 conversations at once.
The release archives carry the GPU backends. Setup is one step, and there is one
decision API (System One).

### Several conversations at once

- **#1955**: every text engine serves several conversations at once (`coli serve
  --kv-slots N`, up to 16), as GLM-5.2 and GLM-5.3 Flash did: qwen36 (Qwen3.6,
  Qwen3-Coder, Qwen3.8-27B), qwen38, OLMoE, Inkling, Kimi K3, MiMo-V2.6,
  DeepSeek V4 and V4.1. Each slot keeps its own conversation's state, and every
  decode step takes the next token of each active request as one batch, so the
  weights and experts a step reads serve all of them. A request gets the tokens
  it gets alone, checked frame for frame on every engine, on the CPU and with
  the expert tier. With more than one slot nothing drafts and the dense chain
  stays off.

### Vulkan on every engine

- **#1830**: every engine's resident matrices run on any Vulkan GPU (fmt 10, 11
  and 12 added), each configuration checked against the engine's own CPU run on
  Lavapipe (`tests/vulkan_engines.sh`).
- **#1834**: tiled GEMMs for prefill in every weight format, and a
  cooperative-matrix GEMM where the device has one.
- **#1840**, **#1843**: a shared routed-expert tier (`vk_tier.c`). It holds a
  cache of experts in device memory, filled from the expert history and adapting
  while you chat, and computes the resident experts of each step as one async
  batch while the CPU computes the rest. First on qwen38 and qwen36, then on
  every MoE engine: GLM-5.2, GLM-5.3 Flash, Inkling, OLMoE, Kimi K3, MiMo-V2.6,
  DeepSeek V4 and V4.1.
- **#1844**, **#1848**, **#1849**, **#1851**, **#1857**: the dense chain
  (`vk_chain.c`), a layer's dense part in one submission, on qwen36, qwen38,
  MiMo-V2.6 (sliding window and sinks on the device), OLMoE, Inkling (and
  OLMoE's PILOT race fixed), GLM-5.2 and GLM-5.3 Flash (shared MLA, DSA, KDA and
  mHC ops), Kimi K3, DeepSeek V4.1 and DeepSeek V4.
- **#1871**: staged device-local uploads for cards without Resizable BAR, where
  the mapped path failed or spilled to system RAM.
- **#1901**: expert streaming for big prompt steps, memory budgets and
  speculative verification on the device.
- **#1909**, **#1913**, **#1916**, **#1918**: a partial dense chain. The first N
  layers that fit go to the device, the CPU runs the rest, and nothing is
  uploaded that the chain will not use, so an 8 GB card with a larger trunk keeps
  the chain and its expert tier instead of losing both. `COLI_VK_CHAIN_LAYERS`
  forces N, `coli plan` predicts it. DeepSeek V4, qwen36 and olmoe, qwen38,
  GLM-5.2 and GLM-5.3 Flash.
- **#1920**: a second GPU for the expert tier (`COLI_VK_DEV2=auto|<index>`) on
  every MoE engine: the experts after the primary device's, each step one batch
  per device, both in flight at once. A failing second device gives its experts
  back to the CPU and the tier goes on with the first.
- **#1942**: the dense chain's layers on two GPUs. With `COLI_VK_DEV2`, the
  layers a partial chain leaves go to the second device instead of the CPU, on
  every chain engine (qwen36, qwen38, OLMoE, MiMo-V2.6, Inkling, GLM-5.2,
  GLM-5.3 Flash, Kimi K3, DeepSeek V4.1 and V4). `COLI_VK_CHAIN_LAYERS2` forces
  how many, `COLI_VK_CHAIN_DEV2=0` keeps them off. A lost second device leaves
  the CPU to run its layers, the recurrent state rebuilt where it was held.
  Checked on Lavapipe opened twice; two real GPUs not measured yet.
- **#1933**: `COLI_VK_KV_COLD=device` (opt-in): with the KV cache split past the
  device's budget, the host's part of the attention runs on the device too, from
  host memory it reads in place, so a step runs in one frame. The prompt gains
  4-6% on a Radeon 780M, decode is slower there (hence off by default); a
  dedicated GPU has not been measured.
- **#1948**: several conversations at once on the dense chain. colibri's
  multiplexed decode (`KV_SLOTS`, one row from each active conversation) runs on
  the device: the batch's matrices as one, each row's attention over its own
  conversation's KV mirror (up to `COLI_VK_CHAIN_MUX`, default 16, beside the
  chain's own) with its own DSA list; two devices and the partial chain too.
  Every frame checked against the CPU's on Lavapipe; not measured with a real
  checkpoint yet.
- **#1934**, **#1935**, **#1936**, **#1937**, **#1938**, **#1939** (@huppiflupp):
  the matrix units for prompt attention and int8/int4 prompt GEMMs on the
  chain, a step's experts as one grouped GEMM (decode: one grouped GEMV per
  phase), qwen36's routing in parallel, and int8 decode GEMVs sized by the
  matrix. On a Radeon 780M with Qwen3.6-35B-A3B the first token of a
  1000-token prompt comes in 9.3 s instead of 12.6, decode 6.1 tok/s instead
  of 5.7, perplexity unchanged.
- **#1954**: on an Intel GPU the dense chain decoded garbage (Qwen3.6 on an Iris
  Xe, the default there). Its pipelines now run at the subgroup size the device
  reports; the device compiles at 8 to 32 lanes, and the chain's GEMVs had run
  at another width than the one they read. On Windows the chain also finds its
  optional shaders (MLA, KDA, mHC, DeepSeek V4, the split KV cache), and the
  split cache frees its host memory with the matching call.
- **#1911**: `COLI_VK_DEV=<index>` picks the device on a machine with two GPUs of
  the same kind; the cooperative GEMM's epilogue stride is aligned to 16 bytes, a
  validation error on some drivers (#1908).
- **#1846** (@crichalchemist): correct expert-batch results under MoltenVK's
  default mode.
- **#1762**, **#1763** (@Kenneth-Javier): the Vulkan loader linked on Windows
  under `-static`, and the Vulkan objects linked into every engine-including
  test rule.

### Models

- **#1813**, **#1819**, **#1820**, **#1827**, **#1835**: MiMo-V2.6 (Flash and
  Pro): the engine, the vision tower, tool calling and Brio mode with logprobs,
  read as released; Pro verified against Xiaomi's reference on the real
  checkpoint, and `coli serve` names the loaded variant.
- **#1828**, **#1829**: Qwen3-Coder-30B-A3B (`qwen3_moe`) on the qwen36 engine.
- **#1777**, **#1779**: dense checkpoints of the Qwen3.6 family on the qwen36
  engine (Qwen3.8-27B), text and images.
- **#1780**: Qwen-Image-2.1, text to image: a C engine, pictures in the
  terminal, the web app and the OpenAI images API.
- **#1951**: Qwen-Image on the GPU and a faster start. The weights load in
  7.5 s instead of 34 (four layers at once, quantized straight from bf16, the
  same int8 bytes). With Vulkan every block of a denoising step runs on the
  device, its attention included, and the VAE decodes there too; a card that
  does not hold the 7.1 GB transformer keeps the blocks that fit and streams
  the others each step. On a Radeon 780M a 512x512 image takes 61 s instead of
  112 and a 1024x1024 step 38 s instead of 67; every stage checked against the
  diffusers reference.
- **#1831**: Qwen3.8 Flash Next's routed experts as int4-g64: 1.4 to 1.56x
  decode.
- **#1832**, **#1917**: speculative decoding with the checkpoint's MTP head,
  lossless, +12-14% on the release; with #1917 it is on by default with prompt
  lookup on every engine that has it (`Q38_MTP=0`, `COLI_LOOKUP=0` turn them
  off), and `coli plan` counts the MTP head's memory.
- **#1814**: Inkling reads the embedding norm under the name transformers 5.18
  writes.

### System One: one decision API

- **#1856**: `POST /v1/systemone`, one decision API, and the Laya decision
  engine; `/v1/brio` is removed.
- **#1868**: GLiNER2.5-Decide as a native decision engine (DeBERTa-v3 and
  GLiNER2's head).
- **#1872**: Clef as a native decision model on qwen36, a joint head over
  Qwen3.8-27B, with a 16-bit dense mode.
- **#1743**: the brio serve gates run in CI against the converted fixture.
- **#1753** (@tarazum): brio normalizes to sum by default and warns when a mean
  mixes option token counts.

### Setup and the CLI

- **#1953**: the release archives carry the GPU backends: every Linux and
  Windows engine built with Vulkan and its shaders, the macOS engines with
  Metal, and a Windows CUDA package (`coli_cuda.dll` for compute 8.0 and newer,
  with colibri, qwen36 and kimi_k3 built to load it). The Vulkan loader is
  opened at run time, so these engines still start on a machine without one,
  on the CPU. `coli setup` uses them without a Vulkan toolchain.

- **#1842**: one-step install and start (`start-here`, `coli setup`), the
  `AI_SETUP.md` guide and an MCP server.
- **#1850**, **#1896**: setup picks the backend that works on the machine: on an
  integrated GPU, Vulkan only where it was measured faster; CUDA only when the
  toolkit builds for the card, Vulkan otherwise, and a failed build falls back.
- **#1903**: an engine already built is brought up to date with `make` before it
  is used (a `git pull` used to keep running the old binary), and `coli logs`
  says where a foreground server prints (#1852).
- **#1919**: a fresh install of Qwen3.6-35B-A3B or Qwen3.8 Flash Next gets a
  starting expert history, so its first run fills the GPU tier from the start:
  on a Radeon 780M Qwen3.6's first run went from about 6 to 11 tok/s.
- **#1817**: in `coli chat`, a line that starts with a picture's path is a
  message, not a command.
- **#1959** (@rudycelekli): `coli setup` counts a server on its port as a running
  colibri only when `/health` answers as colibri does; another program's HTTP 200
  no longer passes for one, and the setup starts its own on the next free port.
- **#1315** (@Avicennasis): resumable, hash-verified qpack installers for
  Hugging Face and static mirrors.
- **#1316** (@Avicennasis): the planner honours cgroup memory limits.
- **#1949**: on Windows every engine has its bare `make <engine>` target (six
  fell to make's built-in rule and linked without CUDA or Vulkan, #1945,
  #1900); `coli setup` prefers an MSYS2 that can build Vulkan over a PATH
  compiler that cannot, and installs libgomp; `COLI_VK_DENSE=0` keeps the dense
  chain off too (on an 8 GB laptop it had taken the expert tier's budget,
  #1900); DeepSeek V4 uses the physical cores on an SMT machine (+10% decode on
  a Threadripper, #1906); `coli plan` leaves a card below an engine's CUDA
  floor out; the server says why its engine stopped (#1941); clearer messages
  for a missing model and a CUDA DLL that does not load.

### The serve contract

- **#1353** (@monotophic): `logprobs`, `top_logprobs` and `echo` on the OpenAI
  endpoints, aligned by raw-stream span.
- **#1794**, **#1767**: Qwen3.6 tool calling, and the template's
  `preserve_thinking` rendered so standard clients get KV prefix reuse.
- **#1802** (@bherald): opt-in strict GLM tool-call parsing.
- **#1765** (@SulimanAbdulrazzaq): GLM-5.3's reasoning stays out of the
  `/v1/messages` answer.
- **#1791**, **#1793** (@Avicennasis): Anthropic image blocks are served and a
  tool result's picture is not dropped; the modalities a model card claims are
  the ones the engine loaded.
- **#1787**, **#1804** (@benmaster82): unsupported OpenAI result shaping is
  refused; the completions keepalive streams as a text chunk.
- **#1782**, **#1783**, **#1785**, **#1786** (@kevin9327): malformed tool calls,
  text parts, tools, messages and image URLs answer 400 instead of 500.
- **#1809** (@Stamina9): non-string brio message text is refused.
- **#1749**, **#1751**, **#1789**, **#1803** (@enitimeago): glm53 reports REUSE
  in detail and logs CANCEL, does not restore a pin over rows another branch
  rewrote, handles cancellation during prompt processing, and continues from the
  cache instead of prefilling again.

### Correctness and security

- **#1930**: hardening of three input paths. The files the engines keep beside a
  model (`.coli_kv`, `.coli_usage.tmp`, `hot_pinned.bin`, `.coli_ckpt/`) are
  opened without following a symlink and only as regular files, so a link
  planted in a downloaded model directory no longer redirects the engine's
  writes. Request grammars are limited to 32767 alternates and symbols per rule
  (past that the walker's index wrapped) and are refused with a message.
  colibri, kimi_k3 and deepseek_v41 check the indexer's and RoPE's head
  dimensions in the config.
- **#1739**, **#1740**, **#1754**, **#1755**, **#1854**, **#1855**
  (@namespaceMarcello): the published advisory fixes carried to glm53, qwen36 and
  deepseek_v41; glm53 refuses f32 tensors shorter than the config reads and
  matrices whose shape differs from it; deepseek_v41 keeps engram lookups inside
  their table; qwen36 gives the same logits at every expert-cache capacity on FMA
  builds and never evicts an expert a MoE run is still reading.
- **#1775**: the DeepSeek V4/V4.1 pre-tokenizer in `tok.h`, so Turkish
  tokenizes as HF does.
- **#1799** (@RayanR000): the DeepSeek V4.1 reference sends top-k ties to the
  lowest index and its indexer never keeps -inf.
- **#1812** (@ZacharyZcR): the shared-expert bindings of DeepSeek V4's fused MoE.
- **#1611** (@Cometbuster4969): OLMoE uses the shared RAM probe, with a
  plausibility floor.
- **#1744**, **#1745** (@kevin9327): a numeric `node_id` no longer kills the
  cluster's topology and health requests, and a manifest that is not a JSON
  object no longer crashes the experiments validator.
- **#1356** (@monotophic): the ablation scoring mode replaced by a checked,
  digest-bound one.
- **#1904**: DeepSeek V4's `PROF` measures the expert wait instead of printing 0
  and folding it into `attention_s` (#1852).
- **#1902**: Windows expert prefetch is asynchronous and its queued work bounded.

### Speed on the CPU

- **#1837**: every engine's per-token projections run per block of rows in
  prefill.
- **#1761** (@mfethe1): a NEON arm for batched `matmul_fp8`, bit-exact, 6 to 10x
  at prefill shapes.
- **#1790**, **#1798** (@RayanR000): the f32 matmul runs eight `fmaf` chains at
  once with the same bits on every FMA build, and one vectorized f32 matmul
  serves quant.h, olmoe, inkling and qwen36 (#442).
- **#1773** (@JackKnifeAI): glm53's dense prefill batched, bit-identical per
  token.
- **#1784** (@kreuzzelg): qwen36's DeltaNet layer on the card
  (`Q36_DN_GPU=1`), expert homes per layer range (`QT_HOME=layer`), the shared
  expert offered on request.
- **#1323**, **#1343** (@Avicennasis): qwen36 reads routed experts from a qpack
  container through bounded Metal slots, and MLX-affine dense weights and norms.
- **#1261** (@Kenneth-Javier): an optional explicit AMD XDNA2 lane for the GLM
  shared expert.

### Build, tests and CI

- **#1758** (@Kenneth-Javier): header prerequisites generated with `-MMD -MP`
  (#1741).
- **#1845**, **#1912**: the sanitizer runs and the bf16 gates hold on AVX-512
  runners, whose CPUs keep bf16 on the CPU.
- **#1914**: the Windows UCRT64 job's limit from 35 to 60 minutes.
- **#1795**, **#1821**, **#1836**, **#1839**: four flaky tests made
  deterministic.

### Docs

- **#1897**, **#1833**: the README rewritten for the release (one-step setup,
  models per machine, GPUs, System One) in five languages, with the site.
- **#1768**, **#1776**: every engine in the environment reference, DeepSeek V4.1
  in its own section, and the weights-from-disk options.
- **#1788** (@jamshaid120): duplicate entries removed from the DeepSeek V4 docs.
- **#1801** (@benmaster82): the web app's image alt count and German image
  labels.
- **#1738**: the 1.12.1 entry's pull request count corrected.

## [1.12.1] — 2026-09-24

96 pull requests since v1.12.0, 80 of them from contributors. Two tokenizers
brought back to the reference, brio on the ninth engine, `coli chat` working
again at the default context on two families, and a placement decision that
is now measured on the card in front of it instead of predicted.

### Tokenizers, measured against the reference

- **#1654**: qwen36 tokenized differently from HF `tokenizers` in two ways.
  An added token right after punctuation was encoded as text (`X.<|im_end|>`
  was 7 tokens instead of 3, every chat turn ending in punctuation paid +4,
  #1653), and a whitespace run followed by a non-space was one piece where
  the regex's `\s+(?!\S)` leaves the last char to the next one, so every
  indented line of code tokenized differently. Measured on the real
  vocabulary: 2,803 lines and blocks of code, Markdown, Chinese and
  Japanese went from 757 identical to 2,803, with 5.4% fewer tokens.
- **#1656**: OLMoE's `tokenizer.json` has no Split, a bare ByteLevel with
  `use_regex`, for which HF runs the original GPT-2 pattern; `tok.h` applied
  cl100k. A GPT-2 family in `tok.h`: 1,560/1,708 identical before, 1,708/1,708
  after. The same measurement on GLM-5.2/5.3/5.3-Flash, DeepSeek V4 and V4.1,
  Inkling and Qwen3.8 came back identical on every case.

### Brio and the serve contract

- **#1662**: `POST /v1/systemone`, the request and the reply of TypeSafe's
  Jev API, served by the brio channel: a client written for it points at
  colibri and changes the base URL. `noul` is a yes/no question, `choice`
  scores the labels with their descriptions in the text, `score` the level
  numbers with the expected value and the legend; `confidence` by their
  documented formula. Any `model` name is accepted on that route. Measured on
  the real Qwen3.6: the three-question example of the docs in 1m46 with the
  state read once.
- **#1655**: the DeepSeek V4 engine speaks the numeric channel (`logprobs=k`,
  `pin=1`, `max_tokens=0`), so `/v1/brio` works on the ninth engine instead
  of answering 500 (#1648). The head that used to keep only its argmax now
  returns the whole row; `ECHO` per prompt position during prefill, the
  prompt-end scores kept with a state snapshot on `pin`, and a logprob tail
  on every `DATA` frame during generation. The tiny fixture pins that the
  best `ECHO` token equals the greedy token from the same prefix, and that
  the pinned predictor equals a cold prefill's.
- **#1659**: qwen36 and qwen38 refused a request when `prompt + max_tokens`
  exceeded the context, and the gateway's default budget for these two
  families is 8192, the whole default context: every request without
  `max_tokens` and every `coli chat` message answered 400 on a two-token
  prompt (#1641). `max_tokens` is now a ceiling, clamped to the room the
  prompt leaves, as GLM and DeepSeek V4 already did; only a prompt that does
  not fit is refused. `docs/api.md` states the rule, `docs/qwen38.md` names
  `Q38_MAXT` as the variable `--ctx` becomes.

### The dense trunk in VRAM, measured before it is placed

- **#1657**: qwen36 offers the rest of its dense trunk to the VRAM placer:
  the DeltaNet out_proj (`dnout`), the attention q/k/v/o (`attnproj`) and
  the shared expert (`shexp`), about 650 MB more of int8 on the 35B beside
  `lmhead` and `dnproj`. Measured on four Tesla M10 by the reporter of
  #1652, every placed component ran slower than the CPU (lm_head 68.8 ms
  against 41.7), so the engine now times one GEMV both ways at startup and
  withdraws the whole automatic placement when the GPU loses, giving the
  VRAM back to the experts: `auto` equals `off` on that box, byte-identical
  output. A hand-written `COLI_PLACE` stands; `COLI_TRUNK_PROBE=0` trusts
  the placer.

### Performance

- **#1664**: qwen36's dense trunk and routed experts multiply with integer
  dot products. The activation is quantized to int8 once per call and the
  weights, int8 rows or int4 planar blocks, meet it with maddubs / vpdpbusd
  instead of a float conversion per weight; the integer kernels move from
  `quant.h` into `idot.h`, shared by every engine. Measured on the 35B, 8
  threads, every expert resident: decode 6.71 to 8.23 tok/s (+22.6%), lm_head
  12.6 to 10.1 ms/token, the expert compute 22.7 to 15.6, for +1.3%
  perplexity on 4 x 512 tokens. Both are the default (`COLI_DENSE_IDOT=0`,
  `QWEN_EXPERT_ACT=f32` restore the f32 kernels). `COLI_DENSE_BITS=4` with
  `COLI_DENSE_INT4=<components>` stores part of the trunk as int4 in blocks
  of 64: opt-in, with the perplexity it costs per component in the docs
  (lm_head alone +2.4%, everything +10%).
- **#1668**: qwen38's dense trunk (553 matrices, 3.6 G weights, 8 GiB of
  BF16 read on every token, more than the ten routed experts) is kept on the
  CPU as int8 rows with the BF16 copy released, and multiplied with the same
  integer kernels; the routed experts' e4m3 blocks are decoded eight at a
  time in registers and multiplied with FMA instead of one table lookup per
  weight. Measured on the released Qwen3.8-Flash-Next-FP8, 8 threads, RAM
  LRU 96 per layer: decode 0.61 to 1.42 tok/s, the trunk 434 to 85 ms/token,
  lm_head 76 to 13, the expert GEMVs 388 to 140, peak RSS 32.2 to 28.5 GB;
  prefill of 512 tokens 495 to 149 s. Perplexity on 4 x 512 tokens +0.5%
  (two chunks lower, two higher); the vector FP8 kernel alone reproduces the
  BF16 run to four decimals. Both are the default (`Q38_TRUNK_CPU_INT8=0`
  keeps the BF16 trunk, `Q38_FP8_KERNEL=scalar` the table kernel).

### Performance, from contributors

- **#1606**: the K1b grouped int4 family gets a multi-row tile and AVX-512
  and AMX arms, and is no longer switched off on AVX-512 builds; exact on
  all eight engines on a 16-core AVX-512 host.
- **#1239**: an SSE4.1 tier for the olmoe and qwen36 int8 GEMV, for hosts
  with SSE4.1 but no AVX2; on the Sandy Bridge of #1652 decode went from
  2.45 to 3.54 tok/s.
- **#1313**: `matmul_fp8` computes four output rows per pass under clang,
  where the contraction makes it bit-exact; GCC keeps the one-row kernel.
- **#1612**: qwen36 gains the GLM engine's `CACHE_ROUTE` lever, with the
  VRAM tier as the first residency level, opt-in.
- **#906**: `DEGRADE_ZERO`, an opt-in policy that zero-fills a missed
  expert slot below a gate-weight threshold instead of blocking on the
  load (#865).
- **#1677**: qwen36 projects a prompt's DeltaNet inputs (qkv and z) on the
  card in blocks of up to 256 rows instead of one row at a time; a 259-row
  prefill makes 2 projection calls instead of 259, with the convolution
  history and the recurrent state checked against the CPU run. The paired
  microbenchmark on an RTX 4070 read 4 to 10x per projection.
- **#1674**: qwen36's attention projections the tier placed in VRAM answer
  a whole prompt batch with one call per matrix; a failed call turns only
  that handle off and the prompt continues on the CPU.
- **#1676**: Kimi K3's streaming CUDA expert keeps the gate, up and SiTU
  intermediates on the device and applies down there (one fused entry
  point, optional in the DLL: an older backend keeps the three-call path).
- **#1673**: the streaming MXFP4 matmul reuses one grow-only device scratch
  per card instead of allocating and freeing weights and scales on every
  call.
- **#1559** (kreuzzelg): `convert_qwen36.py --down-bits 8` writes the mixed
  expert layout, int4 gs64 gate/up and int8 down in one slab (5.7 bits per
  weight against gs64's 4.5); the engine tells it apart by size and reads
  each matrix in its own format on the CPU path, and refuses the VRAM tier
  with a line. It is the knob behind the #1370 numbers: on wikitext-2 the
  int8 down alone recovers a quarter of the gap between gs64 and all-int8,
  the rest sits in gate/up. A measurement tool and a middle step, not the
  answer to the gap.
- **#1730** (mfethe1): DeepSeek V4's FP4 expert kernels, the prefill batch
  and the decode matvec, get a NEON arm; arm64 used to take the scalar
  arm, which is why Apple Silicon prefilled at decode speed (#1696). Bit
  identical to the scalar arm, and the ARM CI job now checks that on every
  change; 17 to 22x on the kernel at the V4 expert shapes on an M-series
  Mac, as measured by the author.
- **#1716** (jtinbergen): qwen36 quantizes its dense weights to int8 while
  loading instead of keeping an f32 copy first, and converts f16/bf16 with
  SIMD. On the 35B the resident set after load goes from 9.2 to 4.8 GB;
  the generated text and the perplexity are identical to before.
- **#1286** (cameron): the grouped int4 GEMV and the fused gate/up GEMV get
  an SSE4.1 arm for CPUs without AVX2 (Ivy Bridge and older). It vectorizes
  across output rows, so each lane runs the scalar row's exact sequence and
  the result is bit-identical; forced-SSE4.1 tests at -O1, -O3 and without
  FP contraction pin it. 2.2 to 2.7x on the isolated kernel on a dual
  E5-2680 v2.
- **#1686** (DebugSultan): qwen38's prefill chunk (`Q38_PREFILL_BATCH_ROWS`)
  and workspace (`Q38_PREFILL_WORKSPACE_MIB`) are runtime knobs, the expert
  load batch is no longer capped at top-k, and the QSA ranking and
  attention run per position in parallel at prefill. Measured on the
  released checkpoint on top of the int8 trunk: output byte-identical at
  every chunk width, no speed change on our 16-core server; the knobs are
  there for hardware where the chunk binds.

### Fixed

- **#1650** (bokiko): a Qwen3.8 pin snapshots the recurrent and PLE state
  but reuses the live attention and indexer rows; after an unrelated prompt
  overwrote those rows, returning to the pin could change brio logprobs
  without a warning. The engine now records the token identity of the live
  rows (`kv_prefix.h`) and refuses a stale pin or prefix restore; image rows
  are tainted. Wire regressions run on the BF16 and FP8 fixtures.
- **#1626**: `SNAP` is the model directory for every non-GLM engine, so
  `coli run` stops handing them a leftover environment (#1600).
- **#1604**: glm53 honours `Mat.resident` in the Vulkan gate and frees the
  Vulkan handle in `mat_release`.
- **#1321**: glm53 sizes its expert cache around the model rather than
  around `MemAvailable`, which the page cache had been inflating.
- **#1588**: qwen36 refuses loudly on a failed encode-buffer realloc instead
  of writing through NULL.
- **#1546**: `coli convert` routes OLMoE to `convert_olmoe_merged.py`.
- **#1630**: olmoe emits the `ROUTE_TRACE` records it announced; the stream
  used to be a zero-byte file.
- **#1610**: `v41_dsml.py` is staged during installation (and the nix flake
  bumped).
- **#1511**: the GPU test suite builds under HIP on gfx1151.
- **#1658**: `test_mem_available` compared two reads of available memory
  with `==` and failed on a busy Windows runner; a quarter of a GB of
  tolerance.
- **#1670**: DeepSeek V4.1 read only its argv cache cap, so `RAM_GB=120`
  on a 128 GB box left the engine at eight expert slots per layer and
  23.8 GB of RSS (#1666). With `--cap` omitted, `coli chat`, `coli serve`
  and `coli web` now size the cache from the resource plan, with `RAM_GB`
  or `--ram` as the budget; an explicit `--cap`, a measured profile and an
  auto-tier plan keep precedence.
- **#1671**: DeepSeek V4.1 treats `max_tokens` as a ceiling like the other
  engines (#1641): a fitting prompt with a large request generates what
  the context leaves, a score-only prompt may fill the context, and a
  prompt one token over it is refused instead of silently truncated.
- **#1675**: resident MXFP4 tensors on CUDA carried O float scales where
  the kernel reads O x ceil(I/32) exponent bytes: short buffers were
  over-read and long ones truncated. One format-aware size for upload,
  refresh, accounting and release.
- **#1678**, **#1679**, **#1680**, **#1682**, **#1683**, **#1684**: the
  Qwen CUDA tier's lifecycle, end to end. Shutdown releases every resident
  expert, projection handle and host table after parked callers resume;
  a failed gate, up or down upload frees what it had already allocated;
  the expert budget charges the three scale buffers at their own sizes
  (two experts used to be admitted where one fit); a failed result
  collection stops inference instead of publishing a partial MoE sum; a
  failed or explicitly disabled tier start unwinds its storage and
  synchronization objects, and a second init cannot overwrite a running
  tier; the CUDA backend validates the whole device list before touching
  state and keeps live contexts on a repeated init. Fault-injected on the
  fake backend, then run together on an RTX 4070 under compute-sanitizer
  with zero errors and zero bytes leaked.
- **#1669**: `test_systemone_api` imports its scoring engine relative to
  its package, so an installed `tests` package no longer breaks discovery.
- **#1697** (kevin9327): the dashboard redesign had dropped the reasoning
  stream: thinking tokens arrived on `delta.reasoning_content` and vanished,
  the bubble stayed empty until the answer and a stop during thinking lost
  the turn. The stream is read again, rendered as its own folding block,
  counted in the rate and the time to first token, and a unit test pins the
  split.
- **#1693** (namespaceMarcello): with `PILOT` on, OLMoE could read the same
  expert twice, once from the prefetcher and once from the forward pass,
  into two slots; a slot being read now keeps a reservation in the index
  (the `colibri.c` pattern) and the second caller waits for the first read
  to publish. Three model-free scenarios pin it.
- **#1695** (namespaceMarcello): the prefill echo state and `serve_echo` sit
  under the same `QWEN36_NO_MAIN` guard, so the segment build no longer
  warns about a function it never gets; the full build is byte-identical.
- **#1724** (GenericRikka): Qwen3.6 decoded `<think>`, `</think>` and the
  tool tags to nothing, because they live only in the tokenizer's
  `added_tokens`; with thinking on, the closing tag never reached the
  gateway and the whole answer came back as `reasoning_content`. The
  non-special added tokens are decoded now; special ones such as
  `<|im_start|>` still decode to nothing.
- **#1734** (tarazum): stopping `coli serve` closes the engine's stdin and
  waits for it to exit on its own before the hard-stop ladder, so the
  engine's teardown runs; qwen36 never saved its `HEAT_FILE` under `coli
  serve` (#1733). On Windows the gateway handles SIGBREAK and the engine
  runs in its own process group.
- **#1726** (kevin9327): Inkling measured no RAM on Windows and sized its
  expert cache to 16 per layer; it uses the shared probe now, which on
  Linux and macOS reads the same numbers as before.
- **#1735**: on GNU Make 3.81, the system make on macOS, `.build-config`
  was never written and every build relinked (#1732).
- **#1731** (bokiko): the DeepSeek V4 CUDA object rebuilds when the nvcc
  command changes, so a new `CUDA_ARCH` no longer links the old object.
- **#1728** (crichalchemist): `make test-c VK=1` built 43 test binaries
  without the Vulkan object; they link it now.
- **#1712** (kevin9327): Kimi K3, Inkling and OLMoE now treat `max_tokens`
  as a ceiling like the other engines; `coli chat`'s default of 16384
  answered 400 on every Kimi and Inkling message against their 8192-token
  window.
- **#1713** (kevin9327): `coli plan`, `doctor` and `--auto-tier` export the
  variable that actually sizes the expert cache on Kimi K3
  (`K3_EXPERT_GB`) and GLM-5.3 (`GLM53_EXPERT_GB`); only `RAM_GB` was
  exported, which neither engine reads as the cache size.
- **#1711** (kevin9327): on Windows, a Kimi K3 `CUDA_DLL` build and a HIP
  host were refused by `--gpu` as CPU-only; the probe reads the backend DLL
  name the host was built with, and the launcher maps `--gpu` onto Kimi's
  `K3_CUDA`.
- **#1710** (kevin9327): a `tools[]` entry whose `function` is not an object
  answered HTTP 500 from the GLM and DeepSeek renderers; it is the 400 that
  `generation_options` already had.
- **#1721** (monotophic): every frame the gateway writes to the engine is
  checked, short writes are completed, and a failed `CANCEL` or `STOP`
  drops the request's pending entry and answers a named 500 instead of a
  silent close.
- **#1714**, **#1719** (benmaster82): the brio options form pins the shared
  state, so per-question requests on one document read it once; the web
  page can stop a scoring run, and duplicate options are removed on both
  clients.
- **#1709** (kevin9327): regenerating a turn with pictures sends them again
  and leaves the composer alone.
- **#1646** (Stamina9): qwen38 says once, on stderr, why the parallel expert
  read path is not taken (disabled, cache smaller than the route, no FP8
  scale bank, repeated expert, converted layout).
- **#1708** (wittchen): every `VK=1` build of glm53 failed to compile on a
  misplaced parenthesis.
- **#1707** (namespaceMarcello): the DeepSeek V4 unit objects rebuild when
  the build flags change, so a CUDA engine build followed by `make test-c`
  no longer links the wrong objects (#1702).
- **#1715** (namespaceMarcello): seven GLM-5.3 harnesses matched the
  unittest glob and counted as zero tests; they are renamed, a skip exits 2,
  the two tiny oracles run in CI, and a discovery test catches the next
  empty module (#1700).
- **#1622**: DeepSeek V4's REAP checkpoints store each expert as six
  per-matrix records; the engine read them through buffered pread and
  counted every one as a direct-I/O fallback (36% of expert reads on the
  150B, #1615). Each segment now goes through the aligned direct window,
  with a regression on a generated per-matrix fixture.
- **#1597**: a replayed tool call whose `arguments` parsed as JSON but was
  not an object (`"[1, 2]"`, `"5"`) answered HTTP 500 from the GLM renderers
  before the engine was asked anything; it renders the call without
  arguments, as every other renderer already did.
- **#1624**: the five gcc 13 warnings left in `make check` are gone, and
  `st_index_load` refuses an index path that would not fit its buffer
  instead of opening a truncated one, with a long-path case in the tests.
- **#1651**: a `pyflakes` pass over the launcher, autotune, the family
  registry and the qwen36 converter: a `measure()` defined twice, a
  `readline` import without a fallback, a stray f-string, dead variables.
- **#1580**: `make qwen36 CUDA_DLL=1` on Windows reached GNU make's implicit
  rule and built a CPU-only binary; a bare `qwen36` alias, a `.build-config`
  prerequisite so a CUDA_DLL change rebuilds, a loader-against-header parity
  test, and the Windows CUDA tier documented.
- **#1556**: `coli plan` on macOS said "no supported GPU detected" on every
  Mac; it now lists the Metal device by name, as identity only, without
  pretending unified memory is a VRAM budget.
- **#1691**: the installed launcher invoked as `/bin/coli` or `/sbin/coli`
  on a merged-/usr system derived `/libexec/colibri` instead of
  `/usr/libexec/colibri`, because `abspath` kept the alias (#1689,
  florin65's patch): `realpath` first. A test runs the launcher through
  such an alias, and another checks that every root module the launcher
  reaches is in the `make install` list, the gap #1610 closed by hand.

### Tools and the gateway

- **#1425**: a general GGUF reader, pure stdlib, and a converter from GGUF
  OLMoE checkpoints to a colibri container, with the numerical evidence in
  its own CI job.
- **#1497**: opt-in prompt-injected tool calling for the families without
  native tool tokens (OLMoE, Qwen3.6), behind `COLI_TOOL_FALLBACK=1`, with a
  two-turn end-to-end test.
- **#1355**, **#1357**: durable per-request results and strict stdout
  classification in the eval harness, and the logprob-gap check gated on
  the engine preamble.
- **#1687**: `GET /metrics` in Prometheus text format, behind the API key:
  four gauges, six outcome counters and four histograms (queue wait, slot
  occupancy, first output, engine call), no request labels, no new
  dependency. The admission scheduler distinguishes completion, failure
  and cancellation, lets a request use a free slot that no earlier waiter
  reserved, and joins the keepalive pump before the slot is released.
- **#1717** (enitimeago): the web chat offers Continue on the last
  assistant message when it stopped at the token limit, by hand or on an
  error, and only when `/health` says the server continues assistant
  turns (#1699).
- **#1402** (enitimeago): a request whose last message is a non-empty
  `assistant` turn continues that turn instead of answering in a new one, on
  `/v1/chat/completions` and `/v1/messages`, for all nine families (Kimi K3
  frames the open turn engine-side); the prompt ends inside the turn as the
  official template renders it without a generation cue. On by default,
  `COLI_CONTINUE_ASSISTANT=0` restores the old behaviour; refused together
  with tools or a turn ending in whitespace, with a 400 that says why. Each
  renderer is pinned against the vendored template (#1401).
- **#1102** (monotophic): checkpoint-faithful FP8 containers that store
  `kv_b_proj` as fmt=8 could load but not decode attention; the absorb path
  now decodes fmt=8 on CPU (bit-exact against the reference) and CUDA
  (within the documented tolerance), and the kv_b sharding refuses by name
  the formats it cannot serve, which also closes two silent misreads of
  fmt=5 and fmt=6.
- **#1395** (rybruscoe): `COLI_EXACT_VERIFY=1` makes the speculative verify
  batch token-exact against sequential decode, at a measured cost on the
  dot itself; off by default, the default path is unchanged.
- **#1720** (monotophic): a request carrying `seed` is accepted and the seed
  ignored, as `docs/api.md` now says, instead of a 400; no determinism is
  implied.
- **#1605**: `ORACLE_STRICT=1` makes a GLM oracle comparison exit non-zero
  when it fails, token-exact by default with `ORACLE_TF_MAX_MISMATCHES` for
  the documented teacher-forcing allowance; references are validated before
  the comparison and non-finite logits cannot pass. Both oracle CI jobs run
  real-process regressions against it.
- **#1705**: `tools/benchmark_baseline.py`, a collection protocol on top of
  the HTTP harness for a repeated three-engine serving baseline: one frozen
  manifest (hardware, model and template identity, per-engine launch
  settings, cache and speculation policy), a rotating plan over a
  concurrency matrix, one collector per engine and round that manages no
  server, and a comparison that keeps failed and missing cells visible and
  distinguishes matched artifacts from deployment comparisons. No results
  are bundled and no ranking is emitted.
- **#1688**: `tools/benchmark_http_serving.py`, a stdlib HTTP streaming
  benchmark over fixed JSONL conversations: closed-loop or paced arrivals
  (periodic or Poisson, seeded), warmup separated from measurement,
  first-output and duration SLOs, latency percentiles and usage-based
  token throughput; a truncated or malformed stream is a failure, not a
  sample.

### Docs

- **#1639**, **#1644**: the README shows brio mode and the dashboard as it
  is: the workspace, the Brain page (the measured expert atlas as a cortex,
  and a region inside it) and the Profiling page, in four languages;
  `docs/api.md` describes the four pages instead of the old console.
- **#1492**, **#1643**: a Japanese README, and its banner at the shipping
  version, which the banner test now checks in every language.
- **#1634**: the multi-disk guide states measured gains and limits instead
  of "twice the bandwidth", with Bash and PowerShell examples.
- **#1617**: connecting the pi coding agent to `coli serve`.
- **#1619**: `expected_bytes` identity versus physical extent for
  int4-rans256-g0 (#1273).
- **#1618** (bherald): `docs/qwen38.md` no longer calls the engine text-only;
  the vision tower and the gateway image path shipped in 1.12.0.
- **#1649**, **#1647** (Suraj2105-1): the musl CI job runs on Alpine 3.24
  and the release pipeline on Node.js 22, ahead of the 3.21 and Node 20
  end of life.
- **#1568** (Yoruxyv): an Indonesian translation of the dashboard.
- **#1681** (XBold): the README and `docs/qwen38.md` no longer say Qwen3.8
  has no GPU backend; the CUDA VRAM expert tier and the int8 trunk in VRAM
  shipped in 1.12.0.

## [1.12.0] — 2026-09-20

81 pull requests since v1.11.0. A new way to ask a model a closed question,
a redesigned dashboard and landing page, and a long run of small failures
that used to answer 500 or die on a locale.

### Brio mode: score a closed set instead of generating

- **#1632**: brio mode, on all nine engines. Hand the engine the options an
  answer is allowed to take and it reports the probability of each one
  instead of writing the answer: the option tokens are read, not sampled,
  so `completion_tokens` is 0 and no reply can fall outside the list. It is
  opt-in per request through two `SUBMIT` keys, `logprobs=k` and `pin=1`;
  without them every frame is byte-identical to before, which is asserted
  per engine rather than claimed. `max_tokens=0` became legal, but only
  together with `logprobs>0`.
- The shared contract is three headers: `decode_batch.h` for the logprob
  tail, `serve_codec.h` for the wire, and `pin_pool.h` for nested state
  snapshots, so a request can keep one photograph of the shared
  instructions and a deeper one of the instructions plus the question. With
  one level the question is re-read once per option; with two, four items
  cost 176 tokens instead of 496.
- `kv_prefix_holds()` is the guard that makes the snapshots safe: a
  snapshot is reused only when the prefix record still holds the same ids,
  because a K/V bank can be dropped between two options.
- Exactness is measured, not asserted: the logprobs read from a snapshot
  match a cold recomputation to 0.00e+00 on all nine tiny fixtures, and on
  the two real checkpoints available (qwen36 at 22 GB and DeepSeek V4.1
  Flash at 476 GB).
- Three clients: `POST /v1/brio` on the gateway, `/brio` in `coli chat`,
  and a page in the dashboard. `docs/brio.md` has the request, the reply,
  the normalisation choice and the cases where the mode does not help.
- The endpoint takes three forms. `options` is one closed question.
  `questions` is many questions on one state, each with its own options,
  with the state photographed once and the snapshots ordered by the server.
  `schema` is an object of field to allowed values: the server writes the
  JSON skeleton and fills it one field at a time, so the object is valid by
  construction and every value is one the caller allowed, each with its own
  probability and entropy. Both were measured before they were exposed: the
  5.7x and the 2.4x above are these two forms.

### The dashboard and the landing page

- **#1633**: the web dashboard is redesigned around a workspace and a
  navigation dock, with a brio page that reads a document once and asks it
  several questions, each with its own option set, and a light and dark
  theme.
- **#1635**: the landing page lists the models as a searchable list instead
  of a card grid, gains a brio section, and gets a light and dark theme
  built on the mechanism proposed in #1551. The shipping version and the
  family names are generated from `c/version.py` and `c/family_registry.py`,
  so the page cannot claim eight families again while nine are running.
  The hero plays a recorded session rather than a mock-up.

### Performance

- **#1477**: one routed-expert kernel, `expert_ffn.h`, shared by the MoE
  engines and used by qwen36 first: int4 kept planar in RAM instead of
  unpacked to int8, and two OpenMP regions per layer instead of three per
  expert. 12.8 to 15.7 tok/s with the resident set down from 29 to 17 GB,
  output identical.
- **#1424**: a CUDA VRAM tier for Qwen3.8-Flash-Next, 43 % on one 8 GB card
  and 60 % on two.
- **#1553** and **#1558**: the previous turn's KV is reused instead of
  re-prefilling the transcript, on qwen36, olmoe and DeepSeek V4.1, with a
  resumed prefill that is exact.
- **#1521** and **#1524**: the mHC mix and the KDA convolution and head
  loops run in parallel, bit-identical, for 3.9 % and 3.0 %.
- **#1517**: the four engines that never sized their OpenMP team now do.
- **#1522**: the DeepSeek V4.1 expert stream can be read from more than one
  drive; **#1455** weights glm53 expert reads by disk and honours
  `COLI_MODEL_MIRROR`; **#1543** fixes the V4 mirror cache on unified memory.
- **#1495**: less overhead in the sparse router's top-K selection.

### Fixed

- Requests that answered `500 engine failed` and now answer properly:
  a non-object `json_schema` (**#1587**), an unpaired surrogate escape
  (**#1589**), a non-object `tool_choice.function` (**#1598**), and a tool
  call whose arguments are not an object.
- **#1595**: the grammar draft walker switched itself off after about sixty
  repetitions. **#1596**: a nested array schema doubled the compiled
  grammar at every level.
- **#1483** and **#1514**: olmoe, inkling and glm53 refuse an over-long
  prompt with `CONTEXT_EXCEEDED` instead of failing late.
- **#1549**: the lazy shard-mapping table in `st.h` was published without
  synchronisation and glm53 reached it from an OpenMP region.
- **#1557**: a truncated multibyte tail made the qwen36 tokenizer read past
  the prompt. **#1530**: an integer overflow check in `kimi_k3.c`.
- **#1631**: `coli serve` reaches the expert-history save when it is stopped
  with SIGTERM, not only on Ctrl-C. **#1628**: the expert grid is resent
  after every turn, so the dashboard stops showing the cold snapshot
  forever.
- **#1608**: `coli doctor` matches core tensor roles by component instead of
  by one family's spelling.
- **#1526**, **#1584**, **#1585**, **#1536**: the planner, the auto-tuner
  and the registry agree about which engine is running, and stop advising
  GLM-only knobs on every family.
- **#1489**: `coli bench` ran the GLM engine on any model. **#1503**: every
  engine is handed its model directory through `SNAP`. **#1486** and
  **#1488**: a directory without `config.json` names no engine, and
  `coli convert` refuses an output directory that already holds one.

### Windows, macOS and locales

- **#1515**, **#1560**, **#1561**, **#1562**, **#1516**: the chat, `coli
  run`, `coli tune` and the datapoint harness no longer die when an engine
  line, a prompt or a dash does not fit the console code page.
- **#1537**, **#1579**, **#1535**: the qwen36 CUDA_DLL build on Windows gets
  its tier, is recognised, and the device probe loads the backend before
  counting devices. **#1563**: the Inkling dense int4 converter finishes.
- **#1599**: MacPorts libomp built every macOS engine single-threaded.
  **#1548**: Metal falls back to `MTLCopyAllDevices` when there is no
  system default device. **#1504**: olmoe measures available RAM on macOS
  and Windows too.

### Diagnostics

- **#1494**, **#1506**, **#1512**: `PROF` reports block time, head time,
  matmul, attention and lm_head, at microsecond resolution, on deepseek_v4,
  olmoe and qwen36. **#1555**: `CONSIST=1` checks prefill against decode.
- **#1482**: configurable generation statistics in `coli chat`, with exact
  token throughput when the server reports it.
- **#1468**, **#1487**, **#1480**: a failure in the MoE step, a missing core
  tensor and duplicate tensor names are diagnosed by name instead of by a
  generic message.

### Docs and licence

- **#1540** and **#1541**: the copyright holder is named and a `NOTICE` file
  is added.
- **#1294**: a reproducible benchmarking protocol; **#1508**: a GPU-backend
  datapoint needs a correctness line to be accepted.
- **#1471** and **#1473**: the expired Discord invite is replaced in all
  four READMEs and on the site.

## [1.11.0] — 2026-09-13

56 pull requests since v1.10.2. A ninth model family, five real bugs closed
across four engines, and the two platforms the C tests never built on now
building them in CI.

### A ninth engine: DeepSeek V4.1 Flash

- **#1453**: DeepSeek V4.1 Flash (552B, 510 GB on disk) runs on a CPU box
  streaming experts from an SSD, with no conversion: the released checkpoint
  is read natively, fp8 dense with 32x32 ue8m0 tiles and fp4 experts whose
  layout is byte-identical to the mxfp4 the Kimi K3 engine already reads.
  Everything in the architecture that is not V4 is in: Engram (two n-gram
  memories of 384M rows, 203 GB, that never enter RAM), the DSA indexer with
  its two-level candidate source, hyper-connections, the compressor, the
  32-layer vision tower with its aligner, DSpark speculative decoding (3
  stages, blocks of 5, verified in one batched forward with a rollback for
  the rejected rows) and tool calling in the checkpoint's own DSML format.
- Held token-exact in CI against a torch-only CPU reference
  (`c/tools/dsv41_ref.py`, written because the vendor's own forward needs
  tilelang GPU kernels), at three cache capacities, on a short and a
  40-token prompt, under all three speculative modes; the vision tower is
  matched to 5e-06. The CI also asserts that the vendor's index-key
  republication policy and the tidy reading disagree, so the shipped default
  cannot be "corrected" by accident (`V41_INDEX_OWNER`).
- Measured on the released checkpoint, cold, caches dropped before every run,
  same prompt and seed: a turn went from 78.7 s to 25.1 s during the work
  (0.305 to 0.957 tok/s) through batched expert reads (`V41_READ_DEPTH`,
  default 8 is the measured knee), attention matrices read once per block of
  positions instead of once per token, and an expert-major MoE. Every step
  is bit-exact against what it replaced. A five-turn chat session runs at
  1.14 to 1.58 tok/s; an `image_url` part goes through the gateway into the
  vision tower on the same engine.
- Two ways of hiding the expert reads behind the matmuls were built,
  measured worse, and removed; both are written up in `docs/deepseek-v41.md`
  with the numbers, so the next attempt starts from them.
- `coli chat`, `coli serve` and `coli web` work; `coli run` is deliberately
  unwired for this family, as for qwen36 and qwen38. Per-turn accounting is
  behind `V41_STATS`, off by default, so the chat stays clean.

### Fixed

- **#1390** (@crichalchemist): the qwen36 GPU tier's `qt_fill_wait` returned
  when the upload queue was empty, but the uploader frees the ring slot at
  dequeue, before the backend copies anything, so the warmstart freed the RAM
  int8 copy of experts still in flight. An in-flight count that the uploader
  decrements only once the slot is resident (#1360).
- **#1434** (@njloof): `fmt=0` is raw f32 and has no scale array, but the
  Metal sizing helper returned a per-row scale size for it, so
  `coli_metal_matmul` wrapped a NULL pointer and segfaulted inside
  `newBufferWithBytes`, or silently produced all-zero output when the size
  happened to be a page multiple. The kernel no longer applies a scale for
  `fmt=0`, and a fail-closed guard sized off the same helper falls back to
  the CPU path for any format that needs scales and got none.
- **#1389** (@bherald): GLM-5.3 teardown leaked the lazily allocated dashboard
  HITS table.
- **#1461**: `coli cluster worker` could never start without an explicit
  `--cap`: the default is `None`, and `str(None)` reached the engine's
  argument check as the literal `"None"` (#1452). The worker now resolves the
  cap the way every other launcher does.
- **#1460**: olmoe's serve-mode `PROF` line published five literal zeros, so
  `/profile` reported `expert_disk_s = 0.0` on turns where the expert reads
  were the workload. The disk phase is measured now; the other four fields
  stay zero because they are unmeasured, not because a guess would look
  better (#1449, half of it).
- **#1445**: olmoe's `--ram` was inert and "no `--cap`" meant a constant eight
  slots per layer regardless of memory; the cap is derived from the RAM budget
  (#1443). On the reporter's box a 2,291-token prompt went from 675 s to 353 s
  with no flags (#1442).
- **#1377**: available RAM is measured on every platform (glm53 read
  `/proc/meminfo` unconditionally, so on Windows and macOS it read 0 and the
  expert budget collapsed to 1 GB, which is how `coli tune` went OOM in
  #1375), and the Windows commit limit is respected.
- **#1381**: the context ceiling is announced, a request that cannot be
  honoured is refused up front, and the number reported is the right one
  (#1376).
- **#1393**: GLM-5.3 replies always start inside the think block (#1278).
- **#1414** (@dajiaohuang): the GLM-5.3 serve loop honours `CANCEL` while the
  turn is still running (#1332).
- **#1423** (@kreuzzelg): the lazy HITS table is built privately and published
  under a lock in qwen36, kimi_k3, glm53 and qwen38; the parallel warmstart
  segfaulted on first touch about one run in twelve (#1422).
- **#1404** (@Petsku01): the qwen36 tier offers int8 experts on the decode
  path (#1391). **#1388** (@crichalchemist): `QT_MAX_ROWS` replaces seven
  literal 32s that had to agree, and the int8 copy is freed by ownership
  rather than by format.
- **#1421** (@bherald): `coli` no longer overwrites an explicit
  `CUDA_EXPERT_GB` when it decides to place the dense trunk on the card.
- **#1244** (@Unknown-Findout): the CUDA expert tier is charged real VRAM, not
  logical bytes (#687). **#1394**: the VRAM prefix is priced per row, not at
  the container's widest (#1351). **#1410**, **#1411**: on a single GPU the
  VRAM prefix is sized from the VRAM budget and the measured headroom, not
  from the RAM pin plan capped by the LRU reserve (#1409, #1405).
- **#1447** (@trigger2k20): `coli mirror verify` accepts a complete mirror
  copied by other means, with no receipt, and fails closed on a short or
  corrupt shard.
- **#1456** (@trigger2k20): the planner reports `memory.unified` from the
  host, not from whether the selected engine has a placement-capable GPU, so
  a CPU-only engine on Apple Silicon no longer reads as non-unified; and
  `coli tune` stops suggesting `DRAFT`/`PIPE`/`PIN`/`NUMA` to glm53, which
  ignores them.
- **#1396** (@dmoraesrs): the web reasoning selector drops "Medium" for
  GLM 5.3, which the engine renders identically to "High".
- **#1428**, **#1435** (@iiEliJas), **#1433** and **#1432** (@texasich),
  **#1440**, **#1459**, **#1458** (@trigger2k20), **#1463**: `setenv` visible
  to `getenv` in-process on Windows, `malloc_trim` guarded to glibc so the
  engines build on musl, a missing bench recipe restored, the per-test
  `_putenv_s` helpers dropped, tests including `compat.h` directly, and
  Clang warnings cleaned up.

### Added

- **#1462** (@trigger2k20): an opt-in Metal path for GLM-5.3-Flash's routed
  experts on Apple Silicon (`COLI_METAL=1`): gate, up, clamped SwiGLU, down
  and the route-weighted scatter on the GPU, CPU path unchanged when Metal
  is off. Validated against the CPU implementation to 2.8e-09 and measured
  on an M4 Max: 0.469 to 0.621 tok/s at 32 tokens, up to 2.15 tok/s with
  the expert cache tuned. Also fixes `coli run --cap N` being silently
  ignored on the glm53 one-shot path.
- **#1457** (@trigger2k20): GLM-5.3-Flash feeds the shared routing telemetry
  and writes `.coli_usage`, so usage-driven placement and partial-mirror
  planning have data for it.
- **#1454** (@yuripourre): the qwen36 GPU tier compiles with `HIP=1`.
- **#1399** (@SebaWag): `TRUNK_RESIDENT_LAYERS=N` streams the dense trunk
  through mmap (#826).
- **#1361**, **#1374** (@kreuzzelg): the qwen36 dense trunk places itself
  (`COLI_PLACE=auto`, priced in bytes saved per byte of VRAM), fp8 streaming
  mode, VRAM accounting at allocator granularity, thread affinity, `COLI_GPU`.
- **#1383**, **#1385**, **#1386**, **#1387**: Brain and Profile tabs (EMAP,
  HITS, PROF) on every engine. **#1382** (@dmoraesrs): a reasoning depth
  selector in the web UI (#1311).
- **#1407**, **#1408**, **#1406**: CI builds the portable Windows CUDA DLL and
  publishes it as an artifact; the Makefile refuses the 32-bit `cl.exe` before
  nvcc runs (#1405).
- **#1436**: CI builds against musl (Alpine) and compiles the environment
  tests on Windows, the two holes that let #1430 and #1420 ship.
- **#1360** (@kreuzzelg): tier invariants on the fake backend, and the
  reservation leak they found. **#1419**, **#1415**, **#1418**
  (@dajiaohuang): the V4 and fp8 test harnesses build on Windows.
- **#1439** (@bherald): the planner tests no longer materialise four 3 GB
  zero-filled payloads. **#1358** (@monotophic): a raw-evidence adapter for
  the scoring corpus. **#1238** (@ZacharyZcR): reproducible performance
  records are validated.

### Docs

- **#1446**: the qwen36 `--ram` section said the engine does not stream at
  all. **#1392**: Azure GLM-5.2 benchmark rows (#1379, #1380, #1384), the rANS
  cross-reference (#1273), and the int8 probe pinned in CI (#1331).
- **#1427** (@ZH1995): README.zh-CN formatting. **#1438** (@iiEliJas): the
  `malloc_trim` comment.

## [1.10.2] — 2026-09-06

Patch release. Three of these fixes answer reports made against 1.10.1 in the
days after it shipped.

### Fixed

- `coli convert` picks the converter from the checkpoint's `config.json`. It ran
  GLM-5.2's converter on everything; on GLM-5.3-Flash that quantized the nested
  embedding and the engine refused the result hours later inside `coli web`.
  An option the target converter does not take is refused, not dropped (#1368,
  #1369). The converter also refuses a checkpoint it cannot serve, with a
  per-family pointer (#1305).
- `coli doctor` no longer reports two missing core tensors on a healthy
  GLM-5.3-Flash: it matches roles, prefix-agnostically, instead of GLM-5.2's
  literal names (#1365, #1366).
- The release archive ships every file `coli` reaches: `iq3_pack.py`, its grid
  data file, and `tools/convert_glm53.py`, which had never been packaged
  (#1359, #1364).
- The RSS guard counts anonymous memory, not reclaimable page cache, so a mapped
  container no longer evicts experts to free memory it was not using (#1350).
- `serve` honors CANCEL while a turn is still running (#1336), and the
  disconnect scenario is built rather than hoped for (#1329).
- Metal: bit-exact fp8-e4m3 decode (#1346). Qwen3.6: tokenizer merges in both
  spellings (#1319). macOS: Homebrew prefixes found when `brew` is off the PATH
  (#1320). DeepSeek V4 on macOS: real CPU and memory in HWINFO (#1308).
- `coli doctor` omits the GPU plan for a CPU-only engine (#1322); a missing core
  tensor explains itself on every fatal path (#1318); GLM-5.3-Flash `--no-think`
  is the template's lowest effort level, not a shape of ours (#1327).
- GLM-5.3-Flash `serve` can use the 16 KV slots the engine has; the registry
  declared 1 (#1283).
- `image_url` local reads: `..` is refused, and with `COLI_IMAGE_ROOT` set a
  path must resolve inside it, so an authenticated client of a non-loopback
  server cannot read arbitrary files through the image API. Error messages no
  longer confirm a path or its permissions (#1354).

### Changed

- The GLM family is named `GLM-5.2/5.3`: the two checkpoints share the base
  model and cannot be told apart from their configuration (#1367).
- DeepSeek V4 Flash REAP-150B (85 GB, 132 of 256 experts) loads with the same
  engine (#1310), is documented, and is announced by its measured geometry
  rather than the official checkpoint's 284B.
- The qwen36 VRAM tier promotes int8 experts instead of reserving for nothing
  (#1334), and the three tier bugs that surfaced with it are fixed: an `is_x`
  overrun with two or more GPUs, a shutdown that could hang, and a
  use-after-free on int8 containers (#1339, #1340, #1341, #1344). Kimi K3
  stops paying for a DSA indexer nothing reads (#1335).
- Opt-in: `COLI_MAP_EXPERTS=1` serves experts through a per-shard file mapping
  (#1325). Off by default; output is byte-identical either way.

### Docs

- Windows DeepSeek V4 users are led to the release launcher (`coli.cmd`)
  instead of a source build (#1291).

### Build and CI

- CI workflows run with `contents: read`, and third-party actions are pinned
  by commit SHA (#1354).
- Makefile lists the headers each engine includes as prerequisites (#1284,
  #1349). Site and READMEs carry the eight families with real RAM figures under
  a contract test (#1302).

## [1.10.1] — 2026-08-31

Packaging repair for the prebuilt archives; no engine changes.

## [1.10.0] — 2026-08-31

### A seventh engine: Qwen3.8-Flash-Next

- Added complete text-only inference for the official Qwen3.8-Flash-Next FP8
  checkpoint: four-stream Gated Residual, Gated DeltaNet, Qwen Sparse Attention,
  pageable hashed n-gram embeddings, top-10 routed MoE, and the shared expert.
- The original 131 safetensors shards run directly. Vision and MTP are not
  loaded or advertised; tools and non-text gateway content are refused.
- Added family/planner/doctor/build/release integration and a pinned upstream
  tiny oracle covering sparse selection, cached decode, LRU eviction, and
  sanitizer runs.
- Kept native FP8 expert payloads and normalized scale banks bounded, added
  cache-sized parallel demand loading, and made prompt MoE execution
  expert-major with bounded shared-expert and causal DeltaNet batching.
- Added exact single-slot hybrid prompt-prefix reuse across QSA, DeltaNet and
  PLE state, with persistent state and bounded workspace reflected explicitly
  in planner RAM accounting.
- Added the boundary-only Qwen3.8 Edge adapter and the seventh-family real
  Edge -> Segment -> Edge oracle gate without loading transformer, vision or
  MTP tensors into the Edge process.

## [1.7.0] — 2026-08-19
71 pull requests since v1.6.2. A sixth model family with its GPU tier, a
rebuilt expert-matmul path, and the CI that would have caught the class of bug
we shipped twice.

### A sixth engine: Qwen3.6-35B-A3B — CPU and GPU
- **#712** (@kreuzzelg) — hybrid Gated Attention + Gated DeltaNet + streaming
  MoE, in `c/qwen36.c`. Pre-converted containers published (int4-gs64
  recommended: cosine to the int8 anchor 0.98777 → 0.99313, KL 0.109 → 0.080
  vs per-row). The engine takes any architecture-identical checkpoint
  unchanged — KAT-Coder v2.5 runs on it with no code path of its own.
- **#713** (@kreuzzelg) — CUDA VRAM expert tier with heat-based placement
  across GPUs: **1.44 → 10.05 tok/s (7.0×) on 2× 8 GB cards, output
  bit-identical to CPU** (`cmp` over the full 200-token generation), measured
  cold with no heat table. A `qt_ready()` gate keeps CPU-only builds from
  allocating the packed int4 buffers they never read: **7.33 GB saved**.

### The expert matmul path, rebuilt (all bit-identical)
- **#1071 / #1075 / #1076 / #1077** — activation quantization hoisted to layer
  level across GLM, Kimi K3 and DeepSeek V4: the same vector was being
  re-quantized ~16× per layer, serially. Removes ~5.2 ms/token of serial time
  and every per-call `malloc` from the hot path.
- **#1079 / #1086** — **K1: plane-nibble int4 layout + unsigned-VNNI dot.**
  Storing element *k* and *k+32* in one byte deletes the unpack, and since
  nibbles are stored unsigned, `dot(v,x) = dot(u,x) − 8·Σx` feeds `vpdpbusd`
  natively. 8 uops per 64 MACs instead of 32: **1.45–2.65× on the IDOT
  kernels**, zero bytes added.
- **#1088** — **K2: 1×4 union tile.** The prefill union hands each expert
  2–16 rows; the weight block's load+mask is now paid once per four rows
  instead of once per row: **2.67–3.10× at S=4** (peak 253 GMAC/s).
- **#1093** — parallel silu and the down-side activation hoist.
- **#1094** — **K1b: grouped planar IDOT for gs64 containers** (`IDOT_GS=1`,
  opt-in): the recommended container format could not reach the integer
  kernels at any batch size before this.
- **#1082** (@outtodata) — `FUSED3=1` opt-in fused AVX2 expert matmul.

### Streaming and I/O
- **#1097** — DeepSeek V4 expert-loader pool default 3 → 9 lanes:
  **1.41× decode** on the real V4-Flash checkpoint (8 interleaved runs on a
  quiet 25 GB box). `V4_LOADER_LANES` still overrides.
- **#1056** (@dcutugno) — DeepGEMM sm120 headers fetched at a pinned commit on
  first build: 2.5× prefill on sm120 with nothing vendored in-tree.
- **#988 / #1054 / #1055** — DeepSeek V4 CUDA tier and dual-SSD mirror.

### Correctness and CI
- **#1083** — **ARM CI job** (`ubuntu-24.04-arm`) plus an integer-kernel
  bit-exactness gate that runs on both ISAs. Every tiny-oracle job ran on x86
  before this, so NEON-divergent paths were invisible — which is how the IDOT
  defaults below shipped. Closes #1081.
- **#1044 / #1080** — IDOT made opt-in in olmoe and inkling: the fast path is
  x86-only and quantizes activations, so the same model produced different
  tokens on x86 and ARM by default.
- **#1109** (@SebaWag) — ARM64 dotprod probed by *compiling* the intrinsic:
  GCC 11 defines `__ARM_FEATURE_DOTPROD` for a base it cannot emit
  `vdotq_s32` for. Fixes #1104.
- **#1111** — `__syncwarp()` after `grouped_s4_wmma`'s store (reported by
  @monotophic with `compute-sanitizer` evidence). Fixes #1099.
- **#1073 / #1074** (@bherald) — Kimi K3 cancels prefill between layers
  instead of holding the engine for a minutes-long prompt; cancelled requests
  no longer count as completed.

### Apple Silicon
- **#790 → #1113** (@RDouglasSharp) — **Metal backend for Kimi K3**: KDA state and
  window buffers aligned, wrap-once buffer cache, CPU-side MLA KV cache. 1.7×/2.4×
  on the compute-bound phases (KDA attention + projections dispatched to the GPU);
  MoE experts stay on the CPU. Kimi K3's first GPU backend.

### More correctness fixes
- **#1098** (@monotophic) — `__syncthreads()` missing from the absorb softmax
  reduction, with a determinism test that reproduces the hazard.
- **#1101** (@monotophic) — allocation and `snprintf` results checked on the
  checkpoint-load path (#798).
- **#1100 / #1108** (@monotophic) — fmt=8/fmt=6 scale-byte accounting in
  `tensor_bytes`/`tensor_free`, and `weights_owned` set before the host-to-device
  copy so a failed upload frees its buffer. Each ships with its own regression
  test; all four of this contributor's CUDA fixes landed in this release.
- **#1122** (@ZacharyZcR) — `USAGE_SAVE=0` honoured in every engine (#1039): the
  history was loaded but written back anyway, which quietly contaminated any A/B
  that shared a usage file between arms.
- **#1121** (@ZacharyZcR) — LRU victim selection now respects a lowered `ecap`
  (#1034): after an RSS-guard reduction the cache kept evicting against the old
  capacity.
- **#1123** (@ZacharyZcR) — the v1.6.2 warning-cleanup patches landed (#1032).
- **#1106** (@monotophic) — duplicate tensor names across indexed shards are now
  refused rather than silently resolved to one of them (untrusted containers).

### Interfaces
- **#829** (@aaristov) — GPU-vs-fallback counters and chat status made visible in
  `coli serve`: the tier's behaviour is now observable instead of inferred.
- **#1095** (@benmaster82) — OLMoE planner geometry adapter, and **#1103**
  (@SebaWag) — Kimi K3, Inkling and DeepSeek V4 adapters with 23 tests: every
  family now has real planner geometry, so `coli plan` stops guessing (#1066).
- **#1096** (@terrizoaguimor) — DeepSeek V4 serve framing on the shared codec,
  completing the codec migration across OLMoE, Kimi K3 and V4.
- **#1063 / #1068** (@terrizoaguimor) — model families are registry-owned:
  `coli`, the gateway, `doctor` and the planner read one descriptor table.
- **#1087 / #1090 / #1096 / #1116** (@terrizoaguimor) — a shared serve framing
  codec, now adopted by **every engine**: OLMoE, Kimi K3, DeepSeek V4 and
  Inkling (whose audio payload rides as an opaque extension). Each migration
  landed behind a byte-exact wire-transcript freeze, so the gateway contract is
  provably unchanged. Byte framing had been duplicated five times, which is how
  Windows binary mode silently disappeared from sibling engines (#748).
- **#1036** (@lineape) — distributed expert workers (LAN, opt-in via
  `CLUSTER_WORKERS`).
- Planner: DeepSeek V4 expert naming now recognized, so `coli plan` and
  `coli doctor` stop counting every routed expert as dense (fixes #1110).

## [1.6.2] — 2026-08-14
Security release: **six privately-reported memory-safety issues fixed**, all reachable
from attacker-controlled input (malicious model file / `config.json`, or the kimi_k3
SERVE stdin). Every fix validates at the trust boundary — no behavioural change on
well-formed models or requests. Advisories: GHSA-gf38-c8fx-ppvv (kimi_k3 SERVE OOB
write), GHSA-2qrj-xjmh-mv74 (json.h OOB read), GHSA-w696-h9p7-6rgc (inkling audio
OOB), GHSA-7654-r78q-vc3r (deepseek_v4 indexer OOB R/W), and two more in the same
class. See the GitHub Security Advisories for details.

## [1.6.1] — 2026-08-13
- `--allowed-host '*'` lets an operator reach a public bind deliberately (#990, #993)
- OLMoE streaming no longer drops the answer into the reasoning channel (#984, #985)
- chat reasoning-channel fixes and pty test hardening (#980)

## [1.6.0] — 2026-08-12
**If you are on v1.5.0, update:** it shipped a performance regression on GLM-5.2
(#856), left up to ~60 GB of RAM unused with a 13-point expert hit-rate loss (#885),
and broke Kimi K3 outright on some machines (#888).
- #869 — the planner priced every expert row at the container's *widest* width;
  mixed-width containers had their cache silently halved
- #914 (bherald) — pin budgets accounted correctly
- prefill batch-union: each distinct expert is read **once** per chunk

## [1.5.0] — 2026-08-05
51 pull requests from 15 contributors.
- **Fifth engine: DeepSeek V4 Flash** (@DrewZt, #165) — MLA + DSA sparse attention,
  43 layers, 256 routed experts + 1 shared, top-6; official checkpoint streams with
  no conversion (fp4 experts, fp8-e4m3 dense with UE8M0 block scales)
- #839 — the rows16 fp4 fast path no longer requires AVX-512: consumer Intel/AMD
  CPUs since Alder Lake get the fast path

## [1.4.0] — 2026-08-01
162 commits, 29 pull requests (25 from contributors).
- **Release archives now contain every engine** — v1.3.0 archives shipped `c/colibri`
  alone while the README promised four families (#720); `inkling` and `kimi_k3` are
  built, packaged and smoke-tested per platform
- Third GPU backend lands

## [1.3.0] — 2026-07-29
Three MoE families on one engine, 744B → 2.8T.
- **Kimi K3** (#676) — 2.8T/104B active: KDA + gated-NoPE-MLA + AttnRes + LatentMoE,
  streams Moonshot's QAT MXFP4 experts straight from the original HF shards
- **Inkling** — a 975B model answers on a 25 GB machine

## [1.2.0] — 2026-07-28
- GB10 / DGX Spark unified-memory OOM fix (#653); AMD/ROCm recognized by `doctor`
  and `resource_plan` (#662, #663)
- AVX2 `matmul_e8` — fmt=6 was 92% of decode on the scalar kernel (#654); native
  SIMD fmt=6 encoder, 15× over numpy
- chat stop-set fix (#633/#381), async packed-int4 parity (#632), stable KV slot
  per conversation (#634, #639)

## [1.1.1] — 2026-07-23

A same-day patch release. **Windows users on v1.1.0 should upgrade**: Microsoft
Defender flags the v1.1.0 Windows binary, and the cause was ours.

### Fixed

- **107 KB of zeros were shipped inside every binary** (#527, #532) — and that is
  what antivirus ML heuristics were reacting to. `static GrDraft g_grd={.max=24};`
  looks harmless, but `GrDraft` is ~107 KB (the grammar's 1024 static rules plus the
  PDA walker) and **any** initializer moves the whole struct out of `.bss` and into
  `.data`, writing 106,848 bytes of near-zero-entropy data into the file — in a
  *writable* section, which is the classic shape of an unpacking buffer for a packed
  payload. Section forensics against v1.0.0 (clean on the same Defender definitions)
  isolated it: identical toolchain, identical PE layout, `.data` 1,840 → 108,752
  bytes. A Windows build with the fix scans clean where v1.1.0 does not. Every
  platform's binary also gets smaller: the Linux engine drops 474,904 → 368,016
  bytes, **-22.5%**.
- **`python3 openai_server.py` was broken on a clean checkout** (#526) — the gateway
  still looked for an engine named `glm` after the #391 rename. It resolves
  `colibri`/`colibri.exe` first now, falling back to `glm` for older trees.
  `coli serve` was unaffected. Spotted by @RDouglasSharp while debugging #488.

### Added

- **Anthropic Messages API** on `/v1/messages` (#343, #525) — clients that only speak
  to Anthropic endpoints, Claude Code above all, now work against colibri with no
  shim: same port, nothing to enable. It is a translation layer over the same
  generation path, so tools, streaming and the KV cache behave exactly as on
  `/v1/chat/completions`. Covers system prompts, `text`/`tool_use`/`tool_result`
  blocks, `input_schema` tools, every `tool_choice` mode, the full named-event SSE
  sequence with protocol `ping` keepalives, `stop_reason` mapping, extended thinking,
  and `x-api-key` auth (`Bearer` still works). `stop_sequences`, `top_k` and non-text
  blocks are refused explicitly rather than silently ignored.
- **`SHA256SUMS.txt` published with every release** (#530) — verify a download is
  exactly what CI built from the tagged source.
- **The Windows engine is uploaded as a CI artifact** (#532) — an antivirus report can
  now be verified on a pull request instead of only after a release is published.

### Changed

- **Docs: "Get started" now starts by getting the program** (#521). The README told
  newcomers to download the 372 GB model *before* it told them how to obtain colibri —
  and for Linux/macOS it never told them at all. New order: get colibri (prebuilt
  archive or build from source) → get the model (372 GB stated up front) → run it.
  The obsolete "rename the engine to `glm.exe`" step is gone; archives have shipped a
  plainly-named `colibri.exe` since #508. Applied in all four languages.

## [1.1.0] — 2026-07-22

A community release. 27 pull requests from more than 20 contributors, 216 commits since
v1.0.0. Most of what follows was found, measured, or fixed by people who do not work on
this project and had nothing to gain from it.

### Added

- **AMD GPU support (HIP/ROCm)** (#339) — single-source `backend_gpu_compat.h` with a WMMA
  dispatch gate, so one codebase builds for CUDA and HIP. Validated on an RX 9070 XT
  (RDNA4, ROCm 7.2): token-exact against CPU on a real fmt=4 gs64 container, with resident
  dense *and* with routed experts in VRAM, plus a fail-injection control proving the GPU
  actually executed the work.
- **Dual-SSD streaming** (`COLI_MODEL_MIRROR`, #421) — read the model from two drives at
  once, roughly doubling streaming bandwidth on a disk-bound host.
- **N-drive shard split** (`COLI_MODEL_DIRS`, #469) — capacity aggregation: run a container
  no single drive can hold, spread across several with no duplication.
- **fmt=5 (int3-g64)** (#168) — 3-bit weights with per-64 group scales: measured 3.3x lower
  outlier-row error than per-row int4 at 25% fewer bytes.
- **fmt=6 (E8/IQ3 lattice)** (#465) — CPU decode kernel and dispatch; index codec tooling (#458).
- **`tools/try_tool_calling.py`** — dependency-free two-turn tool-calling probe that doubles
  as a smoke test.

### Fixed

- **Tool calling in coding clients** (#401), root cause found, in two parts:
  - **#506** — the engine capped prompt encoding at `CTX-2`, and the tokenizer stops dead at
    its limit *without reporting anything*. A prompt longer than the context was therefore
    silently truncated to its first `CTX-2` tokens and answered anyway. With the 4096 default
    that is 4094 — exactly the `prefill 4094` in the field report. The dropped tail was the
    tool instructions and the user's actual turn, so the model emitted a bare `<` and stopped;
    and because clients append to the *end* while truncation keeps the *head*, every retry
    re-sent a byte-identical prompt. Now refused with a 400 `context_length_exceeded`.
  - **#505** — a tool call whose closing `</tool_call>` never arrived was dropped whole,
    because the parser required both tags. Now recovered when unambiguous, on both the
    streamed and non-streamed paths.
  - **#437** — non-EOS role markers were armed as hard stops in serve mode and cut generation
    the instant a tool block started.
- **Grouped-int4 (fmt=4) produced garbage output on CUDA** with `CUDA_DENSE=1` (#298) — the
  dense and attention kernels applied per-group scales as if they were per-row. Hardware-verified.
- **OpenMP tuning re-exec preserved the CPU affinity mask** (#476), jailing every thread onto
  one core when `OMP_PROC_BIND`/`OMP_PLACES` were set: roughly a 20x slowdown.
- **Pilot eviction guard dropped ~100% of speculations** once the cache filled (#497),
  collapsing `PILOT_REAL` to a hint-only path.
- **Silent budget clamp** capped the CUDA expert tier at ~109 experts regardless of
  `CUDA_EXPERT_GB` (#495).
- fmt=4 guard at the per-row-only CUDA entry points (#464/#470); `COLI_CUDA_MTP=1` and
  `COLI_CUDA=0` are now honoured over implicit defaults (#468).

### Security

Threat model: model files come from mirrors that are not trusted.

- **#368** — server hardening, JSON and tokenizer parser hardening, build flags, downloader
  and dependency pinning.
- **#413** — the quant layout is resolved *and* validated against the on-disk byte counts
  (unknown layouts are refused rather than falling through to int2), shape-product overflow
  is rejected, and the olmoe dtype-3 path no longer trusts a crafted `nbytes` (heap overflow).

### Performance — all byte-identical

- **#481** +4.7x on the MLA-absorb score and value-mix reductions
- **#477** +13% decode on AVX-512 (`qt_addrow` / `qt_matvec_rows`)
- **#475** +11.6% with opt-in `XEXP=1` (one OpenMP region per expert block at S=1 full residency)
- **#473** +5.5% int4 IDOT at S=1 on AVX-512 VNNI

### Changed

- `glm.c` is now `colibri.c` plus header modules (#391); `make glm` remains as an alias.
- Serve stage 2 (#192): `response_format`, per-request grammars, grammar-forced drafts.

### Upgrade notes

- **`CTX` still defaults to 4096.** Coding clients send far more than that in a single system
  prompt. Use `CTX=32768`. Before this release an over-long prompt was silently truncated;
  now you get a clear 400 instead.

## [1.0.0] — 2026-07-19

First tagged release. The engine has been running in production since late June
2026; this tag marks the baseline for semantic versioning going forward.

### Highlights

- **GLM-5.2 (744B MoE)** runs on ~25 GB RAM in pure C, streaming experts from disk
- **Three-tier placement**: VRAM (hot) / RAM (warm) / NVMe (cold), with a learning
  cache that pins your workload's hottest experts automatically
- **CUDA backend**: multi-GPU expert tier, dense tensor distribution, batched
  ragged attention, resident pipeline (`COLI_CUDA_PIPE=2`)
- **Metal backend** (Apple Silicon): batched expert SwiGLU + fused decode attention
  on unified memory GPU
- **MTP speculation**: native GLM-5.2 draft heads, grammar-forced drafts, kernel-
  pinned verification (`SPEC_PIN=1`)
- **OpenAI-compatible API**: `coli serve` with SSE streaming, KV slots, bounded
  queue, web dashboard (`coli web`)
- **Web UI**: chat with live metrics, expert cortex brain page, profiling breakdown,
  expert atlas 3-D galaxy
- **Cross-platform**: Linux, macOS, Windows 11 (native MinGW), PowerPC; CI on all three
- **Auto-tune**: `coli plan --auto-tier` classifies the bottleneck and derives
  MTP/PIPE/NUMA/PIN settings with explanations

### Engine

- Token-exact validation against `transformers` oracle (teacher-forcing 32/32)
- Compressed MLA KV cache (576 floats/token, 57× smaller), persisted across
  restarts (`.coli_kv`, zero re-prefill)
- DSA sparse attention (lightning indexer), faithfully implemented
- Router-lookahead prefetch (`PILOT=1`, 71.6% predictive)
- Async expert I/O pool (`PIPE=1`), io_uring batching (`URING=1`)
- NUMA-aware expert placement (`COLI_NUMA=1`, +13–40% on multi-socket)
- AVX2 / AVX-512 / AVX-VNNI / ARM NEON / NEON-i8mm / POWER VSX kernels
- int4 / int8 / int2 / grouped-int4 (fmt=4) quantization formats

### Tools

- `coli convert` — FP8→int4 one-shard-at-a-time converter
- `coli doctor` — read-only setup diagnostics
- `coli plan` — resource planner with auto-tune prescription
- `coli bench` — MMLU / HellaSwag / ARC quality benchmarks
- Expert atlas (`tools/analyze.py --web`) — measured topic affinity for 19,456 experts

### Community

- 30+ hardware datapoints in the benchmark tracker
- Contributions from 20+ authors across engine, docs, tooling, and ports
