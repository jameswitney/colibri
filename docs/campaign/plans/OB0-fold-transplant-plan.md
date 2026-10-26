# OB0 — the Option B fold transplant: the implementation plan (charter)

**Lane:** OB0 (read-only planning). **Date:** 2026-10-25. **Author:** worker, for the owner/manager.
**Revision:** r3 — S0 measured: §1.2 attribution inverted (staging 66 % > host-MoE 31 %), S3 bars re-expressed against the staging bucket. Prior: r2 — post-review: F1–F8 applied, reviewer verdicts recorded (§8)..
**Decision recorded:** the owner committed to **Option B — the fold transplant** (port the fork's
cell-pipeline architecture into the port's chain lineage), consciously relaxing PORT_PLAN's D3
("capabilities, not stack", decided 2026-10-19, `PORT_PLAN.md:412`). This document is the charter the
implementation lanes will execute; precision here is bought with the campaign's own measurements.

**Trees this plan is anchored to (frozen):**
- **fork** = `/root/Projects/colibri-ds4-vulkan` @ `d11fba5b` (all fork `file:line` cites).
- **port** = `port/up-2276` @ `073a03b6` via `git -C /root/Projects/colibri-upstream show 073a03b6:<path>`
  (all port `file:line` cites; `deepseek_v4_chain.h` = 1691 lines, `vk_chain.c` = 3674, `vk_tier.c` =
  3264, `vk_dmoe.h` = 692, `deepseek_v4.c` = 23492 at this ref).
- Evidence: `docs/research/{P-optionB-dossier, O-day2, Q-l2-dmoe-map, R-l1-byte-economy, S-store-mfu,
  T-l2-arms, U-l2-p1-arms, V-g1-dprof}` @ 073a03b6, `bench/up2276/p1-c0-r1.log` (the C0' boot lines),
  `specs/{G1-pipeline-gaps, L2-chain-moe-vkdmoe, L7-f8-decode-projections}` beside this dir,
  `CAMPAIGN.md`.

**Laws carried into every stage (the campaign's, restated as constraints on this plan):**
1. **Default-off byte-identity.** Every lever lands env-gated, default off; the off-arm must produce
   byte-identical text (the L2 window's 9/9 precedent, T §2.1). Armed arms are *thresholded*, never
   claimed bitwise (F8 envelope language; the P1d deterministic mid-generation divergence class, U §3.5).
2. **One bench lane at a time**, ×3 interleaved reps, `vram0` floor guard, standing runner
   `bench/up2276/run-arm2276.sh`, desktop-present guard.
3. **Do-not-retry register** (§1.4 below) — no stage may re-try a falsified lever.
4. **Record, never debug, in a window** (the P1 rule, U §5).

---

## 1. The measured ground truth the transplant must move

### 1.1 Decode wall (V-g1-dprof, port @ 073a03b6, leg a-r1, 2,515-tok/64-tok)

```
wall 1619.5 ms/tok = chain fence waits   235.0 (14.5 %)
                   + tier decode MoE CPU 821.9 (50.7 %)   ← the host computes 81–87 % of routed pairs
                   + forward glue         518.8 (32.0 %)   ← h2d/cdn memcpys, host router reads, OMP wakeups
                   + head 72.9 − overlap 29.1              (block = waits + tier CPU + glue, closes exactly)
```
Fence-gap ceiling is **5.5 ms/tok** (R1 fired; G1 closed negative — there is no queue/fence pool left).
Decode device-served routed share: 13.1 % (C0' run line, `p1-c0-r1.log`) / 18.6–22.5 % (V-g1 legs).
Fork reference: 1.15–1.17 tok/s (≈ 860 ms/tok), of which the expert fold is worth 1.84×
(`DSV4_VK_EXPERTS=0` arm, O §10).

### 1.2 TTFT (U window, C0' median 153.9 s; campaign best 148.4 pre-merge; fork 103–106)

Bytes are **not** the gap: 251 GB port vs 203 GB fork payload = 1.24× ≈ 5 s (R-l1 headline; the port is
already at ~1.01 reads per (layer, expert) per prompt). The C0' chain report reads **144.4 s of routed
experts on the host** over the run (`p1-c0-r1.log` chain line); the decode window owns ~52 s of that
(821.9 ms/tok × 63), so **prefill's host-MoE step is ≈ 90 s of a 154 s TTFT (ESTIMATED, subtraction
across config worlds — S0 measures it directly)**. That is the TTFT lever: loop order + device-resident
expert compute + overlap, exactly the dossier's S5/R-l1 reading. The remaining ~60 s is dense frames,
attention, staging — already at fork class (mm8 + `CHAIN_GEMM_ROWS` landed).

### 1.3 The VRAM ledger (16 GiB RX 6900 XT, C0' boot lines @ 073a03b6)

| holder | bytes | anchor |
|---|---:|---|
| dense chain (43 layers, 897 matrices + buffers) | **6.40 GiB matrices / 7.11 GiB held** | `p1-c0-r1.log` chain-fit lines |
| tier total budget | **7.85 GiB = 277 residents (15.0 MiB mirror each) + 256 stream slots** | tier boot line; sizing `vk_tier.c:2768-2837`, PIN/POOL env `:2845-2861`, slot carve `fit = fit_raw − slots` at `:2877` (r2 F5) |
| host pool (this window) | 4.00 GiB / 272 experts (RAM, not VRAM) | `COLI_VK_TIER_HOST_GB` |
| store RAM cache | 25.70 GiB (RAM plan 28 GiB) | `ram_tiers` boot line |
| **device total** | **≈ 15.0 of 16 GiB — the card is full at the standing arm** | |

**The bank does not fit beside this.** The fork's bank is `V4_GPU_BANK_MIB 3277` (256 experts × ~12.8 MiB
record, fork `deepseek_v4.c:16638`), and the fork's own answer is *replacement*: bank-first recovery
sheds the VRAM tier exactly when its bytes are what makes the bank fit (`gpu_mfu_cache_shed_all` at
`deepseek_v4.c:19239`, the v6/v5 recovery block `:19164-19245`), then re-promotes post-prefill from the
warm RAM pool. On the port the natural swap is **the stream slots' 3.75 GiB → the bank** during an armed
prefill: they are the same bytes doing the same job (a per-layer window of expert weights), and the
slots are idle at decode. (Sizes: the fork's own slab is 3.27 GiB in its 12.8 MiB record format; the
port's residency is at the 15.0 MiB device-mirror format — 256 × 15.0 MiB = **3.75 GiB**, which is
why the carve is slot-for-slot.) Per-stage budget table in §4.

### 1.4 The do-not-retry register (falsified with model-scale evidence — every stage must respect it)

| lever | falsified by | the differentiator any new stage must claim |
|---|---|---|
| BDA-hybrid decode (pool-resident in-frame MoE) | P1d −1.44 %, "a shuffle of where the same PCIe-bound work is paid" (U §3.4/6.2) | VRAM residency (compute reads VRAM, not PCIe) |
| whole-layer device pin inside the resident budget | `98fcee51`: prefetch 12,644→1,890, TTFT ×2 | an explicit carve/shed that *replaces* budget, never silently takes it |
| dmoe prefill chunk frame as-is | U §2: the armed chunk read 3.75 GiB over PCIe in one submit → amdgpu hard recovery | the ROWS frame-split (S1) + VRAM-resident reads |
| L7 GEMV8 / fmt-12 decode kernels | 13.1 % share of device wait, ≤2.5 % of wall (impl-L7A NO-GO) | — (closed) |
| promote-under-fences (H1) | V-g1 R3: tier decode waits 0.49 ms/tok both arms | — (closed) |
| `.coli_usage`-ranked hot-set overlay (L3) | S7/`98fcee51`: ranking prompt-contaminated, device share pinned ~14 % | decode-only counting (fork `mfu_record` discipline, S2) |
| pool scaling for residency | 3.84 GiB/layer, ~1-layer ceiling on 34 GiB cgroup | — |
| store-side retention as the TTFT theory | R-l1: 1.24× ≈ 5 s, not 60 s | — |
| G1 fence-gap slices (settle reorder/frame merge/spin, as *wait* levers) | V-g1: the whole gap budget is 5.5 ms/tok | only as *glue/round-trip* levers (S5), never as wait levers |
| speculative drafting, 1536-row chunks | O §9 (both negative at this bench) | — |
| mm8 as a decode lever | HANDOVER §2.1 (2026-10-23): the fork's mm8 refuses S<2, so decode at S=1 never sees it — mm8 is prefill-only | — (nothing in this plan retries it; recorded for completeness, r2 F8) |

### 1.5 The amdgpu frame-time boundary — a design constraint, not a bug to fix

K1 (T §3): single submissions of **~2–4+ s of GPU work** (48 heavy layer-calls at S ≥ 256) trigger the
amdgpu hard recovery; the same load passes at 8 layers a frame. U §2: the engaged P1 chunk (3.75 GiB of
PCIe reads inside one submission) lost the device. **Constraint, written into every stage: no single
submission may carry more than ~1 s-class of GPU work — compute from VRAM (~0.1 s per layer-visit at
2048 rows, K1's cross-check) and split chunk-row groups across frames (the S1 cap).** Microbenches cap
frame load at 8 layers-equivalent at S ≥ 256.

---

## 2. Reuse inventory — what is already landed, and which stage eats it

The dossier's 4.5–7 k estimate (§4.4) predates five landings. This plan is sized *after* them:

| landed | anchor @ 073a03b6 | consumed by |
|---|---|---|
| `COLI_VK_DMOE` in-frame MoE wiring (L2 Stage A: route on device, shared + `vkc_dmoe_layer` in ONE frame, split-4 batching, hybrid fallback) | `deepseek_v4_chain.h:683-715` (`v4c_dmoe_arm`), `:1380-1402` (the in-frame branch), `vk_dmoe.h:525-660` | S1's compute, S2's in-frame half, S5 |
| fmt-7 grouped chunk MoE `vkc_moe_rows` (L2 Stage B; `mx_pipe` via `qmatmul_grp_mx.comp` mode 4) | `vk_chain.c:2630` (`our_fmt`), `:2699` (`vkc_moe_rows_ready`), `:2710` (`vkc_moe_rows`) | S1's chunk compute |
| `COLI_VK_TIER_POOL_LAYER` (L2 Stage C: gate-opening residency that takes no device place, proven at model scale — 63 hybrid steps ×3) | `vk_tier.c:929-955` (the plan block), `:865` (promote skip) | S1's publishing seam (the same `vkt_dev_table` contract, device side) |
| `COLI_VK_TIER_PIN_LAYER` scaffolding + `COLI_VK_TIER_HOT` pins | `vk_tier.c:959-970`, `:727/:749` (victim skip) | S1's tenure mechanism |
| K1's finding: per-pair `vkc_moe` is 4.5× *faster* than grouped at S=1 — **no new decode kernel wanted** | T §3 table | S1/S2 decode shape |
| DPROF (G1 S0): decode-window wait/device/submit/role counters + tier decode dprof | `vk_chain.c:3123-3129`, `VkcStats` roles `vk_chain.h:841-893`, `vk_tier.c` decode accumulators | S0's prefill extension, S2/S5 instruments |
| S1+S2 tier loaders: `.load_batch` group reader + `COLI_VK_TIER_STREAM_BYPASS` cache-bypassing reads (8×16 MiB staged pool, OMP parallel) | `deepseek_v4.c:14050-14160` (`v4_vkt_load_batch`, `read_private` at `:10390`), `:14236-14280` (VktConfig wiring) | S1's refill loader (the fork's `read_bytes` discipline, already ported) |
| mm8 tiled GEMM + `COLI_VK_CHAIN_GEMM_ROWS` prompt path; `COLI_VK_PROFILE=RDNA2` stage sets | ENVIRONMENT.md:251 | the prefill dense half is done — not in this plan |
| `vkc_layer_recorded` split batching (default 4) + `vkc_wait_serial` | `vk_chain.c:896-905`, `:3667` | S1's frame-split pattern, S5's settle discipline |
| hybrid worker + epoch/patch discipline (`vkc_dmoe_read/patch/upload`) | `vk_dmoe.h:247-302`, `:577` | all stages' correctness spine |

Not consumed (and correctly absent): the fork's `backend_vulkan_dsv4.c` ABI shim (H, out of scope), the
fork's mHC/dec2/attn-segment/indexer recorders (~4.7 k lines — the port's chain frame model already
covers them, dossier §4.4 row "≈ 0"), `qmatmul_pf4*` (the port's mode-4 MXFP4 GEMM replaces the family).

---

## 3. The stages

Each stage: goal · seams (fork AND port) · LOC · gate additions · the falsifiable arm with
pre-registered bars · stop rule · VRAM/merge notes. LOC are new/changed lines on the port.

### S0 — the prefill DPROF window (the instrument TTFT needs) — **~70–110 LOC**

- **Goal:** make §1.2's ~90 s subtraction a measured per-stage number: a prompt-forward window with the
  same shape as the landed decode window (roles: chunk-A1, dmoe/host-MoE step, staging-upload join,
  tail), printed beside `v4c_report` (`deepseek_v4_chain.h:1596`). The fork's own
  `COLI_V4_CELL_HOST_PROF` buckets (fork `deepseek_v4.c:10829-10884`, fence-wait-subtracted) are the
  shape reference; the port's S0 counters are the decode ones widened (`vkc_dwin(prompt)` opens a window
  per chunk, `vkc_role` stamps the existing sites plus the host-MoE span at
  `deepseek_v4_chain.h:1419-1427`).
- **Seams (port):** `vk_chain.c:3123` (`vkc_dwin` — accept a chunk window), `vk_chain.h:863-868`
  (window accumulators), `deepseek_v4_chain.h:1288` (chunk loop = window boundary),
  `:1403-1430` (A1/MoE/A2 role stamps — three lines), `vk_tier.c` decode-dprof block (mirror for
  `S > VKT_UP_ROWS`), `deepseek_v4.c` `TUNE`/timing print.
- **Gates:** `test_dprof` extension; DPROF-off byte-identity (the d602436a precedent).
- **Arm:** one leg, ttft set + `DPROF=1 PROF=2`, ×2. **Falsifiable output (not pass/fail):** the
  prefill decomposition line — predicted shape `host-MoE ≈ 85–95 s, staging/upload join ≈ 20–30 s,
  **[r3 — MEASURED by X-ob0-s0-2026-10-24: host-MoE 49.2 s (31 %, over-attributed ~2×), staging-upload 105.6 s (66 %, under-attributed ~3.5× — the dominant mass), dense A1 host 4.0 s with 70.2 s device GEMM fully overlapped. §1.2's ~90 s estimate retires; S3/S4's levers aim at the staging mass; S1's per-layer ceiling ≈ 3.5 s.]**
  dense frames ≈ 50–60 s`. Every later stage's bar is expressed against this line.
- **Stop/decision rule:** none (instrument). **PR-able standalone: yes** (the DPROF family, upstream-neutral).

### S1 — the VRAM expert bank, one layer, through the landed seams — **~350–600 LOC** (candidate (a))

The substrate stage: device-resident experts **without BDA** (answers the P1d no-win: the same
gate-opening residency, but the GEMMs read VRAM, not host RAM over PCIe), with upload separated from
compute (answers the amdgpu boundary: bounded staging uploads, ~0.1 s compute frames).

- **Shape (port-native):** the bank is **a pinned per-layer resident section of the tier**, not a fork
  slab: `COLI_VK_TIER_BANK_LAYER=n` plans layer n's 256 experts into *device* residency (place 0,
  real `ColiVkExpert` tensors), pinned (`hot_pin`), with an explicit **carve**: while armed, the stream
  slot budget is reduced by the bank's bytes (256 × 15.0 MiB mirror ≈ 3.75 GiB → slots 256→~2 during the
  armed prefill; the carve is logged like the fork's `vram-plan` ledger lines). Validity: a per-layer
  `bank_valid[256]` bitmap with at-most-once refill (missing-set = routed ∧ ¬valid), loads through the
  **landed** bypass group reader (`v4_vkt_load_batch`, `deepseek_v4.c:14127` — the port's twin of the
  fork's `coli_v4_expert_store_read_bytes` staging refill, fork `deepseek_v4.c:19429-19540`), uploads
  sequential on the bank, bitmap set on success. Because banked experts are ordinary residents,
  `vkt_dev_table` counts them with **zero new gate code** — the exact seam POOL_LAYER proved at model
  scale — and both compute paths are landed: the tier's big-step batch (`issue_big` BC_DEV,
  `vk_tier.c:1408`) at the host step, and the in-frame `COLI_VK_DMOE` path when the all-or-nothing gate
  opens.
- **Fork reference (frozen):** create/refill/shed `deepseek_v4.c:19139-19620` (bitmap clear on layer
  switch `:19291-19294`, staging pool `:19470-19500`, sequential upload `:19503-19540`, bank-first
  recovery/shed `:19164-19245`); the backend slab itself lives in the ABI shim
  `backend_vulkan_dsv4.c:4660-4715+` (create `:4660`, upload/refill `:4706+`), while
  `backend_vulkan.c:10696+` is the bank pool/descriptor/compute machinery (`eg2_bank_ensure_pool`)
  — **neither is ported** (r2 F4); the compute half is the port's `vkc_moe_rows`/tier batch.
- **The frame-split cap (the U §6.1 slice, in here):** `COLI_VK_DMOE_ROWS_MAX=R` (default 0 = today's
  whole-chunk behavior): `vkc_dmoe_layer`'s big branch (`vk_dmoe.h:624-639`) splits a chunk's rows into
  ≤R-row groups with `vkc_submit(0)+vkc_begin()` between groups (the `vkc_layer_recorded` pattern,
  `vk_chain.c:896-905`). This is what makes the P1 chunk arm *runnable at all* on this rig.
- **Seams (port):** `vk_tier.c:925-1000` (`vkt_plan` — the bank block beside POOL_LAYER/PIN_LAYER),
  `:1179` (`st_alloc`) + `:2845-2891` (the carve: PIN/POOL env `:2845-2861`, slot carve
  `fit = fit_raw − slots` at `:2877`; the sizing/STAGE block above it `:2768-2837` — r2 F5), `:1548`
  (slot reuse — banked layers keep tenure), `deepseek_v4.c:6761` (`coli_v4_moe_routed` — the refill
  call site, post-router), ENVIRONMENT rows.
- **LOC:** tier 180–300, engine arm/refill 90–150, ROWS_MAX split 40–80, tests+docs 60–100.
- **Gate additions:** `test_vk_tier` bank case (at-most-once refill, carve accounting, decline paths:
  no room → the plan is the history's, one line) **plus an explicit 2-layer case** — arm layer n then
  layer m: the bitmap clears at the switch and each layer refills at-most-once (the fork's
  switch-clear discipline `:19291-19294` never fires at a fixed `n`; r2 F6); `deepseek-v4-tiny-check`
  dmoe case with the bank armed (token-exact at tiny); ROWS-split vs unsplit at equal rows →
  identical `y` (unit); `tests/vulkan_engines.sh deepseek`.
- **Arm (one window, ×3 interleaved):** C0' control / `BANK=26 DMOE=26 ROWS_MAX=512` (the P1 chunk
  question, now runnable) / `DMOE=26 ROWS_MAX=512` **no-bank sub-leg** (r2 F1: separates bank-compute
  from carve-cost) / `BANK=26 DMOE=26` decode leg / off-control byte-identity.
  **Pre-registered bars:** (i) chunk leg: TTFT ≥ −2 s median (the spec's −2.5–5 s/layer band) with
  **no device loss** and the **engagement guard (r2 F1)** — the run-line device-served routed share
  (the `p1-c0-r1.log:43` counter; control 97.0 %, prefill-dominated) stays **≥ ~90 % of the off-arm
  control**: the banked layer serves by construction, so the counter measures the *non-banked*
  layers' engagement beside the carve (the retired `prefetched`-count guard could not pass by
  construction — with slots carved 256→~2 it counts slot capacity, a collapse `98fcee51` already
  priced at TTFT ×2); (ii) decode leg: ≥ +1 % median (one layer's 822/43 ≈ 19 ms/tok ≈ +1.2 %
  ceiling); (iii) off-arm text byte-identical.
- **Stop rule (r2, F1):** a **chunk-leg verdict miss** — TTFT ≤ +1 s median or the engagement guard
  tripping — **does not cancel S3/S4**: it records *"persistent bank cannot coexist with chunk-outer
  streaming — 98fcee51's answer at bank scale"* (the chunk-outer probe tests a coexistence regime
  S3's reorder abolishes; 98fcee51 measured that regime: prefetch 12,644→1,890, TTFT ×2). A
  **decode-leg miss** records "single-layer decode tenure is not worth arming" and likewise does not
  cancel S3/S4. What stops S3/S4 is **machinery failure** — any hang, device loss, ledger/VRAM
  discrepancy, or off-arm non-identity → the bank substrate is falsified on this rig, stop arming it
  (S2/S5 proceed — they do not depend on the bank). **S3's gate is S1's machinery landed**
  (carve/tenure/refill + the token-exact tiny leg) **+ S0's prefill line + S3's own window.**
- **VRAM:** bank 3.75 GiB carved from slots (256→~2 while armed; prefill tenure only, restored at
  prefill end — the fork's shed/recover discipline). Residents untouched (277). **PR-able standalone:
  yes, as two PRs** — (i) `COLI_VK_DMOE_ROWS_MAX` (generic dmoe safety, upstreamable alone),
  (ii) the bank carve+tenure (generic "bank a layer" tier capability).

### S2 — decode residency: decode-counted heat + decode-time slot repurpose — **~250–500 LOC** (candidate (b)'s substrate)

The decode wall's 821.9 ms/tok is `tier CPU computes 81–87 % of routed pairs` — a *residency* problem
(placement/quantity), not a compute-path problem (the tier computes resident pairs on device today).
Two differentiators against the falsified L3/S7 class, both from the fork's own design:

1. **Decode-only counting** (fixes S7's diagnosis "the `.coli_usage` ranking is prompt-contaminated"):
   make the fork's `mfu_table` the decode-selection authority. **The lift is already landed (r2, F2):**
   `c/mfu_table.c` (147 lines) + `mfu_table.h` (150) sit in the tree at 073a03b6 (`port/store-mfu`),
   included at `deepseek_v4.c:8432-8436` ("the fork's mfu_table.c, lifted as-is — S-store map §5b");
   `V4HotPolicy` carries `MfuTable mfu` and saves/loads `<model>/.coli_mfu` (`:9331-9375`); decode
   recording is wired (`coli_v4_expert_store_mfu_record` `:5498`/`:10307`; the discipline is the
   fork's `deepseek_v4.c:10541-10566`: `count==1` records, prefill `count==0` never). **The real work
   is the ranking repoint:** the tier still ranks on the merged `.coli_usage` history
   (`vk_tier.c:1025-1043` — "the history's counts stay the only authority"); point the decode
   ranking at the decode-only table, recording in `vkt_dev_count`'s call path (`vk_dmoe.h` ids →
   tier heat). Consult S-store-mfu-map §5b's pre-registered rules (record at the two issue seams,
   `decode=1` only, prefill never; keep `rt_count`/`note_routed` as-is so `.coli_usage` semantics do
   not change; the seed is the load-bearing half — prewarm ranked by `mfu_ref`, not merged
   `policy->usage`). **Authority rule (r2, F2): when `.coli_usage` and `.coli_mfu` disagree, the
   decode-only `.coli_mfu` table wins for decode-time ranking; `.coli_usage` remains the authority
   for prefill-window decisions (pins/prewarm unchanged), and the two files are never merged — the
   fork's rule, `deepseek_v4.c:9370-9372** (the standing file holds 1.56 M selections,
   `bench/coli_mfu.fixed`).
2. **Decode-time VRAM repurpose:** the stream slots (3.75 GiB) are idle at decode ("a big prompt chunk
   only", `vkt_stream_prefetch` no-ops, `deepseek_v4_chain.h:1406`). At the prefill→decode transition,
   re-plan the slot budget into residents (277 → ~530) ranked by the decode counts, with the
   post-prefill refill discipline the fork documents (`deepseek_v4.c:16130-16146` — on the port the
   transition is an explicit re-plan + warm re-fill from the pool/store, dual-residency optional).

- **Seams:** fork `mfu_table.{c,h}` + `expert_cache.c:202` (the one `mfu_record` caller; `:250-275`
  is the shed/GPU-exclusion block — r2 F3) as reference; port landed-lift anchors
  `deepseek_v4.c:8432-8436`, `:9331-9375`, `:5498`/`:10307`; port work seams
  `vk_tier.c:1025-1043` (the merged `.coli_usage` ranking to repoint; hot-share line `:1043`),
  `:925-1000` (plan/rank), the `vkt_dev_count` bookkeeping (`vk_tier.c:3169`),
  `deepseek_v4.c:15240` (the phase seam — `use_prefill_pool` / target_token transition),
  ENVIRONMENT rows.
- **LOC (r2, F2):** mfu-table lift **0 — already landed** (`port/store-mfu`); tier-ranking repoint
  80–150, transition repurpose 120–200, authority/seed rules + tests+docs 50–150 — **~250–500**.
- **Gate additions:** `test_mfu_table` (lift with the fork's suite, B §3 T3); a decode-window
  **engagement counter** gate (device-served share must move — the G17 wrong-lever trap);
  off-arm byte-identity.
- **Arm:** decode set ×3: control / `DECODE_HEAT=1` / `DECODE_HEAT=1 SLOT_REPURPOSE=1`.
  **Pre-registered bars:** device-served routed share ≥ 35 % (from 13–22 %) AND decode ≥ +15 %
  (0.55 → ≥ 0.63); falsifier: share unmoved (the S7 shape) or decode < +8 %.
- **Stop rule:** miss → the decode-residency half is falsified *at this counting discipline*; record,
  ship nothing armed, S5 shrinks to the glue-only remnant. (Note honestly: this is the highest-
  falsification-risk stage — it is staged after S1 so its window can also carry S1's confirm leg.)
- **VRAM:** decode tenure only; prefill unchanged (slots restored). **PR-able: yes** — (i) decode-
  counted heat table (generic, the fork's own story), (ii) the transition repurpose (generic tier).

### S3 — prefill layer-outer loop reorder (the TTFT surgery) — **~700–1200 LOC** (candidate (c))

The port's chain prompt path is **chunk-outer** (`deepseek_v4_chain.h:1288` chunk loop → `:1370` layer
loop); the fork's prefill is **layer-outer** (fork `deepseek_v4.c:23524` layer loop → `:23580+` chunk
loop of `chunk_width` 128; its own comment: "A true prefill is layer-major: every prompt position
crosses this layer before the next one begins", `:23559-23563`). With layer-outer:

- the tier's **slot reuse across a layer's chunks goes live** (`vk_tier.c:1548` — dead code on the chain
  path today, R-l1 §1: reuse distance 43 layers → 0) — the slots *become* the bank for every layer in
  turn: fill ~220 experts once, serve all chunks of that layer, free at switch;
- **one bank serves all 43 layers sequentially** — every layer's visit computes from VRAM (the landed
  dmoe/fmt-7 path with S1's carve), removing the ~90 s prefill host-MoE step layer by layer;
- the prefetcher's next-*layer* prediction (`vk_tier.c:1733`, `T.pred[i]`) becomes a per-layer-switch
  ring fill — the overlap S4 formalizes.

- **Seams (port):** `deepseek_v4_chain.h:1180-1480` (`v4c_forward_seg`): restructure the prompt path to
  `for layer { for chunk { … } }` — the per-layer host-state lowering that today runs at `c0==0`
  (`:1323-1363`: window/compressed/ring/indexer writes) becomes per-layer-once at the layer's first
  chunk; the per-layer prepare/count checks (`:1200-1216`) move to the layer head; the ks-split
  compressed-row copy-backs (`:1389-1397`, `:1409-1416`) stay per chunk but inside the layer; the
  end-of-forward `pull` copy-out (`:1442-1470`) is unchanged (forward end). `v4c_chunk_rows` (`:902`)
  sizing per chunk unchanged. **Numerics:** at `GEMM_ROWS=0` the per-row GEMV invariant holds — the
  reorder is bit-neutral by construction; at the ttft set's `GEMM_ROWS=-1` the tiled path's bits already
  depend on the chunk cut (the `:1266-1276` comment) — **pin the cut sequence identical per row** (same
  `v4c_chunk_rows` per layer) so S3 changes only the *serving path* (device GEMM vs CPU — thresholded
  class, envelope-gated, never byte-claimed).
- **LOC:** loop restructure 400–700, state-lowering hoist 100–200, ks re-plumb 100–200,
  counters/report 50–100. Behind `COLI_VK_CHAIN_ORDER=layer` (default `chunk` = today, byte-identical).
- **Gate additions:** golden leg vs the D11 re-pin baseline (thresholded, envelope recorded); the
  3072-entry decline path (`:1194-1199`) re-tested at the new order; `test_v4_serve_framing`;
  `vulkan_engines.sh deepseek`; S0's prefill line as the engagement gate.
- **Arm:** ttft set ×3, `ORDER=layer` (+ the S1 bank armed on all layers in turn = the composed fold).
  **Per-layer banking is owned here (r2, F6):** the landed arm arms exactly one env layer
  (`v4c_dmoe_arm`, `deepseek_v4_chain.h:683-715`) and S1's `BANK_LAYER=n` never switches, so S3 adds
  the fork's layer-switch refill (bitmap clear `:19291-19294`, ring take/prefetch `:19296-19301`) and
  a per-layer bank rotation — S5's `lo..L` multi-layer arm (`vk_dmoe.h:525`) pulls forward if more
  than one layer banks at a time (its LOC already carried at S5; S1's 2-layer gate case is the unit
  seam). **Pre-registered bars (r3, re-expressed against S0's measured decomposition — X-ob0-s0: host-MoE 49.2 s / staging-upload 105.6 s / dense-host 4 s of TTFT 159.1):** S0's staging counter − ≥ 50 % (105.6 → < 53 s) AND host-MoE − ≥ 50 % (49.2 → < 25 s), or TTFT ≥ −25 s (159 → ≤ 134); falsifier: TTFT gain < 10 s or any numerics event outside the recorded envelope. S1's measured per-layer ceiling ≈ 3.5 s (2.4 staging + 1.1 MoE).
- **Stop rule:** miss → keep S1/S2, cancel S4, S5 shrinks; the fold's TTFT claim closes as measured
  negative. **Depends on S1's machinery landing, not its chunk-leg verdict (r2, F1)** — the bank
  carve/tenure/refill is what the reordered loop computes through; the gate is machinery landed +
  S0's prefill line + this stage's own window.
- **VRAM:** neutral (same buffers, different order; per-chunk scratch unchanged).
  **PR-able:** V4-only, engine header — the hardest sell; keep the default off and the diff confined to
  `deepseek_v4_chain.h` + the one call site in `deepseek_v4.c`.

### S4 — the host-RAM ring (next-layer prefetch feeding the bank) — **~250–450 LOC** (candidate (d))

Only meaningful in the S3 world (next *layer* is the next consumer). Fork C15: while layer L computes,
`pread` layer L+1's whole 256-expert set into an mmap'd ring on a worker; at the switch, the whole-ring
PCIe upload replaces the disk refill ("the disk stays busy from here to the last layer"). The fork's
measured 0-hit global-ring failure (O §11) does not apply: that was a *global heat-ranked* window with
reuse distance 43 layers; this is a *sequential next-layer* stream with reuse distance 1 — the fork's
own `bank_layer != layer → memset` distinction (dossier §2.6).

- **Seams (fork):** `deepseek_v4.c:18481-18716` (ring state, `v4_ram_take_par` `:18557`, cancel flag
  `:18494-18503`, `v4_ram_prefetch` `:18684`), `deepseek_v4_ram_prefetch.h` (75), the take/prefetch call
  sites at `:19296-19300`; **(port):** the refill seam S1 added (the ring becomes the bank refill's
  source ahead of the bypass reader), a loader thread (the chain has no cross-frame prefetch — dossier
  §4.4 "ring 0.3–0.6 k").
- **LOC:** worker+ring+take/cancel 150–250, engine wiring 50–100, tests/docs 50–100.
- **Gates:** cancel-path test (fork issue #4's lesson: teardown must not wait the in-flight stream);
  off-arm byte-identity.
- **Arm:** S3 world ×3, `RING_GB=3.2`. **Bar:** TTFT ≥ −5 s beyond S3's leg (the overlap term; the byte
  term is already ≈ 0 by R-l1). **Stop:** < 5 s → record, keep the code off.
- **VRAM:** host RAM 3.2 GiB **out of the RAM plan** (the 28+8 GiB OOM trap, HANDOVER §8 — the ring
  must replace plan bytes, not add; document beside `COLI_VK_TIER_HOST_GB`). **PR-able:** generic tier
  loader extension.

### S5 — decode cell discipline: the glue kill — **~200–400 LOC** (candidates (b)+(e) residual)

With S1/S2 armed layers, the landed in-frame path already records dense+shared+route+MoE per layer with
split-4 batching and no per-layer finish (`deepseek_v4_chain.h:1380-1402`). The remaining 519 ms/tok
glue mass is the *round trips themselves*: the `h2d` copy + host router read (gone for armed layers —
route in-frame), the `routed` memcpy (`:1430`, gone), `cdn` copy-outs (ks layers only), A2 as a separate
frame (`:1417` — fold into the armed layer's frame), and the settle discipline (replace residual
per-layer waits with `vkc_wait_serial`, `vk_chain.c:3667` — G1's S1 shape, now worth something only
because the host step is gone; as a *wait* lever it stays falsified). Queue-ahead per se is
wall-neutral (SF-5): port the *class* (defer the settle to the next natural sync), never the letter.

- **Seams (port):** `deepseek_v4_chain.h:1370-1435` (the A1/MoE/A2 block), `vk_dmoe.h` multi-layer arm
  (`v4c_dmoe_arm` `:683` takes a layer *set* — `vkc_dmoe_prepare` already supports `lo..L` ranges,
  `vk_dmoe.h:525`; the port's arm restricts to one layer), `COLI_VK_CHAIN_SPLIT` retune.
  **(fork reference:** dec2 `deepseek_v4.c:20665-20790`, FFN opener `:21404-21757` — both *shapes*, not
  ports: the chain's frame model is the port's answer to both.)
- **LOC:** multi-layer arm 60–120, A2 fold + split retune 40–80, settle reorder 40–80, glue trims
  60–120.
- **Gates:** split-variants × text (thresholded); DPROF glue counter as engagement gate.
- **Arm:** decode set ×3, composed with S2. **Bar:** glue counter − ≥ 40 % (519 → < 310 ms/tok) AND
  decode ≥ +10 %; falsifier < +5 %. **Stop:** record, keep off. **PR-able:** the multi-layer arm and
  the settle reorder are separately small and generic.

---

## 4. The VRAM budget, per stage (16 GiB card; the honest table)

Baseline (C0' @ 073a03b6): chain 7.11 held + tier 7.85 (277 residents + 256 slots) ≈ **15.0 GiB — full**.

| stage | residents | stream slots | bank | notes |
|---|---|---|---|---|
| S0 | 277 | 256 | — | instrument only |
| S1 (armed prefill) | 277 (untouched — the `98fcee51` rule) | **256 → ~2** (carved 3.75 GiB) | **3.75 GiB, layer n, prefill tenure** | the carve is the swap: same bytes, better tenure; restored at prefill end (fork shed/recover, `deepseek_v4.c:19164-19245`) |
| S1 (decode leg) | 277 + bank layer persists if armed | idle anyway | 3.75 (layer n) | decode tenure = the bitmap persists across tokens; VRAM from the idle slots |
| S2 (decode) | **277 → ~530** at the transition | → ~0 at decode (idle, repurposed) | — | the decode-time repurpose; prefill shape unchanged |
| S3 | unchanged | become the per-layer bank in turn | (the slots themselves) | neutral; one layer's window at a time, freed at switch |
| S4 | unchanged | unchanged | — | ring is **host RAM from the plan** (3.2 GiB; the 28+8 OOM trap — rebalance, never add) |
| S5 | unchanged | unchanged | — | neutral |

Coexistence law: **the bank and the slot budget never add** — the bank is the slots' bytes with a
different tenure. Residents are never silently reduced (the measured strangling). Every carve prints a
ledger line (the fork's `vram-plan` discipline) and the `VRAM_MAX_USED_MB` guard stays on every arm.

---

## 5. Numerics and gates strategy

- **The off-arm law:** every stage's default is today's bits; the window's control must be text
  byte-identical (T §2.1's 9/9 precedent). This is mergeable-ness: a declined stage costs nothing.
- **The armed-arm class:** thresholded, never bitwise. Pre-register the divergence class per stage:
  S1 = the rank-order vs ascending-id sum class (chain_moe's accumulation order vs the CPU's,
  `vk_chain.h:432` — the P1d deterministic mid-generation divergence, U §3.5); S3 = the chunk-cut class
  at `GEMM_ROWS=-1` only (bit-neutral at 0); S2/S5 = serving-path class (device GEMM vs CPU rows).
- **The folded-MoE oracle the port lacks** (dossier §4.5): build it inside S1, not before: (i) the tiny
  gate is already token-exact (`tiny-check-dmoe`, landed with L2 A) — extend it to the bank-armed layer
  and the ROWS-split; (ii) the real-envelope leg = the **D11 golden re-pin now running on 073a03b6 is
  the pre-surgery baseline** — every stage's armed arm records first-divergence position against it and
  the envelope in its ENVIRONMENT row; strong parity claims only after a fresh golden leg per merged
  stage (≈ 4.1 h/run, F10 — schedule them at stage boundaries, not inside windows). **Pin
  re-validation rule (r2, F7):** the pin is a baseline for the tree it was cut on — after any
  upstream merge, run one off-arm text-identity control against the D11 pin *before* any armed arm
  records first-divergence against it.
- **Gate set per merge (all stages):** `vk-tier-check`, `vk-chain-check`, `vk-strict-check`,
  `deepseek-v4-tiny-check`, `test_v4_serve_framing`, `cu_tier.c -DCOLI_CUDA -fsyntax-only`,
  `tests/vulkan_engines.sh deepseek` (shared-code stages: the full engines script), plus each stage's
  additions above. Engagement counters are gates (G17): S0's prefill line, S1's placement/ledger line
  (the POOL_LAYER precedent), S2's device-served share, S5's glue counter.

---

## 6. Schedule, cumulative LOC, and the stop-loss ladder

| stage | LOC (cum.) | elapsed | standalone PR? |
|---|---|---|---|
| S0 prefill DPROF | 70–110 (0.1 k) | 0.5 wk | yes |
| S1 bank + ROWS cap | 350–600 (0.5–0.7 k) | 1.5–2 wk | yes (two PRs) |
| S2 decode heat + repurpose | 250–500 (0.7–1.2 k) | 1.5–2 wk | yes (two PRs) |
| S3 layer-outer reorder | 700–1200 (1.4–2.4 k) | 2–3 wk | conditional (V4-only, default off) |
| S4 ring | 250–450 (1.6–2.9 k) | 1 wk | yes (generic) |
| S5 cell/glue discipline | 200–400 (1.8–3.3 k) | 1 wk | partially |

**Total: ~1.8–3.3 k new/changed lines (r2, F2 re-scope), 6–10 wk elapsed** with serialized windows and golden legs —
**under the dossier's 4.5–7 k / 5–8 wk**, and the delta is accounted for: the dossier's "MoE inside the
frame for V4 (fmt 7) 1.5–2.5 k" collapsed to ~0 (L2 A+B+C landed, ~550 LOC, proven at model scale), the
dense/cell machinery's "2.5–4 k" shrank to S3+S5 (the chain's frame model already *is* the cell — one
frame per layer, `vkc_layer_recorded` batching, device mHC, per-row GEMV invariance), DPROF + the
bypass loaders (~0.3 k) landed as G1-S0/S1+S2, and the fork's mfu_table landed whole (`port/store-mfu`,
r2 F2) — S2's lift is now a ranking repoint. What remains is exactly the two masses V-g1 named
(822 CPU-MoE + 519 glue) plus the loop-order/ring machinery the port never had.

**Stop-loss ladder (the dossier's staged discipline, now inside Option B):**
- **S1 misses** → split by kind (r2, F1): a *verdict* miss does **not** cancel S3/S4 — the chunk leg
  records "persistent bank cannot coexist with chunk-outer streaming — 98fcee51's answer at bank
  scale", the decode leg records "single-layer decode tenure is not worth arming" (S3's gate is S1's
  machinery landed + S0's prefill line + S3's own window); a *machinery* failure (hang, device loss,
  ledger/VRAM discrepancy, off-arm non-identity) falsifies the bank substrate → cancel S3/S4; S2/S5
  proceed (bank-free); the campaign falls back to consolidation + PR queue.
- **S2 misses** → decode residency closes (second falsification of the class, now with decode-only
  counting — a clean kill); S5 shrinks to glue-only (~+5 % class); full-parity decode claim is closed.
- **S3 misses** → keep S1/S2 (both standalone); cancel S4; TTFT closes at whatever S1 bought.
- **S4/S5 miss** → record; nothing downstream.
- Any stage's *numerics* event outside the envelope → that stage parks armed, ships default-off only.

---

## 7. Risks register

1. **Merge burden — measured now, not guessed.** `vk_chain.c` is touched by 26 % of the last 400
   upstream commits (dossier §4.3). **Fresh check (2026-10-25, `ls-remote` + GitHub compare, no fetch):
   upstream `dev` has moved 7398a85f → `681c0f17`, 7 commits, 18 files** — the `fix/vk-host-pool-heap`
   series (`vk_tier.c` +49 lines changed, `vk_tier.h` +6, `backend_vulkan.c` +21, `cu_tier.c` +3,
   `deepseek_v4.c` +23, engines, `tests/vulkan_engines.sh` +11) plus a qwen36 folder fix. **None touch
   `vk_chain.c`, `vk_dmoe.h`, or `deepseek_v4_chain.h`.** (That file list is network-read, not
   fetch-verified — re-verify it from the fetched diff at merge time:
   `git diff --stat 7398a85f..681c0f17`; r2 F7.) → **A fresh merge IS advisable before stage 1**
   (1–2 h with gates): it is tier-adjacent exactly where S1/S2 land, and taking it early converts a
   known future conflict into a clean base. Fold in the owed frag-mask gate fix (N2 follow-up) with it.
2. **The amdgpu frame-time boundary as a design constraint** (§1.5): max ~1 s-class GPU work per
   submission; S1's ROWS cap and the bank's VRAM-resident compute are the compliance mechanism; every
   arm keeps the device-loss fallback path (the landed CPU re-run, U §2) as the safety net, and a device
   loss in an arm is a *stop*, never a debug.
3. **Engine-loop surgery vs upstream `deepseek_v4.c` churn** (42 % of commits touch it): S3's diff is
   confined to `deepseek_v4_chain.h` (a V4-only header included once) + one call site; the frame API
   (`vkc_begin/submit/finish/layer_recorded`) is kept stable so upstream chain work re-bases over it.
   Merge at every upstream release boundary regardless (PORT_PLAN §6.2).
4. **The OOM hazards:** the profile-ttft-fill × decode-pool composition that killed leg (a) first
   attempt (V-g1 header); the 28+8 GiB plan trap (S4's ring); the cgroup ceiling for S2's pool growth.
   Every window pins its RAM plan and records the scope's own peak (U's 29.9/34 method).
5. **Falsification-adjacency:** S2 sits one differentiator away from two falsified levers (S7 overlay,
   `98fcee51` pin). The plan's answer is the pre-registered device-served-share bar (a *mechanism* gate,
   not just tok/s) — if the share does not move, the stage is dead regardless of noise.
6. **Bench-window serialization:** S0–S5 need ~6 windows + golden legs; the D11 re-pin currently
   running owns the rig until done — treat its output as the baseline freeze before S0's leg.
   **While that leg holds the rig, `port/up-2276` and its `up2276-merge` worktree are frozen** —
   nothing lands, rebases, or merges on either until the pin completes (r2 F7).
7. **Cross-day drift** (T §4's +6.6–7.1 s TTFT lesson): every window carries its own same-day control;
   no cross-window claims without it.

---

## 8. The recommendation

**Stage order: S0 → (fresh upstream merge + frag-mask) → S1 → S2 → S3 → S4 → S5.**

Rationale (payoff-per-risk on our measurements): S1 lands the substrate machinery S3 needs at the
campaign's cheapest price — under r2/F1 its chunk leg is a *recording* leg (98fcee51's answer at bank
scale; the decisive TTFT falsifier is S3's own window); S2 attacks the single largest mass
(821.9 ms/tok, 50.7 %) at medium risk with two named differentiators; S3 is the big surgery and is
gated on S1's machinery landing (not its chunk-leg verdict); S4 rides S3; S5 composes last. If the
owner weights decode above everything, S2 may swap ahead of S1 — they are independent — but
S1-first keeps the option's kill-switch earliest.

### Reviewer verdicts (recorded r2 — the cross-examination this revision answers)

| stage | verdict |
|---|---|
| S0 prefill DPROF | **GO** |
| S1 bank + ROWS cap | **GO-WITH-FIXES** (F1, F5; decode leg and machinery are sound) — fixes applied r2 |
| S2 decode heat + repurpose | **GO-WITH-FIXES** (F2 — rescope; differentiator judged real/mechanism-gated) — fix applied r2 |
| S3 layer-outer reorder | **GO-WITH-FIXES** (F1 stop-rule rewiring, F6) — fixes applied r2 |
| S4 ring | **GO** (conditional on S3 by design; differentiator vs the falsified global ring is real — sequential reuse-distance-1 vs heat-ranked distance-43) |
| S5 cell/glue | **GO** (composes last; wait-lever discipline correctly carried) |

Stage-1 go/no-go per the review: NO-GO as written — GO immediately after the F1/F2 plan edits (this
revision *is* those edits). Document merge verdict: OK with notes (40/42 anchors exact; apply F1–F8
before any lane is dispatched — done here).

### Stage 1 (S1) implementation checklist — 10 lines, no re-derivation

1. Merge upstream `7398a85f..681c0f17` (7 commits, host-pool-heap series) into `port/up-2276` —
   first re-verify the file list from the fetched diff (`git diff --stat 7398a85f..681c0f17`, r2 F7),
   then run one off-arm text-identity control against the D11 pin before any armed leg (r2 F7); run
   all six gates; land the frag-mask strict-gate fix in the same merge window.
2. `vk_tier.c` beside the POOL_LAYER block (`:929-955`): `COLI_VK_TIER_BANK_LAYER=n` — plan layer n's
   256 experts to place 0, `hot_pin` them, `promote` skips them (`:865` pattern); decline paths print
   one line each (no room / out of range / hash layer).
3. `vk_tier.c` carve: while armed, `st_alloc` (`:1179`) and the carve block (`:2845-2891` — PIN/POOL
   env `:2845-2861`, slot carve `:2877`, sizing above at `:2768-2837`; r2 F5) reduce the
   slot budget by the bank's bytes (≈ 3.75 GiB → slots 256→~2); one boot ledger line
   "bank=layer n, 256 experts, slots 256→k"; restore at prefill end (re-plan).
4. `vk_tier.c` refill: `bank_valid[256]` bitmap; missing-set = routed ∧ ¬valid; loads via the landed
   `v4_vkt_load_batch` bypass path; uploads sequential; bitmap set on success; cleared on layer switch
   (fork `deepseek_v4.c:19291-19294` discipline); counters `bank_refills/bank_bytes`.
5. `deepseek_v4.c`: call the refill at the armed layer's routed step (inside `coli_v4_moe_routed`
   `:6761`, post-router, pre-issue); env plumbing + ENVIRONMENT.md row.
6. `vk_dmoe.h` `vkc_dmoe_layer` big branch (`:624-639`) + `vk_chain.c`: `COLI_VK_DMOE_ROWS_MAX=R`
   (default 0) — split the chunk's rows into ≤R-row groups, `vkc_submit(0)+vkc_begin()` between groups
   (the `vkc_layer_recorded` pattern `vk_chain.c:896-905`); document the ~1 s/submission boundary.
7. `deepseek_v4_chain.h`: no changes expected — verify the landed arm (`:1380-1402`) picks the banked
   layer up when `vkt_dev_table` counts 256 (the POOL_LAYER proof); hash layers skip (`:687-691`).
8. Tests: `test_vk_tier` bank case (at-most-once refill ×2 visits, carve accounting, decline paths)
   + the 2-layer case (switch clears the bitmap, per-layer at-most-once refill; r2 F6);
   `deepseek-v4-tiny-check` dmoe with bank armed (token-exact); ROWS-split unit (split vs unsplit at
   equal rows → identical `y`); `tests/vulkan_engines.sh deepseek`.
9. Docs: ENVIRONMENT.md rows (`COLI_VK_TIER_BANK_LAYER`, `COLI_VK_DMOE_ROWS_MAX`); vulkan.md
   "the prefill bank" section (the carve law, the boundary law); PORT_STATUS note.
10. Window (×3 interleaved, same-day controls): (a) ttft set, off-control — byte-identity; (b) ttft
    set + `BANK=26 DMOE=26 ROWS_MAX=512` — bar: TTFT ≥ −2 s, no device loss, device-served share
    ≥ ~90 % of control (the run-line counter); (b′) ttft set + `DMOE=26 ROWS_MAX=512` no-bank sub-leg
    — attributes bank-compute vs carve-cost (r2 F1); (c) decode set + `BANK=26 DMOE=26` (decode
    control with it) — bar ≥ +1 %; apply the r2 stop rule verbatim (a chunk-leg miss records, it does
    not cancel S3/S4); record either way.

### Total campaign LOC estimate

**~1.8–3.3 k new/changed lines** (S0 0.1 + S1 0.35–0.6 + S2 0.25–0.5 + S3 0.7–1.2 + S4 0.25–0.45 +
S5 0.2–0.4 k), 6–10 weeks elapsed with serialized windows — against the dossier's 4.5–7 k / 5–8 wk,
with the delta itemized in §6 (L2's landing collapsed the fmt-7 half; the chain frame model already
*is* the cell). Every stage default-off, byte-identical when disarmed, and independently falsifiable —
the campaign's method, now aimed at the architecture itself.
