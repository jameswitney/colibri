# G1 — the decode pipeline gap (~200 ms/tok fence-vs-device): attribution, the fork's queue-ahead, ranked slices

Lane: spec-G1 of the manager-run parity campaign (2026-10-24). **Read-only investigation; no arms were run, no
repos touched.** This is a hypothesis-driven spec built on existing logs; **its first gate is an instrumented
measurement it cannot itself run** (§6). Everything below is either (a) arithmetic from committed logs, (b) code
anchored at a commit, or (c) a labeled hypothesis.

Port anchors: `port/up-2276` @ **2bd8ac93** (read via `git -C /root/Projects/colibri-upstream show 2bd8ac93:<path>`;
line numbers below are that ref's). Fork anchors: `/root/Projects/colibri-ds4-vulkan` @ **d11fba5b**.
Evidence logs: `/root/bench-colibri/up2276/` (= `bench/up2276/` @ 2bd8ac93): the L7 Step-0 pair
`gemv8-step0-prof-{8,24}.log` (RDNA2 **decode set**: `COLI_VK_MM8=1 COLI_VK_TIER_HOST_GB=8
COLI_VK_TIER_PROMOTE=32`, `COLI_VK_CHAIN_PROF=2`), the L2/P1 window-2 arms `p1-c0-r{1,2,3}.log`,
`p1-p1d-r{1,2,3}.log`, `l2-*-r*.log` (RDNA2 stage-aware → **ttft set** + `COLI_VK_TIER_STREAM_BYPASS=1`,
`HOST_GB=4` — the boot line `p1-c0-r1.log:2` proves the set), `fork-full-r3/r4.log`, `fork-noexperts-r1.log`,
`decode-prof.log`. Derived numbers from the L7 lane's Step-0 (its §9, `specs/L7-f8-decode-projections.md`) are
re-derived here and carry that lane's caveat (live `.coli_usage`, restored `.coli_mfu`).

The headline (L7 §9 / PORT_STATUS 2026-10-23 II): decode-window chain device **wait (fence) 438.7 ms/tok** vs
device **time (PROF timestamps) 242.2 ms/tok** → **~196 ms/tok of fence-waiting without corresponding chain
device compute**. §2-§3 below bound how soft that number is; §5-§7 say what to do about it.

---

## 1. The chain's frame model at decode — what actually runs per token (code)

`v4c_forward_seg` (`c/deepseek_v4_chain.h:1180`), the host-step path (dmoe off — every decode arm before
`COLI_VK_DMOE`), per layer i, `nr == 1`:

1. **Record A1** into the open frame: the previous layer's join (`v4c_join`, `:1157`), `v4c_pre` (`:1024`),
   `v4c_attention` (`:1066`), `v4c_post` (`:1033`), `v4c_pre`, then `vkc_copy(ch->h2d, …, ch->nrm, …)` —
   **submit** at `:1400` (`/* A1 */`, `vkc_submit(0)`).
2. `vkt_stream_prefetch(i, nr)` (`:1403`) — decode no-op ("a big prompt chunk only").
3. **`vkc_finish()` (`:1404`) — the drain**: submits the open frame and `frame_wait`s **every** frame in the
   16-deep ring (`c/vk_chain.c:784-789`). The header contract states the design: "Then the frame is waited for"
   (`deepseek_v4_chain.h:26-27`).
4. Host reads `vkc_ptr(ch->cdn)` (compressed rows; only `ch->ks.on` layers), then **record A2** = the shared
   expert alone (`v4c_shared`, `:1147`), **submit** (`:1414`, `/* A2: the shared expert, while the host computes
   the routed experts */`).
5. **Host MoE** (`:1415-1427`): `spec_now()` t1 → `coli_v4_moe_routed(...)` — the router on the host from
   `vkc_ptr(ch->h2d)`, the tier's `vkt_issue`/`vkt_join` inside (engine hooks `c/deepseek_v4.c:13951-13956`,
   `:14277`), the CPU's expert share → `ch->host_ms += …` (`:1427`). A2 is the only device work overlapping it.
6. `memcpy(vkc_ptr(ch->routed), ch->host_routed, …)` → `vkc_begin()` (`:1429`) → layer i+1's A1.

The tail (`last` chunk): copy-outs + `vkc_submit(1)` — a synchronous submit+wait (`:1459`).
A frame = one command buffer + fence + descriptor pool, `VKC_FRAMES 16` ring (`vk_chain.c:52`); every frame ends
in exactly one `vkQueueSubmit` (`vkc_submit`, `vk_chain.c:821-855`; `KC.st.frames++` at `:850` — the report's
"frames" **is** the chain submit count). `frame_wait` (`frame_wait`, `:731-752`) polls the fence for `COLI_VK_CHAIN_SPIN_US`
(default **2000 µs**, `:723-727`) then blocks; every call adds to `KC.st.wait_ms` and `KC.st.waits`
(`:738`) — **`waits` is counted but never printed** (`VkcStats`, `c/vk_chain.h:843-844`; the report line prints
only wait_ms, `deepseek_v4_chain.h:1596-1600`).
The spin design comment names the expected shape: "two frames a layer" (`vk_chain.c:723-725`). The dmoe path
instead batches: `vkc_layer_recorded` every `COLI_VK_CHAIN_SPLIT` (**default 4**) layers, no per-layer finish
(`vk_chain.c:884-893`, `deepseek_v4_chain.h:1390-1391`).

**Per decode token, derived** (decode window = prof-24 − prof-8, same config, 16 tokens):

| quantity | per token | arithmetic |
|---|---:|---|
| chain frames = chain submits | **81.6** (1.90/layer of 43) | (2592−1287)/16; = A1+A2/layer + tail, matching `:724-725` |
| ops recorded | 2,649 (~61.6/layer) | (79627−37239)/16 |
| matmuls | 518.4 | (14931−6636)/16 |
| chain fence wait (`wait_ms`) | **438.7 ms** | (22025.4−15006.2)/16 |
| chain device time (PROF) | **242.2 ms** | (76600.9−72726.2)/16 |
| **the gap** | **196.5 ms** | 438.7−242.2 |
| host MoE (`host_ms`) | **30.3 ms** | (176782.4−176298.3)/16 |
| decode wall | 1,695 ms (÷24) / 1,770 (÷23) | `after_first=40.675` |
| tier decode: device expert instances | 55.9 | (1218−324)/16 |
| tier decode: routed instances (all) | 258 | (5934−1806)/16 |
| fence waits | **unknown** | the counter exists, unprinted |

Cross-checks: 81.6 ≈ 2/layer confirms the A1/A2 structure dominates; the whole-run 64-token arms agree
(`p1-c0-r1.log:42`: 5,904 frames / 64 fwd ≈ 92/fwd incl. one chunked prompt forward ≈ 680 frames).

**The structural facts that matter for the gap:** (a) the A1→host-MoE dependency is **data-forced** — the host
router reads `h2d`, so A1's result must reach the host before the MoE; (b) the only device work overlapping the
host MoE is the small A2 frame; (c) the tier issues its own queue during the MoE and joins inside it; (d) the
promote worker uploads experts concurrently (`vk_tier.c:859-900`: queue + `pthread_cond_signal`, ≤
`COLI_VK_TIER_PROMOTE`=32/forward in the decode set = ≤ 480 MiB/token of PCIe traffic).

---

## 2. Attribution from the existing evidence — and what it cannot resolve

### 2.1 Where the wait sits (structure, from §1 + logs)

Per token the chain's wait_ms accrues almost entirely in the 43 per-layer `vkc_finish` drains: each waits
A1(i+1) plus any A2(i) tail. Steady state per layer ≈ max(A1 device ≈ 5.6 ms, A2 tail) + queue-position delay +
signal/wakeup latency. Summed device-side execution is the 242.2 ms; everything else in the 438.7 is —
by construction of `frame_wait` — time the host spent blocked while the GPU was **not** executing marked chain
ops. The candidate fillers: work ahead of the waited frame on the GPU (the tier's own queue: decode batches +
promote uploads), fence-signal/wakeup latency, or **method error** (§2.3).

### 2.2 The two config worlds disagree — the gap is config-dependent

- **Decode set** (step-0 legs, `PROMOTE=32 HOST_GB=8`): wait 438.7 ms/tok, device 242.2, gap 196.5.
- **ttft set** (p1/l2 arms, no promote lever): whole-run chain waits 18.5–23.6 s over 64 tokens
  (`p1-c0-r1.log:42` 23,580.7; `l2-c0-r*` 19.1–23.6 s). **64 × 438.7 = 28,077 ms > 23,581 ms — impossible.**
  So in that world the decode-window wait is ≤ ~368 ms/tok even with zero prompt wait; with a prompt wait of
  8–12 s (plausible: `decode-prof.log` shows 12.9 s whole-run at 8 tokens) it is **~180–245 ms/tok**, i.e. at
  or below the 242 ms of device time — **no gap**. The step-0 pair is the only log pair that shows one.

### 2.3 The leg-diff failure mode (the honest error bar)

The two step-0 legs did **not** run identical prefills: the auto-fit diverged — prof-8 chunked the prompt at
**512** rows, prof-24 at **768** (`gemv8-step0-prof-8.log:24` vs `-24.log:24`, the free-VRAM race), and routing
history differed (live `.coli_usage`). The diff `(wait24 − wait8)/16 = 438.7` assumes equal prompt waits P;
`wait24 = P24 + 24w` and `wait8 = P8 + 8w` give `w = 438.7 + (P8 − P24)/16`. Bounds: `w ≤ 22025.4/24 = 917`
(P24 ≥ 0) — and the §2.2 ttft-set anchor says the no-promote world sits near ~200. **The true decode-set gap is
somewhere in ≈ [0, ~460] ms/tok with a point estimate of 196.5; the committed logs cannot pin it.** This is the
spec's central honesty clause: the ~200 ms is a hypothesis with one supporting diff and one contradicting
cross-config bound, not a measurement.

### 2.4 The bigger hole the same logs expose (flagged, not owned by G1)

Decode-set wall 1,695 = wait 438.7 + host MoE 30.3 + **~1,226 ms/tok unattributed by any CLI counter** (the
ttft-set world: ~1,450). The serve path already computes the decomposition — per-request `expert_disk_s /
expert_wait_s / expert_matmul_s / attention_s / head` (`v4_prof_emit`, `c/deepseek_v4.c:18058`, marks at
`:18296-18305`, the `attention_s` fold at `:18391`, emit at `:18393`; `g_v4_prof_block_s` wraps every `target_token`, `:15240`) — **but the CLI
bench path never prints it** (the CLI's decode diagnostics stop at `TUNE decode` / `timing`, `:19090-19105`).
PORT_STATUS's "host ≈ 1,331 (75%)" reading attributes the pool to the routed-expert path by subtraction; the
chain's own `host_ms` counter (30.3 ms/tok at decode) says the in-MoE host time is small in the decode-set
world, so most of the pool is **outside** the MoE call — unmeasured. Any G1 slice must be sized against this
pool (§6 R4).

---

## 3. Stop-findings (deliverable 4)

- **SF-1 — the gap is not yet a measurement.** §2.3: the 196.5 point estimate rests on a leg pair whose
  prefills differ (512 vs 768-row chunks), and the only independent cross-check (§2.2, the ttft-set arms'
  whole-run waits) is inconsistent with per-token waits anywhere near 438.7 in the no-promote world. The gap
  could be ~0 or ~2.3× the point estimate. **First gate: the instrumented leg (§6). No code slice before it.**
- **SF-2 — "device-time under-measurement" is mostly ruled out, with arithmetic.** PROF marks fire on every
  recorded op (`prof_mark` at `vk_chain.c:961`, `:2669`; copies `:991`, `:1088`), the per-frame query budget is
  `VKC_PROF_Q 512` (`vk_chain.h:56`) vs ~60-120 marks in a decode frame, and the printed buckets sum to the
  total (76603 ≈ 76600.9 ms, `gemv8-step0-prof-24.log:35`). What timestamps cannot see: between-frame gaps
  (queue turnaround, submit latency, fence signal) — real time but µs-scale per boundary at 81.6 frames/token
  unless the queue drains, in which case the *next* wait is short, not long. So the wait-vs-device excess is
  **not** plausibly hidden chain compute; if real, it is **other GPU work under the chain's fences** (the tier)
  or **method error**.
- **SF-3 — fence-granularity/spin artifacts are bounded small.** The 2 ms spin + 50-150 µs wakeup
  (`vk_chain.c:723-727`) over ≤ ~90 waits/token bounds at ~4-13 ms/tok — real but minor; folded into slice S3.
- **SF-4 — even the top of the range is a fraction of the decode deficit.** Recovering all ~460 ms/tok moves
  decode-set 0.565 → ~0.76 tok/s (1/1.310 s); the fork is 1.15-1.17 with the expert fold (CAMPAIGN.md: decode 2× is the
  fold, 1.84×; `fork-full-r3` 819 ms/tok vs `fork-noexperts-r1` 1,563 ms/tok). G1's ceiling is real but
  second-order to the fold — its value rises exactly when L2-class device-MoE lands and the dense chain becomes
  the critical path (§7 S1's strategic note).
- **SF-5 — the fork's queue-ahead is not a portable win.** Fork `docs/ENVIRONMENT.md:438`: "Wall-clock
  **NEUTRAL** at the 4k operating point (…the join's fence wait moves from the attn phase into hc2, same
  total…) — the substrate the route/M1 folds plug into, not a perf win." Porting the letter of it buys ~0;
  porting the *class* (defer the settle to the next natural sync) is only worth code where the queue actually
  holds independent work during the moved wait (§4, §7 S1).

---

## 4. The fork's queue-ahead mechanism, precisely (deliverable 2)

**What it is** (PLAN_submit_merge M2+QA, 2026-10-13/14; all anchors fork @ d11fba5b):

- The prefill cell's mHC tail ([hc2 post] → [hc2b pre_norm] + route gate) records into ONE **private** command
  buffer with its own fence — the cell-tail session: `backend_vulkan.c:6371-6381` ("that is what enables
  QUEUE-AHEAD — the caller submits the attention segment first with its fence left pending
  (**cell_join_commit_nowait**) and submits this buffer while the segment still executes, so the queue never
  drains between them"), state at `:6383-6391` (`g_tail_fence/g_tail_ready/g_tail_seg_pending`).
- The engine arms it per cell — **prefill only**: `if (!result && batch > 1 && pooled && …) arm(1)`
  (`deepseek_v4.c:11141-11148`); disarm + settle at `:11228-11240`. Global switch `COLI_DSV4_VK_QUEUE_AHEAD`,
  **default on**, debug readers force it off (`deepseek_v4.c:22366-22388`).
- **What it queues/fences**: the joined attention segment submits with its fence **pending** (`g_join_deferred`,
  `:6392-6404`); the tail records against the device-resident wo output (no host round trip), and the tail's
  **leading barrier** — gated on `g_tail_seg_pending` — replaces the fence with a queue-order memory dependency
  (`:6558-6573`). The tail close is the ONE wait point: submit tail → wait tail fence → the settle waits the
  segment's fence "already signaled by queue order" and runs the copy-outs (`coli_vk_dsv4_tail_close`,
  `:6583-6615`; `ds4vk_join_settle` `:6425-6520`; `coli_vk_dsv4_join_settle` `:6521`).
- **Numerics class**: "identical dispatches in identical order, barriers replace fences -> **bitwise**"
  (`:6379-6381`); verified value-tracer 2/2 identical (ENVIRONMENT row).
- **Measured effect class**: wall-neutral standalone (SF-5); the substrate that let later folds (route/M1,
  branch-round-on-device) remove host round trips — and at decode the fork never needs it, because with the
  expert fold there is **no host MoE step between dense segments**: the S=1 dense projections go out in one
  dec2 submit (`ds4vk_dec2_qkv_impl` `:15682`, `ds4vk_record_fmt8_s1` `:13726-13740`) and the experts run on the
  device in the same stream.

**Port-side equivalent, in the chain's frame model:** the chain already has the primitives — a 16-frame ring
whose waits defer to ring wrap, `vkc_wait_serial(serial)` to wait ONE frame while later ones run
(`vk_chain.c:3641-3648`, "while later ones run on" `vk_chain.h:762`), and `vkc_submit(0)` (no wait). The
anti-queue-ahead is the per-layer `vkc_finish()` drain (`deepseek_v4_chain.h:1404`). The equivalent change is
S1 (§7): submit A1 → record+submit A2 (independent of the host read) → `vkc_wait_serial(A1)` for the h2d/cdn
reads → host MoE — i.e. "settle the one fence you need, keep the rest in flight." The dmoe path's
`vkc_layer_recorded` (split=4, no finish) is the same discipline already landed for the in-frame-MoE world.

**Falsified upstream/fork levers this spec must NOT re-try** (PORT_STATUS "Portfolio re-assessment" +
"Falsified", HANDOVER-2026-10-23 §2, U-l2 §3-§6, L7 §9): async PILOT (P2.2 — superseded by upstream's
`vkt_join`, which the port already has: issue → CPU work → join, `vk_tier.c:2322-2360`); mm8 as a decode lever
(S<2 refusal); L3 tier-side hot-set placement (neutral ×3); whole-layer dmoe (`COLI_VK_DMOE`+`PIN_LAYER`:
TTFT doubled); byte-economy-as-2.8× (counter mismatch, 1.24× real); decode-only dmoe P1d as a shippable lever
(neutral, "a shuffle of where the same PCIe-bound work is paid" — U §3.4/§6.2); the fork's `qmatmul_s1g`
wo_a-group fold (GPU-time neutral, B-fork-inventory:116 via L7 §3).

---

## 5. Where the ~196 ms most plausibly sits (ranked hypotheses)

- **H1 — tier work under the chain's fences (the only mechanism that makes the gap real and recoverable).**
  The tier's own queue runs beside the chain's: per layer the MoE issues a device batch (55.9 device expert
  instances/token) and joins it, and in the decode set the promote worker uploads ≤ 32×15 MiB = **480 MiB/token
  over PCIe** (`vk_tier.c:859-900`) — ~56 ms of bus occupancy at the 8.5 GB/s the logs measure, plus device
  expert dispatches. None of it is in the chain's timestamps; all of it can sit under the chain's A1 fence
  waits (bandwidth/contention, or ring serialization if the driver maps both compute queues to one ring —
  unmeasured). Explains ≲ ~60-100 ms/tok of the point estimate; **only in the decode set** — consistent with
  §2.2's no-gap ttft-set bound. Predicts: the gap shrinks when `COLI_VK_TIER_PROMOTE=0`.
- **H2 — method error (the diff's P8≠P24), dominant at the point estimate's softness.** §2.3. Predicts: the
  instrumented leg's per-forward wait ≈ 200-300 ms/tok in the decode set too.
- **H3 — per-frame overheads (submit + turnaround + signal latency).** 81.6 submits+frames/token; RADV submit
  ~20-60 µs; fence signal + wakeup bounded ~4-13 ms/tok (SF-3). Real but small; addressed by S2/S3, not by
  queue-ahead.
- **H4 — timestamps under-count chain compute.** Ruled mostly out (SF-2).
- **H5 — OMP team wakeups.** Host-side; lives in the §2.4 unattributed pool, not in `wait_ms`; bounded ~4-13
  ms/tok by op counts. The instrumented leg's block-time print closes it.

---

## 6. Slice 0 — the instrumented leg (design only; the manager schedules it in the next GPU window)

**Goal:** turn §2's bounds into per-token, per-role numbers, and close the §2.4 pool. ~80-110 LOC, env-gated,
zero behavior change at default.

**Counters (chain, `c/vk_chain.c` + `c/vk_chain.h` ~55 LOC):**
- A decode-window flag + role stamp: `vkc_dwin(int on)` (engine calls it with `nr==1` from
  `v4c_forward_seg`), `vkc_role(role)` around the A1/A2/tail record sites (`deepseek_v4_chain.h` ~10 LOC);
  `vkc_begin` stamps `f->dec/f->role` (~6 LOC).
- Per-window accumulators, filled where the counters already tick: `d_wait_ms[role]`, `d_wait_n`, `d_frames`,
  `d_submit_ms` (time inside `vkQueueSubmit` during the window), and `d_dev_ms[role]` (the PROF deltas at
  `frame_wait`, `vk_chain.c:741-749`) (~20 LOC). Print one line in `v4c_report` beside the existing report:
  `chain decode: N fwd, submits S, waits W, wait X ms (A1 a / A2 b / tail c), device Y ms (A1 p / A2 q), submit
  Z ms` — plus the so-far-unprinted `VkcStats.waits` on the main line (~8 LOC).

**Counters (tier, `c/vk_tier.c` ~15 LOC):** decode-window (`S <= VKT_UP_ROWS` — the existing class,
`:2189/:2298/:3172`) accumulators `d_wait_ms/d_dev_ms/d_cpu_ms` beside `T.wait_ms/T.dev_ms/T.cpu_ms`
(`:2341-2347`) + `d_up_bytes` in `promote()`; print beside the existing "decode: …" share (`vkt_report:3011`).

**Engine (`c/deepseek_v4.c` ~10 LOC):** print `g_v4_prof_block_s` deltas and per-token head/other spans at the
`TUNE decode` line — `block_s` already wraps every `target_token` (`:15240`), so wall − block isolates
head/sampling/generate-glue, block − (chain wait + MoE) isolates forward glue. (The full fork-style
`COLI_V4_CELL_HOST_PROF` host-phase profiler — fork `deepseek_v4.c:10829-10884`, fence-wait-subtracted buckets
— is the heavier alternative; not required for the first leg.)

**Env:** `COLI_VK_CHAIN_DPROF=1` (family grammar of `COLI_VK_CHAIN_PROF`); composes with `PROF=2`.

**Run plan (~15-20 min GPU):** the step-0 shape, 2,515-tok prompt / 64 tokens, decode set, ×2 (stability, not
claim-grade): (a) `DPROF=1 PROF=2` decode set; (b) same + `COLI_VK_TIER_PROMOTE=0` (H1's sharp test);
optionally (c) ttft-set + `DPROF=1` to anchor §2.2.

**Pre-registered decision rules:**
- **R1** — `d_wait − d_dev` (A1 role) < 25 ms/tok in (a): the gap is artifact/latency noise → close G1's code
  slices, record the negative, re-rank to the §2.4 pool.
- **R2** — 25-100 ms/tok: slice S1 only; pre-register the +2% decode bar (below the house +5% win gate, since
  the ceiling is ~6% of wall).
- **R3** — > 100 ms/tok AND (b) cuts it ≥ half: the gap is promote/tier interleave → the slice is a **decode
  promote gate** (defer/limit promotions inside the dense window — a pacing knob, NOT hot-set placement, which
  is falsified); design a second leg before building.
- **R4** — the unattributed pool (wall − block − d_wait) > 500 ms/tok: escalate to the manager — G1's ceiling
  is small against it; propose the pool lane first.

---

## 7. Candidate slices, ranked by expected ms/tok per LOC (design only)

| # | slice | LOC | expected ms/tok (decode set) | falsified by |
|---|---|---:|---|---|
| **S0** | the instrumented leg (§6) | ~80-110 | gates [0-460]; prevents wasted slices | its own R1-R4 |
| **S3** | `COLI_VK_CHAIN_SPIN_US` 2000→5000 at decode (env row only) | ~2 | 0-13 (SF-3 bound) | leg (a) shows wakeup term < 2 ms/tok |
| **S1** | the settle reorder: A1 submit → record+submit A2 → `vkc_wait_serial(A1)` → cdn memcpy + host MoE; knob `COLI_VK_CHAIN_DSETTLE`, default off, refusal falls back to today's finish | ~45-60 | **0-60**: removes the drain-all (finish waits every frame) and starts A2 during A1's tail; bounded by A2's duration (~1-3 ms/layer) — the moved wait does not vanish (the fork's own neutral record, SF-5) unless A2 genuinely fills it | arm ≤ +2% decode median, or leg shows A1-wait − A1-device < 25 ms/tok (R1) |
| **S2** | decode frame merge: fold A2 into A1's frame (`COLI_VK_CHAIN_DMERGE`): halves submits 81.6→~41/tok + one boundary less per layer; costs the A2-during-MoE overlap (~30 ms/tok at pool8) | ~30-45 | **−30…+40 (two-sided)** — wins only if boundary+submit cost > overlap lost; the `COLI_VK_CHAIN_SPLIT` precedent (vk_chain.c:879-883: every 1-4 layers 58.3 tok/s vs one-frame-per-forward 44.4, on another engine) says the optimum is shape-dependent | arm ≤ +2% decode median |
| — | promote gate (only via R3) | ~20-30 | up to the H1 share (~60) | R3's second leg |

**Non-slices (do-not-retry, §4's list):** async PILOT / expert-issue-before-wait re-derivations (upstream
`vkt_join` already in-tree); any tier-side placement/hot-set lever; whole-layer or decode-only dmoe as a decode
lever; mm8/fmt-kernel work at S=1 (L7 closed); wo_a grouped fold.

**Arm design (S1/S2, after the leg):** the standing runner `/root/bench-colibri/run-arm2276.sh`, RAM_GB=28,
desktop-present guard, ×3 interleaved reps, medians; base = the decode set (fixed, matching the step-0 legs so
the numbers concatenate); arms = base + knob. Controls: the §6 report lines present in every log (engagement:
`d_frames > 0`, role counters non-vacuous — G17 discipline); `vram0` floor guard; store counters held
comparable (`STREAM_BYPASS` fixed). Predictions pre-registered from the leg's numbers: predicted Δdecode ≈
(leg's A1-gap share) × (fraction the slice removes); record either way.

**Strategic note:** S1/S2's value compounds with L2 — when the host MoE shrinks (device MoE / fold), the
per-layer finish disappears into the dmoe path's split-4 batching and the dense chain becomes the critical
path; the settle discipline is then the difference between a drained and a fed queue at ~10 frames/token. Build
S1 so its knob grammar survives that world.

---

## 8. Implementation checklist — slice S0 (10 lines, executable without re-derivation)

1. On the merge head, re-verify the seams: `vk_chain.c` `frame_wait` (:731), `vkc_begin` (:787), `vkc_submit`
   (:821), `VkcStats` (`vk_chain.h:843`); `deepseek_v4_chain.h` A1 (:1400), finish (:1404), A2 (:1414), MoE
   (:1415-1427); `vk_tier.c` d_routed (:2189), d_served (:2298), join counters (:2341-2347), `vkt_report`
   (:2990-3012).
2. `vk_chain.h`: add the decode-window counters + roles to the KC stats block (~8 LOC); declare `vkc_dwin`,
   `vkc_role`.
3. `vk_chain.c`: stamp `f->dec/f->role` in `vkc_begin`; accumulate `d_wait_ms[role]`/`d_wait_n` in
   `frame_wait` (:738), `d_dev_ms[role]` in the PROF loop (:741-749), `d_submit_ms` around
   `coli_vk_queue_submit_dev` (:847), `d_frames` in `vkc_submit` (:850); env `COLI_VK_CHAIN_DPROF` in the
   family grammar.
4. `deepseek_v4_chain.h`: call `vkc_dwin(nr == 1)` at the seg's top; `vkc_role(VKC_R_A1/A2/TAIL)` at the three
   record sites; extend `v4c_report` with the decode line + print `st.waits` on the main line.
5. `vk_tier.c`: `T.d_wait_ms/d_dev_ms/d_cpu_ms` at the S≤VKT_UP_ROWS sites + `T.d_up_bytes` in `promote()`;
   extend `vkt_report`'s "decode:" clause.
6. `deepseek_v4.c`: print the block/head spans at the `TUNE decode` line (`:19090`) — `g_v4_prof_block_s`
   delta over the decode window, wall, and their difference.
7. Gates: `make -f Makefile VK=1 ARCH=native -j16 vk-chain-check vk-tier-check vk-strict-check`;
   `deepseek-v4-tiny-check`; default-off verified (DPROF unset → byte-identical counters path); CUDA
   double-compile (`cu_tier.c -fsyntax-only`).
8. Docs: one `ENVIRONMENT.md` row beside `COLI_VK_CHAIN_PROF` (default off; what it prints; the R1-R4 rules by
   reference).
9. Request the GPU window: legs (a) decode set + `DPROF=1 PROF=2`, (b) + `PROMOTE=0`, (c) ttft set + `DPROF=1`;
   2,515/64, ×2 each; commit logs to `bench/up2276/g1-dprof-*`.
10. Apply R1-R4; write the verdict into HANDOVER §4/PORT_STATUS with the measured per-role table; only then
    open S1 (or close G1 with the recorded negative).

---

## 9. Sources

Logs: `bench/up2276/gemv8-step0-prof-{8,24}.log` (the diff pair; boot lines 6-24 for placement, 24 for the
512/768 chunk divergence, 34-36 reports, 60 tier line), `p1-c0-r1.log` (ttft-set boot line 2, chain line 42),
`p1-p1d-r1.log` (dmoe engagement lines 43-46), `l2-c0-r*`, `decode-prof.log`, `fork-full-r3.log`,
`fork-noexperts-r1.log`. Docs: `specs/L7-f8-decode-projections.md` §1/§9 (the Step-0 attribution and its
caveats), `docs/PORT_STATUS.md` (2026-10-23 II block: the ~200 ms observation; falsified list; P2.2
supersession), `docs/HANDOVER-2026-10-23.md` §2 (do-not-retry), `docs/research/U-l2-p1-arms-2026-10-24.md`
§3.4/§6 (P1d decode no-win), `docs/ENVIRONMENT.md` rows 251/323 (profile sets, spin). Code: port @ 2bd8ac93 as
cited; fork @ d11fba5b `c/backend_vulkan.c:6371-6615`, `c/deepseek_v4.c:11141-11240, 22366-22405, 10829-10884`,
`docs/ENVIRONMENT.md:438`.
