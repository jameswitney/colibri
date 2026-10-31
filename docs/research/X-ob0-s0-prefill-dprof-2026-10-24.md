# X — OB0's S0: the prefill DPROF window, and the ~90 s estimate it retires (2026-10-24)

**Tree:** `port/ob-s0` @ 563bb643 + S0 (this lane's worktree; code anchors verified unshifted vs the
plan's `073a03b6` — the two intervening commits are docs/bench only, `vk_chain.c` 3674 /
`deepseek_v4_chain.h` 1691 / `vk_tier.c` 3264 lines exactly as the charter froze them). **Rig:** the
parity rig (RX 6900 XT, RADV), exclusive — `vram0=541057024 B`, the idle floor, on both legs, VRAM back
at floor after; `VRAM_MAX_USED_MB=2600` guard, `rc=0` both legs, no device loss. **Charter:**
`plans/OB0-fold-transplant-plan.md` §3 S0 (r2) — instrument only, default off, byte-identical disarmed.

## 1. What landed (S0, ~120 LOC over the landed decode DPROF of `d602436a`)

- `vkc_dwin(2)` opens a **prompt window per chunk** (`deepseek_v4_chain.h`, the chunk loop head;
  closed at the chunk's end; a prompt still closes the decode window exactly as before, and a decode
  step's window still stays open across forwards — the landed discipline untouched). The window's own
  counters are the decode ones widened: `p_fwd/p_frames/p_wait_n`, `p_wait_ms/p_dev_ms/p_submit_ms`
  by role (`vk_chain.h`).
- **The host timeline** — the window's own instrument: while a prompt window is open, every
  `vkc_role` stamp charges the wall since the previous stamp to the previous role
  (`p_host_ms[role]`), so the roles **tile the window's wall exactly** (unit-checked to 1e-3 ms).
  Two new roles stamp **no frames, only wall**: `VKC_R_MOEH` (the host's routed-expert step,
  `deepseek_v4_chain.h:1419-1429` — the span whose run-total `ch->host_ms` is) and `VKC_R_STAGE`
  (the staging uploads: `vkt_stream_prefetch` beside A1, the routed rows' h2d, `vkc_dmoe_upload`
  after the tier's step).
- **The tier mirror** for `S > VKT_UP_ROWS` (`vk_tier.c`): a prompt step's whole span, issue to
  join, split into waited/device/host — `| prompt dprof:` beside the decode clause in `vkt_report`.
  The big path's capture opens at `issue`'s head (mid-flight slot joins included), `join_big` closes
  it; the small path mirrors at the decode class's own site.
- Prints: the chain's `chain prompt:` line beside `chain decode:` in `v4c_report`, and the CLI's
  `v4_dprof prompt:` beside `v4_dprof decode:` at the timing line (the window wall against the TTFT
  wall — the chain owns 159.0 of 159.6 s).

**Gates:** `vk-chain-check` (with `test_dprof` extended: the prompt window's frames, waits, the
MOEH wall span, the exact tiling, and that the decode counters are left alone) PASS; `vk-tier-check`
PASS; `vk-strict-check` PASS (first run — the flake protocol never engaged); `deepseek-v4-tiny-check`
(23 PASS) and `-dmoe` PASS; `test_v4_serve_framing` PASS; `cu_tier.c -DCOLI_CUDA -fsyntax-only` PASS.
`tests/vulkan_engines.sh deepseek` is **environment-blocked on this rig**, pre-existing: the family's
DSpark assertions expect Lavapipe's shared-RAM tier default ("the default on Lavapipe… with
`COLI_VK_TIER_MTP=1` (the default on a discrete GPU)" — the check's own comment); this rig has no
Lavapipe ICD and is discrete. Proven not S0's doing: the exact failing sub-case reproduced at the
stashed base build (`extra layers` present there too), and at the S0 build the same sub-case's Vulkan
tokens remain identical to the CPU's.

**Byte-identity, disarmed (the d602436a precedent, tiny-oracle class):** base vs S0 builds, DPROF off,
the tiny harness — every PASS line and token identical (oracle-exact both sides); the A/B diff is
host-state/timing noise only (`ram_tiers available=…`, ms timings, the `.coli_mfu` selection count
of a stateful file). With `DPROF=1` the same harness is still 12 PASS / 0 FAIL — observe-only.

## 2. The legs (the plan's arm: ttft set + `DPROF=1 PROF=2`, ×2; `bench/up2276/ob-s0-r{1,2}.log`)

Standing ttft set = the C0'/V-g1 c-r1 class: `COLI_VK_PROFILE=RDNA2 COLI_VK_TIER_STREAM_BYPASS=1
COLI_VK_TIER_HOST_GB=4` + `COLI_VK_CHAIN_DPROF=1 COLI_VK_CHAIN_PROF=2`, runner standing envs,
2,515-tok prompt / 64 tokens.

| | r1 | r2 |
|---|---:|---:|
| TTFT s / decode tok/s / wall s | 159.561 / 0.5298 / 278.472 | 159.142 / 0.5410 / 275.595 |
| chunk windows / window wall s | 2 / 159.0 | 2 / 158.4 |
| **host spans: A1 / A2 / dmoe s** | 4.0 / 0.0 / 0.0 | 4.2 / 0.0 / 0.0 |
| **host-MoE (MOEH) s** | **49.2** | **49.1** |
| **staging-upload (STAGE) s** | **105.6** | **104.9** |
| tail / other s | 0.1 / 0.1 | 0.1 / 0.1 |
| chain frame waits s / device s / submit ms | 4.0 / 70.2 / 8.8 | 4.2 / 70.2 / 8.7 |
| tier `prompt dprof`: waited / device / host s | 17.4 / 19.4 / 26.0 | 17.3 / 19.3 / 26.0 |
| tier stream: steps, cold experts, bytes | 86, 10,482, 183.25 GiB | 86, 10,482, 183.25 GiB |
| run line: routed experts on the host (`host_ms`) | 148.9 s | 146.5 s |

The two reps agree to ±0.7 % on every bucket — the decomposition is settled at this rig's noise floor.
Cross-checks: the host spans tile the window wall exactly (4.0+49.2+105.6+0.1+0.1 = 159.0 ✓); 86 tier
steps = 43 layers × 2 chunks (2,515 tokens = 2048+467 rows) ✓; decode side reproduces V-g1's shape
(wall 1,857.6 ms/tok, tier decode CPU 812 ms/tok, decode device share 13.1 %) ✓.

## 3. The verdict: §1.2's ~90 s subtraction is retired — the attribution was inverted

The charter's pre-registered shape was `host-MoE ≈ 85–95 s, staging/upload join ≈ 20–30 s,
dense frames ≈ 50–60 s`. **Measured (median of the two reps):**

| bucket | predicted | measured | the miss |
|---|---:|---:|---|
| host-MoE step | 85–95 s | **49.2 s (31 %)** | the subtraction over-attributed ~2× |
| staging/upload join | 20–30 s | **105.2 s (66 %)** | under-attributed ~3.5× |
| dense frames | 50–60 s | **4.1 s host / 70.2 s device, overlapped** | the mass is real device time but is **not on the critical path** — it hides under the staging+MoE spans (host waits only 4 s) |

What the estimate conflated: `host_ms`'s prefill share (the `t1→memcpy` span, ≈50 s here) was taken as
the ~92 s remainder of C0's 144.4 s run-total after a decode-side 52 s estimate from **another config
world** (V-g1's 821.9 ms/tok × 63). Measured in one config, one run: prefill's routed-expert span is
~49 s of host compute **plus ~105 s of staging**, and the staging — not the compute — owns the TTFT.

The staging mass decomposes (the two lines together): `vkt_stream_prefetch` + the post-step uploads
move **10,482 cold experts = 183.25 GiB** through the 256-slot window at an effective **1.74 GB/s**
end-to-end (the `8.2 GB/s` in the stream line is the staged-pool memcpy, not the pipeline) — chunk-outer
order re-reads essentially the layer's whole cold set per chunk, 43 layers × 2 chunks, serialized on
the host against everything else. R-l1's "bytes are not the gap" stays true at the *payload* level
(251 vs 203 GB ≈ 5 s at like-for-like rates) — the gap is that the port **pays its bytes at staging
serialization**, while the fork's layer-outer bank/ring overlaps them.

Inside the host-MoE 49 s, the tier mirror splits: waited 17.4 s (fence joins, overlap-able) + tier host
26.0 s (its own loads/uploads/grouping inside `issue`) + ~5.8 s engine routing and CPU pairs — i.e.
even the "compute" bucket is two-thirds tier staging-and-waiting, not expert math.

## 4. What this decides downstream (input to the manager's S1/S3 sizing — S0 itself has no stop rule)

- **S3 (layer-outer) attacks the measured dominant mass**: slot reuse across a layer's chunks
  (reuse distance 43→0) and the per-layer bank directly cut the 183 GiB / 105 s staging term; the
  ~49 s host-MoE step is the *second* term. The charter's S3 bar ("prefill host-MoE counter − ≥ 50 %,
  or TTFT ≥ −25 s") should be re-expressed against this line — the honest S3 target is the
  **staging-upload bucket**, with host-MoE as the composed second term.
- **S1's chunk leg (bank layer 26 under chunk-outer)** now has a measured ceiling: one layer's bank
  removes that layer's streaming from the STAGE span (~105/43 ≈ 2.4 s/layer) and its MoEH span
  (~49/43 ≈ 1.1 s/layer) — consistent with the spec's −2.5–5 s/layer band.
- **S4 (the ring)** is promoted by this line, not demoted: 183 GiB at 1.74 GB/s serialized is exactly
  the "disk stays busy" overlap the fork buys with the ring; the byte term R-l1 closed (≈ 0 payload
  delta) never closed the *serialization* term.
- The **dense half is done**: 4 s of host-side A1 with 70 s of device GEMM fully hidden — no TTFT
  lever lives there (confirms the mm8/`CHAIN_GEMM_ROWS=-1` landing as fork-class).

No stop rule fires: no hang, no device loss, no ledger/VRAM discrepancy (vram0 the idle floor both
legs, VRAM at floor after), disarmed byte-identity holds, and S0 is instrument-only by design — the
falsifiable output is this line, recorded.
