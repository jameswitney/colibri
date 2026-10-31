# AM — PW-E: the fork's 6 async MoE compute lanes — implementation-ready spec (2026-10-26)

Lane: PW-E-design of the manager-run parity wave 3. **Read-only on both repos; this file is the
only write. No GPU, no arms.** Fork = `/root/Projects/colibri-ds4-vulkan` @ `d11fba5b`. Port =
`/root/bench-worktrees/up2276-merge` @ `a8f45741` (the current tip; `deepseek_v4_chain.h` anchors
re-verified there). Evidence logs: `/root/bench-colibri/up2276/` — `w1-gf-dprof-r1.log` (the
stacked GF DPROF leg: `:34` store, `:44` chain decode, `:71` tier), `w1-c0-r1.log` (C0), the AK
close (`docs/research/AK-pw-a2-…md` §1/§2, both trees), `audit-fork-r1.log` (`:3335/:5350/:5357`),
`fork-full-r3.log` (`:17/:18/:4093`), and the fork's own A/B records
(`colibri-upstream:docs/research/C-perf-evidence.md` §2 + `K-lanes-result.md` + `I-decode-lanes-design.md`).

**The verdict up front.** The fork's decode does not read less disk than the port — it *hides* the
same ~52–59 GB decode-window read mass behind six async read+compute lanes (AK §2/§5). The port's
decode window carries the equivalent mass **serially on the engine thread**: tier decode-dprof CPU
**61,808 ms / 63 tok = 981 ms/tok (66 % of the 1,475 ms/tok GF wall)**, of which ~70 disk misses
(≈939 MB) and ~188 CPU-served expert visits per token are read-wait-then-compute chains
(`w1-gf-dprof-r1.log:71` + AK §1). The lanes are an **engine-level mechanism** (a pthread job pool
inside the per-token MoE step), **not** part of the fork's cell pipeline — the port's A1/A2 frame
structure can host them unchanged (**§4 stop-finding 1: no fold needed; Option-B mass NOT reopened
by this lever**). The never-tested delta is priced by the fork's own A/Bs at **+23 % decode**
(demand lanes, G15) and **−32 % wall** (warm-pool compute lanes, `0f1b06d2`) at *its* operating
points — **UNPROVEN on the port stack**, and the port's own `port/moe-lanes` attempt measured it
**negative (0.449 vs 0.487) with a crashing control arm** (K) — a *different* design on a
3-generations-older stack (§4.3 states it precisely; the do-not-retry list is respected by
construction rules, not by avoidance). Ranked shapes and the pre-registered falsification bars in
§3; the direct port (shape **a**) is the only GO.

---

## 1. The fork's lanes, precisely

### 1.1 What a lane IS

A lane is **one pthread worker** in a single `PilotPool` (`c/pilot_async.c:41-92`,
`struct PilotPool` `:17-40`): a mutex, two condvars (`cv_work`/`cv_done`), a FIFO of job indices,
a fixed job array (`max_inflight`, default 12), and N threads. Not an OMP worker, not a queue slot
in the Vulkan sense — a plain pthread consuming jobs whose FSM is
`IDLE→PENDING→RUNNING→READY|FAILED` with the **commit always on the decode thread**
(`pilot_async.h:15-48` — PLAN_cache §3's single-mutator rule). Three job kinds share the pool:

- **PILOT (read-only)**: the next-hash-layer prefetch (`pilot_pool_enqueue`, `pilot_async.c:217`);
- **DEMAND read+compute**: a decode MoE *miss* — the lane preads the 12.75 MiB expert record into
  a claimed slot and then computes the expert's contribution ("compute-on-land",
  `pilot_pool_enqueue_full` `:208`, worker `:66-87`)
- **DEMAND compute-only** (L4): a *pool hit* — the slab is already resident; the lane runs the
  compute straight off the live slab, no byte load (`pilot_pool_enqueue_compute` `:223`,
  `no_load` flag `:76-82` of the header).

Per-kind counters (`PilotKindStats`, `pilot_async.h:100-137`) feed the engine's boundary line
(`deepseek_v4.c:16408-16459`): `moe_lanes enqueued/joined/joined_slow/failed/computed/
wait_us_sum/wait_us_max/inflight_peak`.

**Creation/sizing** (`deepseek_v4.c:15858-15877`): the pool is created once at v5-cache boot iff
`COLI_DSV4_VK_PILOT_ASYNC` (default on) or `COLI_DSV4_VK_MOE_LANES > 0`, with
`lanes = max(pilot_lanes, moe_lanes)`; partial thread teams degrade gracefully
(`pilot_async.c:126-134`).
The boot print (`:15874`, `fork-full-r3.log:17` "v5-pilot: async lanes=4 max_inflight=12") prints
`coli_v4_pilot_lanes()` — **a cosmetic bug: the pool actually has max(4, 6) = 6 threads**
(cpu-parity census §1 caught this; do not copy the print).

### 1.2 What each lane does per decode token

Per MoE layer per token, inside `moe_token_pipeline` (`deepseek_v4.c:9132`, called from
`block_token_pipeline` `:10208`) — the v5-cache decode block `:9240-9490`:

1. **Route + sort**: the FFN opener's stashed route (device) or the CPU bf16 route → the top-6
   selection sorted **ascending expert id** (`:9216-9225`). All later sums walk this order.
2. **Pilot demand-sync head** (`:9246-9263`): for hash-router layers, join any outstanding PILOT
   prediction for *this* layer's selections *before* classify, so a landed prediction classifies as
   an ordinary MRU hit (no duplicate slot/read). Unbounded wait; `COLI_DSV4_VK_PILOT_FALLBACK=1`
   is the debug opt-out.
3. **Classify** (`:9265-9281`): each selection → `CACHE_TIER_GPU` (VRAM-resident, the MFU tier),
   `CACHE_TIER_MFU/MRU` (CPU-pool hit), or `CACHE_TIER_MISS`.
4. **L2 "fire all k"** (`:9284-9354`): every MISS claims a pool slot **controller-directed**
   (`miss_demand_claim`, the same victim/direction policy as the sync path — `d11fba5b`'s
   split-direction fix) and enqueues a **read+compute job**: the lane preads the record
   (`v5_moe_loader` → `coli_v4_expert_store_read_bytes`) into the claimed slab, then runs
   `v5_moe_cpu_expert_slice` (`:9012-9037` — the *identical* per-expert chain as the sync path's
   `v5_moe_cpu_expert`, but writing a **caller-owned slice** `slices[i*d]` instead of the shared
   accumulator) with `input` (read-only for the MoE call), `expert_weights[i]`, `swiglu_limit`.
   Pool-full/claim-fail ⇒ release and fall back to the synchronous `miss_load` (no-regression path).
5. **L4 compute-only hits** (`:9356-9395`): every MFU/MRU hit enqueues a **compute-only job** over
   the resident slab into `slices[i*d]`; refusal ⇒ compute inline on the engine thread. (This L4
   leg is the "warm-pool lane compute" of the −32 % record; before it, pool hits computed one-by-one
   on the decode thread "at ~2 ms per expert; with a warm pool ~126 selections/token — half the
   decode wall".)
6. **The joins — the only barrier** (`:9397-9436`): first the L4 join, **unconditional** —
   `pilot_pool_wait_slice` per compute-only job (by slice pointer; a lane-side failure recomputes
   inline, fail-closed; every job terminal before `slices` may be freed); then the miss join —
   `pilot_pool_demand_sync` per miss job (waits, commits LOAD→MRU) + `expert_slot_lookup`. A failed
   read leaves the slot released and the lookup misses ⇒ abort exactly like `miss_load` NULL.
7. **The lane merge** (`:9437-9490`): `memset(output)`; the **shared expert** first (its GPU submit
   was *deferred* at `:9459-9495` so the whole lane window overlapped it on a private command
   buffer — "PLAN_host_serialization stage 1"); then the CPU-tier **slices summed in selection
   order** (`:9493-9495`) — "the exact fp sum `expert_cache_compute` evaluates … byte-identical to
   the non-lane path"; then the GPU group submit for the `CACHE_TIER_GPU` entries (+ F2 tail riding
   that submit); then the **one bf16 round**.

So per token the 6 lanes carry: ~254 routed visits − the VRAM-tier's share as read+compute
(misses) and compute-only (hits) jobs, ~4–6 per layer in flight, joined once per layer before the
merge. The decode thread's own work during the window: the shared-expert submit, bookkeeping, and
the joins.

### 1.3 The lane count rationale

`COLI_DSV4_VK_MOE_LANES` **default 6** (`cache_engine.h:168-193`, with the +23 % A/B note
inline) = **the model's top-k** (`num_experts_per_tok = 6`, the route kernel's hardwired 256/6
geometry): one lane per selection means **every miss of a layer can read and compute
concurrently** — the per-layer serial chain (wait-read₀→compute₀→wait-read₁→…) collapses to
width-6. The pool is shared with the 4-lane PILOT and sized `max(4,6)=6`; `max_inflight=12` covers
a layer's k plus in-flight PILOT jobs. Not a core-count derivation — the fork never reserves OMP
cores for the lanes (see §2.4).

### 1.4 Sync/join points (complete list)

- **Per-layer fail-closed joins** at the end of the MoE step (§1.2 step 6) — the only place the
  decode thread waits on lanes;
- `pilot_pool_harvest` at **layer boundaries** in the decode loops (`:23311`, `:23715`) — cheap
  commit of terminal jobs (READY→MRU), never a wait;
- `pilot_pool_quiesce` at **request boundaries** (before the reorder, `:15981`/`:16328`) and
  teardown (`pilot_pool_destroy` `:141-160`) — drain + commit everything;
- the pilot demand-sync head (§1.2 step 2) — hash layers only.

### 1.5 Interaction with the tier's hybrid/host-pool paths

The fork's VRAM tier and the lanes are **complementary, sequential alternatives per selection**:
classify sends `CACHE_TIER_GPU` entries to the fused device group *at the merge* (after the lane
join), and everything else to the lanes. There is no lane↔device concurrency contract to violate —
the only device work overlapping the lane window is the **deferred shared-expert submit**
(`:9459-9495`) and, with `PLAN_gpu_experts=1` (default 0), lane jobs degenerate to read-only and
*all* routed compute moves into the group over GPU-visible host slabs. The decisive policy
interaction is recorded at `:15517-15528`: over a warm pool, **promotion is turned OFF** because
"lane-computed CPU slices ~2 ms each" beat "~19 blocking ~6 ms host→VRAM copies per token"
(measured **−23 % decode with promote on**) — i.e. the fork's own evidence prices the lanes' win as
**CPU-side parallelism, not residency**.

### 1.6 The measured evidence class (what the numbers are and are not)

- **Demand lanes, +23 %** (`C-perf-evidence.md` §2, REVIEW G15; the note at `cache_engine.h:173-179`):
  982-token code prompt, 64-token budget, 2×2 interleaved, **md5 ×4 byte-identical**; decode
  `after_first` 69.2–71.9 → 55.3–57.1 s; decode **0.92 → 1.10–1.19 tok/s**. Fork's own runner class
  (pre-rig), GPU tier on, `MOE_LANES` 0→6.
- **Warm-pool lane compute (L4), −32 % wall** (`0f1b06d2`, C-perf-evidence §2): real checkpoint,
  **warm `.coli_mfu` pool, 10 tokens** — decode **2.05 → 3.0 tok/s**; the pool warm fill itself
  12.0→9.4 s (the warm's byte loads also routed through the lanes, `:15947+`). This is a
  *microbench operating point* (all-hits, warm) — it isolates the compute-only half.
- Both figures are **fork operating points, never re-measured on the port stack**. The parity rig
  logs prove only *engagement*, not the delta: `fork-full-r3.log:17` (pool boot) and
  `audit-fork-r1.log:5350` (`expert_requests=0 … bytes=0` — the store lease path unused at decode;
  the reads ride `v4_direct`, 52.7 GB of them, AK §2). The fork's per-run `moe_lanes` counter line
  prints only at serve-mode request boundaries — absent from the CLI parity logs.

---

## 2. The port's fit

### 2.1 Where lanes slot in: the decode frame walk

Port decode = `v4c_forward_seg` (`c/deepseek_v4_chain.h:1562`) with `n=1, rows=1`; per layer
(`:1794-1852`):

1. **A1** recorded+submitted (`:1826`), `vkt_stream_prefetch` (decode no-op — "a big prompt chunk
   only", `:1828`), **`vkc_finish()` drains** (`:1829`);
2. **A2 = the shared expert alone, submitted and NOT waited** (`:1838-1840`, "A2: the shared
   expert, while the host computes the routed experts");
3. **MOEH** (`:1842-1845`): `coli_v4_moe_routed(...)` on the engine thread → `rows==1` ⇒
   `moe_token_pipeline` (`c/deepseek_v4.c:6781`) — **this is the lane slot**. Inside it:
   route/sort → `v4_vk_token_issue` (`:5705`; the tier takes residents, marks hybrid host-pool
   pairs `taken` — computed later *inside* the join) → loader-lane preload `min(k,9)` (`:5727`)
   → slide-join (`:5776-5815`: the engine thread waits read(c), collects/attaches the view, issues
   read(c+9)) → `v4_vk_token_finish` (`:6047`): **the serial compute loop `:5540-5545`** (`forward_ref` into
   `rows[c*d]` slices, engine thread) → `tier->join` (`:5546`; **`host_pairs` computed inline here**,
   `c/vk_tier.c:2613-2625`) → the ascending slice+device merge `:5550-5566` → one bf16 round;
4. **STAGE**: the routed rows memcpy'd up, `vkc_begin` (`:1846-1852`); the *next* layer's A1 first
   joins A2 (`:1796-1798`).

The fork-faithful mapping is exact: the port's A2-in-flight-during-MOEH is the same overlap window
as the fork's deferred shared-expert submit (§1.2 step 7). A2 device time is thin at GF
(662 ms/window ≈ 10.5 ms/tok, `w1-gf-dprof-r1.log:44`) — so, as in the fork, **the win must come
from 6-way read+compute parallelism, not from device overlap**; the frame structure is a host, not
a prerequisite. No chain edit is required for shape (a): the lanes live inside
`moe_token_pipeline`/`v4_vk_token_finish`, below the chain's per-layer call.

### 2.2 What state must be shared

- **The routed set**: `V4VkToken` (`ids/w/taken`, the full ascending selection, `:5484-5489`) plus
  the compacted `expert_ids/expert_weights` the CPU set walks — unchanged; lanes consume the
  compacted set, the merge walks `vk->full` (already the case, `:5550-5566`).
- **The accumulator**: today's per-expert `rows[c*d]` slices + `output` — **the slice pattern the
  lanes need already exists and is already proven bit-exact** (I-design §3.4: "Upstream already
  proves this bit-exactly in `v4_vk_token_finish`"). The only change is *who fills* `rows[c*d]`
  (a lane) and *when* (concurrently with other experts' reads/computes). The non-vk CPU loop
  (`:6065-6070`, shared `expert_output` accumulator) is *not* the decode path when the tier is on
  and needs no change.
- **The leases/views**: a lane calls `coli_expert_lookup` itself — the store is already
  concurrent-legal: `lookup_hot` (`:10084`) drops `state->mutex` around the read with a per-slot
  `loading_expert` reservation (`:8491`) + `load_ready` condvar (`:8526`); a leased slot is never a
  victim ("refuse, never steal"). Ownership handoff, not sharing: the job owns the view from enqueue
  to publish; the engine thread reads only slices.
- **The input**: `vkc_ptr(ch->h2d)` contents (`:1845`) — host memory, stable for the MoE call.

### 2.3 Interaction with the landed levers

- **DECODE_GROW (PW-A1)**: one-time post-prefill installs (device share 13.1→24.9/27.2 %,
  `w1-gf-dprof-r1.log:71`); lanes take exactly the complement. No VRAM or policy conflict; arms
  keep G on (it is standing).
- **The host pool's hybrid pairs**: `vkt_issue` marks host-pool experts `taken`; `vkt_join`
  computes them inline on the engine thread (`vk_tier.c:2613-2625`; 694 pairs, 2,298.9 ms,
  3,312 µs/pair at GF = **~36 ms/tok, minor**). In E1 they stay inline — and the join itself
  becomes *free overlap*: fire lane jobs, then run `tier->join` (device rows + hybrid pairs) while
  the lanes work, then join lanes, then merge. This is the (c1) schedule and it costs nothing.
  The fork's L4 analogue (compute-only jobs over resident rows) maps onto these pairs later (c2).
- **The loader lanes (9)**: at decode they preload `min(k,9)` — with k≤6 after tier compaction,
  *all* this-layer reads are already in flight; what is serial is wait-read-then-compute. Shape (a)
  **replaces** the loader path for the `rows==1` decode case (misses never touch the loader pool —
  the fork's shape); prefill `rows>1` keeps the union/batch path untouched.

### 2.4 The threading contract (OMP team at 16, the K lesson)

- **No Vulkan from lanes** (`c/vk_tier.h:99-100`: "Never call the dense Vulkan matmuls between
  `vkt_issue` and `vkt_join` from a parallel region (backend rule), and keep one step in flight").
  Lane compute = `coli_v4_expert_forward_ref` over CPU views only — no tier, no backend, no
  `store->gpu` attach (gate lane compute off whenever the CUDA-mirror path would set `views.gpu`,
  I-design §3.3). Issue/join stay on the engine thread.
- **OMP**: the per-expert kernels are internally `#pragma omp parallel for` on both engines — the
  fork's lanes enter full 16-thread teams from 6 pthreads and **still won** (+23 %): plain
  oversubscription is not automatically fatal (the GEMV is memory-bound; static tiles). But the
  port's one attempt measured the oversubscription *signature* (CPU share/token 1.33→2.92 s, K).
  The contract for PW-E: (i) a **separate pool** (never extend the 9-lane loader pool — see §4.3);
  (ii) E1 measures CPU share/token (the K read); (iii) the pre-registered fallback E2 shrinks the
  engine's team by the lane count — the seam exists: `v4_omp_reserve_loader_cpus`
  (`c/deepseek_v4.c:18779-18797`) already subtracts worker counts, and bails when
  `OMP_NUM_THREADS` is set (`:18781`) — the arm runs `OMP_NUM_THREADS=10` or a
  `COLI_VK_MOE_LANES_RESERVE` extension of that function.

---

## 3. Ranked candidate shapes (LOC, falsification bars, the pre-registered arms)

| rank | shape | what | LOC (est.) | verdict / bar |
|---|---|---|---|---|
| **1 (GO)** | **(a) lane-parallel host MoE compute — the direct port** | a `PilotPool`-class pool (~240-300: create/destroy, 2 enqueue variants, `wait_slice`, `demand_sync`-by-key or by-slice, quiesce, stats — trimmed of the fork's `ExpertSlot` coupling; jobs hold a `ColiExpertView` lease + `owns_view`) + the fire/join/merge wiring inside `v4_vk_token_finish` (~150-200; the merge is reused as-is) + knobs/env (~30-40) + `c/tests/test_moe_lanes.c` (stub store, TSAN, fail-closed, lease-safety; ~120-160) | **~540-700** | **build**. Bar: decode median ≥ **+10 %** vs C0 with **byte-identical text**; park if < +5 % |
| 2 | **(c2) hybrid host-pairs on lanes** | move `vkt_join`'s inline `host_pairs` onto the pool (compute-only jobs over `VktHostExpert` host slabs — pure CPU, no backend calls) | ~80-140 | only after (a) lands; the mass is ~36 ms/tok at GF — bar ≥ +2 % alone, else record as absorbed |
| — | (c1) enqueue-early schedule | fire lanes *before* `tier->join` so the join's device wait + hybrid pairs overlap the lanes | +0-20 | **folded into (a)** — it is (a)'s enqueue point, not a separate arm |
| — | **(b) lane-prefetch only** | reads ahead, compute unchanged | 0 | **NOT a candidate — provably a subset** (§4.2) |
| — | (c3) cross-layer async pairs (issue layer L+1's lanes before L's merge) | changes the chain's per-layer join structure | — | **rejected**: touches the frame structure = Option-B territory; out of scope |

**(b)'s subset proof (§4.2) in one line each:** same-layer read-ahead = *already landed*
(loader lanes, `min(k,9)` preload `:5727-5731` + slide-join `:5776-5815`); next-layer pilot =
fork-measured **wall-neutral** (G14: blocking −35 %, wall +0.4 %; G16/T5 DROP,
`C-perf-evidence.md` §2); and both were inside the falsified P2.1's scope. Building (b) buys
nothing the falsification hasn't already priced at ≤0.

### The pre-registered arm design (the W-E window)

- **Stack**: whatever W2 certifies as standing (G+F+C3+fmt-15 default-on at the window's tip);
  **C0 re-baselined in-window** (house rule), `COLI_VK_PROFILE=RDNA2`, `--memory-gb 28`, OMP 16,
  VRAM-guarded, 2,515-tok prompt / 64 tokens, greedy.
- **Arms ×3 interleaved**: `C0` (lanes off) · `E1 = C0 + COLI_VK_MOE_LANES=6` (misses read+compute
  AND hits compute-only — the fork's full shape; separate `COLI_VK_MOE_LANES_HITS` only if E1 wins
  and the split is wanted for attribution) · `E2` (conditional, only if E1 shows the K signature:
  CPU share/token ≥ C0) = E1 + team reservation (`OMP_NUM_THREADS=10` or the reserve knob).
- **Hard gates (no thresholds)**: greedy text **md5-identical across every arm**;
  `COLI_VK_MOE_LANES=0` ≡ C0 byte-identical *and* within noise (the K crash class must not
  reproduce — proven at model scale by the **deepseek-v4-smoke gate** before any bench);
  `enqueued == joined + dropped`, `computed == joined − failed`, `failed == 0`,
  `inflight_peak ≤ max_inflight` on the new `moe_lanes` counter line.
- **The DPROF read** (engagement + attribution, per leg):
  1. the tier's **`decode dprof: waited/device/CPU`** line (`vk_tier.c:3493-3497`) — the **CPU term
     is the engagement counter** (GF baseline 61,808 ms/window = 981 ms/tok; E1 must cut it ≥ 25 %
     or the lanes are not carrying the mass);
  2. the **MOEH bucket at decode**: the roles are stamped (`VKC_R_MOEH`, `vk_chain.h:865`,
     `deepseek_v4_chain.h:1842`) but the decode print (`:2037-2044`) omits host spans — fold a
     ~5-line decode host-span print (A1/A2/MOEH/STAGE, the prompt line's `:2046-2052` shape) into
     the slice-restructure commit so the window has the bucket;
  3. the tier's **`hybrid: … pairs … in place`** line (`:3508-3510`) — unchanged in E1 (pairs stay
     inline; their 36 ms/tok should now overlap the lanes);
  4. the chain decode line (`:44`-class): waits/device unchanged ±5 % (no regression);
  5. the store line (`v4_tokens`, `:34`-class): decode-window misses **unchanged** — lanes *hide*
     reads, never remove them (AK §2; a drop would mean a bug, not a win).
- **Stop rules**: (i) K signature in E1 *and* E2 → **park**, extend the K record with the new stack's
  numbers; (ii) lane `wait_us_sum`/token > 30 % of the CPU-ms saved → the per-layer k is too small
  to amortize the joins → park; (iii) any text divergence → automatic fail, fix before any perf
  read; (iv) the slice-restructure commit fails byte-identity or the smoke gate → stop at step 1 of
  the checklist (the K lesson: no threading on top of an unproven restructure).

**Expected value (projection, not a promise).** Lane-izable mass at GF ≈ 981 ms/tok: ~70 misses
(≈939 MB; ~10 ms/layer of read at the 2.1 GB/s class) + ~188 CPU visits (≈2 ms each ≈ 375 ms/tok)
+ hybrid 36 + glue. 6-wide with the disk never saturating at decode (≈21 MB per ~34 ms layer)
projects the per-layer serial ~20-23 ms → ~10-12 ms, i.e. **save ≈ 300-500 ms/tok → 0.678 →
~0.85-1.05 tok/s** — the fork's +23 % class at a fatter host mass. The fork-parity 1.135 is *not*
claimed: its VRAM tier serves more of the visits.

---

## 4. Stop-findings

### 4.1 Is the fork's lanes' win inseparable from its cell pipeline? — **NO (state it loudly)**

The lanes are **engine-level**: everything they touch lives in `moe_token_pipeline` and a pthread
pool; the cell/submit machinery (dec2, opener, F2 tail) only *supplies* the overlap window, and the
port has the same window class — **A2 submitted at `deepseek_v4_chain.h:1838-1840` and joined at
`:1796-1798`, straddling the MOEH step** — the exact analogue of the fork's deferred shared-expert
submit. Three independent witnesses that the win is not device-overlap-dependent: (1) the fork's
own PROMOTE-off record (`:15517-15528`) prices lane slices (~2 ms) against promotions (~6 ms) — a
pure CPU-side trade; (2) the L4 −32 % record was measured on an **all-hits warm pool** — zero
device dependency, zero reads; (3) the port's A2 window is thin (10.5 ms/tok) yet the mass to
parallelize (981 ms/tok) is untouched by frame structure. **The port's chain frames host the lanes
without the fold; this lever does not return mass to Option-B territory.** (The converse also
holds: lanes alone cannot close the fork's glue/attention advantages — W1's F verdict and the
audit synthesis already own those.)

### 4.2 Is the minimal shape (b) a subset of the falsified design? — **YES (recorded)**

See §3's table: (b) same-layer = landed machinery; (b) next-layer = fork-measured wall-neutral;
both inside P2.1's scope. **PW-E builds (a) or nothing.**

### 4.3 The DO-NOT-RETRY record, stated precisely (what the falsified design was, why the fork's differs)

**What `port/moe-lanes` (P2.1) was** — `colibri-upstream:docs/research/I-decode-lanes-design.md`
(the design) + `K-lanes-result.md` (the result), branch @ `f8e07636` on **upstream `a0037a3a`**
(the pre-campaign port, 2026-10-19): **extend `ExpertLoadJob` — the 9-lane dual expert *read*
pool — with a compute stage**; misses enqueue read+compute jobs *on that pool*; hits optionally
compute-only (`V4_MOE_LANES_HITS`, default 0); a slice restructure of the CPU accumulation; joins
at the existing slide-join site; knobs `V4_MOE_LANES/_HITS/_DEPTH`. **Result**: `lanes=0`
**SIGSEGV** after the first token (the slice refactor itself was broken — the A/B's *control arm
never ran clean*); `lanes=6`: **0.449 vs 0.487 tok/s (−8 %)** with host CPU share/token
1.33→2.92 s — the oversubscription signature. K's own verdict: "the fork's win was measured on a
different store with serial compute… revisit only with a probe that shows join-wait or
serial-compute time that lanes can actually hide" — **that probe now exists**: DPROF's 981 ms/tok
serial tier-CPU term (V-g1/AI), which a0037a3a could not see.

**Why the fork's design differs** (and what PW-E therefore changes): (1) a **separate pool**
(`PilotPool`, 6 threads, its own job array and kinds) — the fork's decode reads and compute share
one consumer set, never the 9-lane store read pool; (2) the fork's control arm is sound
(`MOE_LANES=0` restores the sync path, md5-proven ×4); (3) the fork's lane window leaves the engine
thread otherwise idle (shared-defer + merge), where the attempt kept it inside the slide-join
waits; (4) the stack was three generations old (no host pool, no hybrid pairs, no G/F/fmt-15, no
DPROF). **Construction rules PW-E adopts from K**: never extend the loader pool; land the slice
restructure as its own byte-identity-proven, smoke-gated commit *before* any thread exists;
`lanes=0` is a shipped, tested arm forever; the CPU-share/token read is part of every window.

---

## 5. Risks register

- **Oversubscription reproduces on the port** (the K signature) → E2's reservation arm; if that
  fails too, park with the record (the fork's win then has a stack dependence we cannot buy cheaply).
- **Join overhead eats the win at k≤6/layer** → the wait_us counter + stop rule (iii).
- **Store lease contention**: lanes + loader lanes + engine thread on the store mutex — the
  mutex-drop-around-read design bounds it; the counters (`dropped`) and TSAN gate it.
- **Numerics**: bit-exact by construction (same fn, same args, slice + ascending merge + one
  round); the md5 gate is absolute — any divergence is a bug, never a threshold.
- **Prefill regression**: the `rows==1` guard keeps the union/batch path untouched;
  `v4_moe_routed_only`/`V4_SHARED_HERE` semantics unchanged.
- **Teardown/leases**: quiesce before store destroy; `active_leases == 0` assert (G6-class);
  SIGINT-mid-decode case tested.

---

## 6. The 10-line implementation checklist

1. Land the **decode host-span print** (MOEH/STAGE roles at decode, `deepseek_v4_chain.h:2037`
   print) — 5 lines, gates green, DPROF legs readable; no behaviour change.
2. Land the **slice restructure with lanes nonexistent**: `v4_vk_token_finish`'s serial loop
   (`:5540-5545`) refactored so each expert's `rows[c*d]` is filled by a callable
   (port twin of `v5_moe_cpu_expert_slice`, `fork :9012`) — **byte-identical** at model scale
   (smoke gate) + all standard gates; this is K's crash site, prove it first.
3. Add `c/moe_lanes.c/.h`: the pool (create/destroy, enqueue read+compute + compute-only,
   join-by-slice, quiesce, stats, per-kind counters) — fork `pilot_async.c` trimmed of
   `ExpertSlot`; lease held by the job, released at commit.
4. Wire the pool into `moe_token_pipeline`'s decode path (`rows==1` guard, refuse inside
   `omp_in_parallel()`, refuse when `store->gpu` mirrors would attach): fire misses after
   `v4_vk_token_issue`, fire hits, run `tier->join` (free overlap), join lanes fail-closed, merge
   unchanged. Knob `COLI_VK_MOE_LANES` (default **0**) + `COLI_VK_MOE_LANES_RESERVE` (default 0).
5. `c/tests/test_moe_lanes.c`: stub store, N lanes × M jobs, sequential-reference slice equality,
   forced-FAILED not consumed + lease released, drain-after-error, TSAN build; wire the gate.
6. Teardown: quiesce at request boundary + `active_leases==0` assert at destroy; SIGINT case.
7. ENVIRONMENT/CHANGELOG rows; the `moe_lanes` counter line beside the tier's run line.
8. Full standard gate set ×2 + **deepseek-v4-smoke** at default (lanes=0) — byte-identity vs pre-slice
   commit at model scale.
9. Manager review, then the **W-E window**: C0/E1(/E2) ×3 interleaved, md5 gate, the §3 DPROF read;
   verdict against the ≥ +10 % bar; record CPU share/token either way.
10. On a win: default flip to 6 + D11 contract re-check (deterministic, so text-class unchanged;
    G-arm-style residency notes if counters move); on a miss: park with the counters — the K record
    extended, the never-tested list closed.
