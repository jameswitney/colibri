# Design map — the fork's expert-cache policy on the port's ENGINE STORE (decode hit rate)

Trees: **fork** `/root/Projects/colibri-ds4-vulkan` @ `d11fba5b`; **port** `/root/bench-worktrees/up2276-merge` @ `3bee7ae7`
(S1+S2 bypass landed: `deepseek_v4.c:13786-13860`, `COLI_VK_TIER_STREAM_BYPASS`; bench arms in
`bench/up2276/`, `port-l3` worktree has the L3 logs).

**Three premises in the task are wrong. They are the whole answer, so they come first.**

1. **`48 × 43 × 15 MiB = 30 GiB` is a unit error.** The store's record is **12.75 MiB** (3 × 4.25 MiB fp4+UE8M0 matrices,
   `bench/up2276/l3-a0-hot0.log:39` "bytes=4456448" ×3; `deepseek_v4.c:8637,8643`). 15.0 MiB is the **device-mirror**
   footprint (`V4_EXPERT_MIRROR_MIB`, expanded f32 scales; `vk_tier.c:2152` "budget 7.04 GiB = 240 experts of 15.0 MiB").
   So `48 × 43 × 12.75 MiB = 25.70 GiB == target_cache` **exactly** (`l3-a0-hot0.log:10`). There is **no slack inside
   target_cache** to grow slots into; the only slack is 179.6 MiB = 14 places. → option (c1) is empty.
2. **The 35 % vs 68.5 % are different populations.** The fork's counter reads **16,254** store requests
   (`fork-noexperts-r1.log:3338`, `hit_rate=68.543`) = decode only, because its prefill reads bypass the store
   (`read_bytes`, fork `deepseek_v4.c:13726-13775`). The port's 35.0 % reads **30,305** requests
   (`l3-a0-hot0.log:32`) because prefill streamed 11,127 experts *through the store lease*. **The port already has S2:**
   with bypass the same arm reads `expert_requests=17588 hits=9779 hit_rate=55.600` (`s12-byp-1.log:32` vs control
   `s12-ctl-1.log:31` 36.088 %). So the honest, like-for-like gap **at equal capacity and equal population is ≈ 55.6 % →
   68.5 % ≈ +13 pp**, and the remaining gap in the printed number was the denominator.
3. **The port's store policy is already the fork's *better* arm.** The port is pure per-layer LRU + 16 pins/layer. In the
   fork's own matched-capacity A/B (`REVIEW.md:8`, 1,681 slots/20.94 GiB, 50 prompts, fixed binary):
   **adapt 75.0 % / freq 70.3 % / rec 72.8 %** hit (decode 1.20 / 1.09 / 1.08 tok/s; wall 2,058 / 2,112 / 2,249 s).
   `rec` = cutoff 1 = pure recency (`scripts/vk_mfu_mru_bench.py:14-17,209-211`). **Pure recency beats pure frequency
   by 2.5 pp there**; the adaptive MFU/MRU split is worth only **+2.2 pp over rec, +4.7 pp over freq.** A frozen-MFU
   section is therefore *not* worth +33 pp; the fork's own arm set prices the mechanism at ~2 pp and prices
   **capacity + warm seeding** for the rest.

---

## Files Retrieved

**Fork machinery**
1. `fork/c/mfu_table.h` (1-150) — the decode-only popularity authority, O(1) record, 2^31 guard, MFU1 format.
2. `fork/c/mfu_table.c` (67-166) — `mfu_scale_down`, `mfu_save`, `mfu_load` (fork-liftable, zero deps).
3. `fork/c/expert_cache.c` (250-275) — the *only* `mfu_record` caller (UPDATE), + mid-request MRU→MFU re-tag.
4. `fork/c/cache_reorder.c` (229-236, 256-272, 283, 291-320, 322-410) — 11008-row rank, K-th-largest cutoff, label re-tag, GPU delta.
5. `fork/c/gpu_mfu_cache.h` (24-60, 100-160) — dual-residency contract, split-target reorder, promote, boot prefill.
6. `fork/c/gpu_mfu_cache.c` (190-258) — install/demote, the one slab-free site (`:248`).
7. `fork/c/deepseek_v4.c` (10541-10566, 15450-15560, 15637-15645, 15731-15772, 15922-16010, 16020-16130) — count gate, promote ring, mfu save/load, slot-count derivation, CPU warm, boot.
8. `fork/REVIEW.md:5-10, 120-160` + `docs/archive/plans/PLAN_cache_span.md:110-131` — the fork's own A/B evidence.

**Port target**
9. `port/c/deepseek_v4.c` (8440-8500, 8655-8762, 8874-8990, 9215-9229) — slot struct, partition LRU, victim, lookup, slot count.
10. `port/c/deepseek_v4.c` (1371-1406, 1710-1780) — the RAM plan: where 48 and 25.70 GiB come from.
11. `port/c/deepseek_v4.c` (9328-9390, 9407-9430, 9751-9800, 9857-9990, 10000-10030, 10209-10230, 10305-10390, 10430-10510) — pins, packing, victim precedence, merged counting, prewarm, pin_count.
12. `port/c/route_trace.h` (1-60, 100-160, 308-390) — `.coli_usage` format (merged; no decode view).
13. `port/c/vk_tier.c` (50, 983-1035, 2146-2170, 2255-2270, 2803-2812, 2838-2860, 2965-2990, 3125-3150) — decode counters, hot-set overlay (L3), staging carve, host pool.
14. `port/c/deepseek_v4.c` (13700-13720, 13840-13870, 14010-14060) — the phase seam (`v4_vk_token_issue` vs `v4_vk_batch_issue`), bypass stage pool, tier wiring.
15. Evidence: `bench/up2276/{fork-noexperts-r1,l3-a0-hot0,s12-ctl-1,s12-byp-1}.log`, `bench/up2276/run-arm2276.sh`, `docs/HANDOVER-2026-10-23.md:25-45`, `docs/research/R-l1-byte-economy-map-2026-10-23.md`.

---

## 1. Fork machinery — mfu_table (decode-only counting)

**Where counts increment, exactly one place.** `mfu_record` (`mfu_table.h:120-131`) is called **only** from
`expert_cache_update` (`expert_cache.c:258`), whose engine caller is gated on the token count
(`deepseek_v4.c:10541-10566`): `if (!result && count) { … expert_cache_update(v5, routed, n_routed); }` with
`/ §10: spec/draft rounds (count==1) count every ROUTED selection … Prefill (count==0) NEVER counts. */` — one record per
(token, rank), the **distinct-union classify is not the counting unit**. Boot prefill never counts
(`gpu_mfu_boot_prefill` doc, `gpu_mfu_cache.h:196-205`); PILOT/prefetch never counts (they call `miss_pilot_*`, not UPDATE).

**The O(1) record** — flat `uint32 counts[43*256]` (44 KB, L1-resident), index `layer*256+expert`; a rare `if` for the
2^31 high-water, then `total_accesses++`, then `delta_counts[idx]++` (the per-request decomposition, lockstep so
"rank_score == live count" survives every shift):

```c
static inline void mfu_record(MfuTable *m, int layer, int expert) {
    size_t idx = (size_t)layer * MFU_EXPERTS_PER_LAYER + (size_t)expert;
    uint32_t *c = &m->counts[idx];
    if (*c < MFU_OVERFLOW_HIGHWATER) { *c += 1; m->total_accesses += 1; }
    else { mfu_scale_down(m); *c = 1; m->total_accesses += 1; }   /* ~µs, 11008 entries */
    m->delta_counts[idx] += 1;
}
```
**2^31 halving:** `MFU_OVERFLOW_HIGHWATER (1u<<31)` (`mfu_table.h:66-68`); `mfu_scale_down` (`mfu_table.c:67-79`) shifts
counts AND deltas by `max(decay_shift,1)` — the overflow guard never no-ops (UINT32 wrap protection is a correctness
invariant, not recency) and bumps `overflow_shift` cumulatively.

**Persistence — its own file, not merged into usage.** Magic `"MFU1"` + version + `overflow_shift` + `total_accesses` +
44032 B counts (`mfu_table.h:91-95`), written tmp+rename (`mfu_table.c:89-119`), validated-and-atomic load
(`mfu_table.c:121-166`: parse into locals, apply `>>decay_shift`, leave the caller's zeroed table on any failure).
Path `<model>/.coli_mfu` built in `v4_cache_engine_create` (`deepseek_v4.c:15819-15825`); **saved only at exit and only
if dirty** (`v4_cache_slot_save_if_dirty`, `:15637-15645`); loaded at boot in `expert_cache_boot` (`expert_cache.c:90-95`)
→ `gpu_mfu_boot_prefill`. **Load decay default 0** (`MFU_DECAY_SHIFT_DEFAULT 0u`, `mfu_table.h:87`; history 4→2→0 at
`:63-84`): the persisted counts ARE the next boot's warm-fill seed for the GPU fill-to-free **and** the CPU pool warm;
÷4 truncated 3713→1141 and starved a 2449-slot warm.

**The ranking / cutoff.** `cache_reorder.c:229-236` sorts all 11,008 rows by `rank_score` (= live count) desc, ties by
smaller `(layer,expert)`; the cutoff is the **K-th largest value** `rows[k_eff-1].rank_score` (`:283`). `K_base` = env
`COLI_DSV4_VK_MFU_CUTOFF` or AUTO `num_slots/2 + gpu_capacity` clamped to [1, 256*layers-ish → 11008] (`:256-272`), then
the §9 controller moves it by at most `SPLIT_STEP` % of the pool per request inside a `SPLIT_DEADZONE` band
(`:322-410`). Membership = `count >= cutoff`, applied **label-only** (slab pointers never move): boundary re-tag
`cache_reorder.c:291-320`, mid-request re-tag `expert_cache.c:265-272` (gated on the controller's grow-MFU direction; a
shrink step does **not** demote — no ping-pong, `cache_reorder.c:298-310`).

## 2. Fork arena (v5/v6) — where every number comes from

**All computed, no config constants.**
- **12.8 MiB slab** = `record_bytes + EXPERT_SLOT_O_DIRECT_SLACK (8192)` (`deepseek_v4.c:15731-15732`;
  `expert_slot_pool.h:42-46`). Not the 15 MiB device footprint.
- **1982 slots** = `(target_expert_cache_bytes − RAM margin 1.0 GiB) / slab` — `budget −= margin` when
  `budget > 2*margin` (`deepseek_v4.c:15760-15772`), then `expert_slot_pool_count_from_budget`
  (`expert_slot_pool.h:96-100`: floor(budget/slab), clamp [1, 11008]). 1982 × 12.8 MiB = **24.69 GiB arena**
  (`fork-full-r3.log:18`), i.e. target_cache 25.70 − 1.0 GiB margin.
- **gpu_cap 954** = `v4_gpu_mfu_target(free_mb, reserve_gb, 11008) = (free − reserve·1024)/V4_EXPERT_MIRROR_MIB`
  (`deepseek_v4.c:15705-15716`), from a **PRE-DENSE** probe at create (`:15752-15760`): 954×15 MiB = 14.3 GiB ⇒
  free ≈ 16.1 GiB before the 6.3 GiB dense upload. Reserve is re-derived at every decision
  (`v4_cache_reserve_effective`, `:15671-15691` = max(env 1.0, admission need + 512 MiB, bank? 2.8)).
- **Frozen MFU membership** = `count >= cutoff`, emergent count (a global threshold, not per-layer K).
- **MRU tail split**: `n_mru = n * COLI_DSV4_VK_MRU_GPU_SHARE / 100` (default **25**, clamped 0-90),
  `n_mfu = n − n_mru` (`cache_reorder.c:265-271`, env `:111-121`); rows `[0,n_mfu)` = MFU section, `[n_mfu, n)` = MRU
  section, `GpuMfuEntry.mru` tags the section (`gpu_mfu_cache.h:86-100`).
- **Promote ring** (v6): after `expert_cache_update`, CPU-tier hits not yet in VRAM are enqueued, decode/draft only
  (`deepseek_v4.c:9690-9696`), then drained **≤ `COLI_DSV4_VK_PROMOTE_PER_TOKEN` (default 2) per layer** at layer
  quiescence, **append-only** (`gpu_mfu_promote`, `gpu_mfu_cache.h:225-241`; ring+drain `deepseek_v4.c:15450-15560`;
  byte cap `COLI_DSV4_VK_PROMOTE_MB_LAYER`). Never demotes/compacts/reallocs mid-request — the lease-free handle contract.
- **Warm-boot discipline**: boot is **deferred post-dense** (`coli_v4_engine_boot`, `deepseek_v4.c:16020-16040`) so the
  free-VRAM probe sees the decode steady state; then `mfu_load` → GPU fill-to-free → **`v5_cpu_pool_warm` fills every FREE
  pool slab from `.coli_mfu`** (`:15922-16010`), skipping GPU-resident keys only pre-v6 (v6 dual-residencies on purpose),
  and **re-stamps LRU age in rank order** (`:15990-16000`) because the rank-ordered fill makes popularity == *smallest*
  `last_access`, so every recency policy would otherwise evict the hottest warm entries first (measured: `pool=0 disk=283`
  at layer 0 with a fully warm pool).

**What makes it 68.5 % vs plain LRU — ranked with the fork's own A/B** (all at matched capacity, `REVIEW.md:8`,
`PLAN_cache_span.md:118-131`):

| contribution | fork's measured value | evidence |
|---|---|---|
| **capacity + full warm seed** (24.69 GiB arena filled from `.coli_mfu` before the first token; the CPU warm read 1,179 experts in 12.0 s) | the enabling half — a frozen set that is empty at t=0 buys nothing in a 64-token run | `REVIEW.md:156-160` ("pool warm … the pool is the durable tier"), `:157` (boot order table) |
| **adaptive MFU/MRU split + controller** | **+2.2 pp** hit over pure recency, **+4.7 pp** over pure frequency; +10 % decode tok/s over freq | `REVIEW.md:8` (adapt 75.0 / rec 72.8 / freq 70.3) |
| **mid-request promote ring** (v6) | +4.3 % decode tok/s, +6.4 % turn-2+ | `PLAN_cache_span.md:118-124` |
| dual residency (no shed cycle; RAM-first installs) | removes the per-cycle ~3 GB disk re-read; decode +4.3 % | `REVIEW.md:126-131, 156-160` |
| frozen-MFU *membership itself*, at fixed capacity | **not separately measurable positive** — "rec" (pure recency) beat "freq" by 2.5 pp | `REVIEW.md:8` |

## 3. Dual residency in the fork

`gpu_mfu_cache.h:33-49`: **the RAM pool slot is the authoritative copy**; a VRAM entry is a promotion overlay; a demote is
**DROP-ONLY** (free the 3 handles, the pool slab stays warm — there is no device→host download primitive); staging slabs
are never retained. `gpu_mfu_cache.c:87` "the caller keeps the RAM copy (dual residency: the pool slab is untouched)".
**The single place a RAM slab is freed for a device expert** is `gpu_mfu_cache.c:248` on a *successful install* of a row
that carried an offered `source_slab` — and that slab is the **reorder's own staging** (`cache_reorder.c:1205-1240`
allocates it, then frees it after the delta), **never the pool's slab**. Same at the skip paths `:206, 217, 241, 254`
(all "free the offered staging; the expert stays CPU-resident"). ⇒ The fork has **no** path that gives up a pool slot to a
device copy. (The port *does*: `coli_v4_expert_store_ram_first` / `ram_gave`, `deepseek_v4.c:8780-8798, 9921-9975, 14052`,
`exclusive: N RAM copies of device experts given up first` in every tier report — measured **0** in a0.)

---

## 4. The port target — the engine store, precisely

**The lookup / get_record / victim path** (`deepseek_v4.c:8874-8990`):
```
get_record                       : 8874-8885 (record table, no lock)
state->stats.requests++          : 8887
indexed_expert_slot → hits++     : 8889-8890
slot = next_empty_slot(layer)    : 8894     (8704-8709: allocated_per_layer cursor)
       ?: oldest_unreferenced_slot(layer) : 8895  (8740-8762: layer's intrusive LRU head→tail,
                                                  first unreferenced; ram_first/hot_ram_first
                                                  preference at 8718-8738)
malloc slab + mark_slot_allocated: 8902-8910 + 8710-8717
unindex → disk read INLINE under state->mutex : 8912-8968 (coli_st_read_at_streaming_rep)
slot->expert/index/misses        : 8969-8973
slot->references++; used=++clock; touch_lru_slot : 8977-8979
```
`slot_by_expert[]` is the O(1) index (`:8779-8798`); partitions are **physical, per layer**
(`layer_slots = slots + layer*slots_per_layer`, `:8655-8660`); prefill may borrow other layers' *empty* slots only
(`next_pooled_empty_slot`, `:8719-8729`, gated on `pool_layer >= 0`, `:10189-10196`).

**Where 48 and 25.70 GiB come from — the RAM plan, not env.**
`coli_v4_resource_plan_compute` (`:1346-1406`): `per_slot = sparse_layers(43) × expert_record_bytes × routed_topk(6)`,
`minimum_expert_bytes = per_slot` (one "topk-per-layer" unit), `slots = usable / per_slot` clamped to [topk, 256] ⇒
`slots_per_layer = topk × slots` semantics. Then `coli_v4_expert_store_open_planned` (`:1710-1780`):
```
per_slot      = plan.expert_cache_bytes / plan.slots_per_layer      (== 43 * record_bytes = 548 MiB)
cache_limit   = planner_available − fixed − dense_in_RAM − head_bytes
slots         = cache_limit / per_slot                              (== experts PER LAYER)
              clamp ≤ plan.slots_per_layer, floor 6
COLI_V4_EXPERT_SLOTS=n overrides down (test knob, :1773-1776)
expert_cache_bytes = slots * per_slot ; runtime->target_expert_cache_bytes
```
Store open then **re-derives** it: `slots_per_layer = cache_bytes / (layers × record_bytes)` (`:9215-9216`), floor 6
(`:9219-9227`), cap 256 (`:9228-9229`). **Nothing else pins the count** — no env, no config constant; `resource_plan.py`
is the setup-side estimator and is not the runtime path (OPEN: confirm it is only a doctor/planner mirror).
Measured boot: `ram_tiers available=28.00GiB dense=device(6.02GiB on the device, 0.25GiB in RAM) target_slots=48
target_cache=25.70GiB head=resident-bf16 projected=27.82GiB` (`l3-a0-hot0.log:10`) ⇒ **48 × 43 × 12.75 MiB = 25.70 GiB,
spare 179.6 MiB**. Slack outside target_cache: dense-in-RAM 0.25 GiB, resident bf16 head 1.06 GiB, host pool 165 MiB.

**What pins a slot — the rows16 pin cache.** `COLI_V4_MAX_PIN_SLOTS_PER_LAYER = 16` (`c/Makefile.deepseek-v4:55,98,109`),
`maximum_pins = min(slots_per_layer − 6, 16)` (`deepseek_v4.c:10451-10464`), `pin_count` fixed at open (`:10466-10484`),
pins derived from the **merged** history (`hot_repin_locked`, `:9857-9885`, every `repin_interval = 6` layer requests),
`hot_is_pinned` (`:9407-9430`). Pins are exempt from **all three** victim selectors — `oldest_unreferenced_slot`
`:8740-8762` (base store), `hot_oldest_victim_locked` `:9886-9918`, `hot_oldest_pool_victim` `:9921-9975` (which relaxes
reserve → pins → last-resort only when correctness demands). Only pinned slots are packed to rows16
(`hot_pack_slot_locked`, `:9751-9785`, gated by `hot_is_pinned` at `:10029`; `v4_rows16 packed_slots=953`).

**`.coli_usage` — merged, no decode view.** `route_trace.h:23-45` (text, `"<layer> <expert> <count>"`, header records
`-1 n_layers n_experts` / `-2 version engine_id`). Counts are **all-request**: `rt_count` at `lookup_hot:10004`
(prefill leases included) and at `coli_v4_expert_store_note_routed:10221` (device-served routings, any phase).
`rt_counts_all()` / `coli_v4_expert_store_history` (`:10229`) is the merged table the tier's warm start and hot overlay
read (`vk_tier.c:1008, 2806`). **There is no decode-only counter and no decode-only view — it must be added** (the
tier's `T.d_routed/T.d_served` at `vk_tier.c:2156,2265,3137,3144` count *device-served routed experts in steps of
≤ VKT_UP_ROWS=8 rows*, not store hits; `:2976-2980` prints them). The store's own counters (`stats.requests/hits`) are
phase-blind.

**The phase seam already exists** (the minimal place to count decode-only): `v4_vk_token_issue` (`:5488-5516`, batch 1 =
decode; both `tier->routed` calls are inside `if (taken[k])`) vs `v4_vk_batch_issue` (`:6375-6399`, `batch × topk` =
prefill union). Both funnel into `v4_vkt_routed(key)` → `coli_v4_expert_store_note_routed(store, key)` (`:13709,
10209-10230`). Adding a `decode` argument costs 2 call sites + 1 prototype (`deepseek_v4_internal.h:773`).

**What the store already takes from the fork's playbook:** prewarm fills *every* slot from the merged history per layer
(`:10305-10390`, `COLI_V4_PREWARM`; on in serve at `:10486-10500`, **off in every bench arm** —
`run-arm2276.sh:60 COLI_V4_PREWARM=0`, so the bench baseline runs a **cold store**); and the L3 hot overlay on the *tier*
(`vk_tier.c:983-1035`, `COLI_VK_TIER_HOT`) which was **replicated ×3 = noise** (`HANDOVER-2026-10-23.md:29`) because
`evictions: 0` — placement is not the cost when nothing evicts.

---

## 5. THE DESIGN (minimal, upstreamable)

### 5a. Frozen MFU section on the store — reuse the pin machinery (≈ 60-90 LOC)

`hot_pins` is *already* a frozen, victim-exempt, history-derived, per-layer set that also gates rows16 packing. So:

1. In `V4HotPolicy` add `uint32_t *mfu_ref` (the decode-only table, 11008 × u32 = 44 KB) and a
   `int frozen_count` (the per-layer K).
2. `hot_freeze_locked(policy, state, layer)` — new, mirrors `hot_repin_locked` (`:9857-9885`) but ranks each layer's 256
   experts by **`mfu_ref`** and writes the top-K into `policy->pins[layer*pin_count …]`, K =
   `clamp(COLI_V4_FROZEN_PCT × slots_per_layer / 100, 0, slots_per_layer − 6)`.
3. Call it where `hot_repin_locked` is called (`:10017` decode, `:10224` note_routed, `:10502` boot seed) — same
   cadence, same mutex discipline. **No victim-path change at all**: exemption is already implemented at `:8741-8762`,
   `:9904-9910`, `:9946-9960`.
4. `COLI_V4_FROZEN_PCT` (default 0 = today's exact behaviour; 100 = the fork's ratio 1982/1982, which for the port is
   `pin_count = min(48−6, 16) == 16` — **so the pin cap must be lifted for this** (`COLI_V4_MAX_PIN_SLOTS_PER_LAYER` or
   a separate `frozen_count`), otherwise the frozen set tops out at 16/layer = 53.8 % ceiling (see §5d arithmetic).

This is the *whole* policy port: **no new victim selector, no new data structure on the store, no reorder pass.**

### 5b. Decode-only counting (≈ 300 LOC, 90 % of it verbatim from the fork)

- Lift `c/mfu_table.c` + `mfu_table.h` **as-is** (297 LOC, zero deps — no engine types, no backend, `getenv` only for
  the decay knob). It is already the exact answer: O(1) record, 2^31 halving, tmp+rename persistence, atomic load.
- Record at the two seams in `v4_vk_token_issue`/`v4_vk_batch_issue` (`:5489-5514`, `:6388-6396`): `decode=1` only for
  the token path (and MTP/spec drafts, which run the same S=1 path); **prefill = never**. Keep `rt_count`/`note_routed`
  exactly as-is so `.coli_usage` and the existing pins/prewarm/hot-overlay semantics do not change.
- Persist as `<model>/.coli_mfu` (the fork's path and format ⇒ the fork's file is directly readable; the A/B rig already
  copies `bench/coli_mfu.fixed`).
- Add the **decode-only hit counter** the verdict needs: `stats.hits_decode/requests_decode` in the store (set a
  `state->decode_phase` flag at the same two seams), printed as `hit_rate_d=` on the `v4_tokens` line. ~30 LOC.
  *This is the counter the whole falsification plan is pre-registered on.*

### 5c. Extra slots — the honest options, with arithmetic

`target_cache` is exactly spent (premise #1). Every extra place must come from outside it:

| option | places gained | % capacity | Δ ceiling (from §5d curve) | LOC | verdict |
|---|---:|---:|---:|---:|---|
| **reclaim the store's RAM twins of device-resident experts** (the port's `ram_first/ram_gave` already exists; make it a *proactive boundary reclaim*, not a victim preference) | **273** (measured `resident 273`, `s12-byp-1.log:41`) | **+13.2 %** (48 → 54.4/layer) | 80.8 → ~82.9 % = **+2.1 pp** | 60-100 | **2nd** |
| grow slots inside target_cache | 0 | 0 | 0 | — | **impossible** (premise #1) |
| merge the tier host pool into the store (the split-brain) | **11** (165.0 MiB, `host pool: resident 11`, 179.6 MiB spare) | +0.5 % | ~+0.1 pp | 150-250 | **reject** — 11 of 11,008 places, and it is host RAM read over PCIe (`vk_tier.c:2543-2580`) |
| stream the bf16 head instead of resident | +83 | +4.0 % | +0.8 pp | 200+ | reject — costs a head read per token |
| shrink dense-in-RAM (0.25 GiB already device-resident) | +20 | +1.0 % | +0.2 pp | — | reject |

**The reclaim's real cost:** a reclaimed expert's only copy is the device's. The tier's own mechanisms that need the RAM
copy are (i) `v4_vkt_note`'s rows16 unpack path (needs the view → would become a disk read), (ii) a device-eviction or
`gpu_mfu`-style shed re-fills from RAM (the tier's `evictions` are 0 in the measured arms, but the *serve admission's*
shed does exist upstream), (iii) the warm-start source. So the reclaim must be limited to experts the tier reports
`resident`/`dev` **and** re-armed as "re-read on demand" — this is exactly the fork's `D6 download` problem in reverse,
and it is the reason the fork never does it. Rank it second for that reason.

**Ranking by hit-rate-per-LOC:** (1) 5a frozen section **+** 5c-seed — the *seed* is not optional (see below);
(2) 5b counter (0 pp but it is the metric and the ranking input); (3) device-twin reclaim (+2.1 pp); (4) everything
else ≈ 0. **The seed is the load-bearing half:** a frozen set that is empty at t=0 gains nothing in a 64-token run.
Either turn `COLI_V4_PREWARM=1` on in every arm and rank the prewarm by `mfu_ref` instead of the merged `policy->usage`
(`:10349-10360`, a 5-line change), or add a `v5_cpu_pool_warm`-style pass (fork `:15922-16010`, incl. the LRU-age
re-stamp at `:15990-16000` — **required**, or the prefill's oldest-MRU release eats the hottest seeds; that exact bug was
measured in the fork).

### 5d. The arithmetic that bounds the whole design (the numbers to argue with)

Static coverage of the given history `bench/coli_mfu.fixed` (MFU1, `total=1560384`, 9,553 nonzero of 11,008), per-layer
top-K mass — i.e. the **hit-rate ceiling of a perfectly-frozen set at the port's exact capacity**:

| K per layer | places | coverage of selections |
|---:|---:|---:|
| 6 | 258 | 31.7 % |
| **16** (= today's pin cap) | 688 | **53.8 %** |
| 32 | 1,376 | 71.0 % |
| **48** (= the port's slots/layer) | 2,064 | **80.8 %** |
| 64 | 2,752 | 87.1 % |

Against the measured store: control 36.1 % (`s12-ctl-1.log:31`), **S2 bypass 55.6 %** (`s12-byp-1.log:32`), fork 68.5 %
(`fork-noexperts-r1.log:3338`). ⇒ **the frozen ceiling at 48/layer is 80.8 %, i.e. ~+25 pp of headroom over the current
store and ~+12 pp over the fork**, and +2.1 pp more with the device-twin reclaim. The fork's own arm set says the
*mechanism* (frozen vs recency) is worth ~2 pp of that and the rest is capacity + seeding — so pre-register a gain of
**+8 to +15 pp**, not +25.

**Decode tok/s is not hit-rate-bound — state this up front.** Decode misses/token at h = 0.556:
`16254 × (1−0.556) / 63 ≈ 115` reads × 12.75 MiB ≈ 1.43 GiB/token; the fork's measured per-read cost is **8.9 ms**
(`REVIEW.md:200` G14) ⇒ ≤ 1.03 s/token unhidden, and the measured decode wall is `63/decode_tps` ≈ 1.75 s/token while
the arm's whole `CPU share` is **63.4 s** (`l3-a0-hot0.log:42`, ≈ 1.0 s/token of CPU expert compute). Going 0.556 → 0.80
removes 63 misses/token ⇒ **≤ +19 % decode (0.57 → ≤ 0.68), ≥ 0 % if fully overlapped**. Reaching the fork's 1.16 tok/s
needs the device-side decode share (port **13.7 %**, `s12-byp-1.log:41` `decode: 2220 of 16254`) and the lanes/ring —
**not this lever**. Say so in the plan, or the test will be read as a failure of a correct implementation.

---

## 6. Falsification plan (pre-registered)

**Method** (the campaign's, `bench/up2276/run-arm2276.sh` + the *replicated ×3 interleaved* discipline that killed the
"-26 s mirage"): 2,515-token prompt / 64 generated, `--memory-gb 28`, `COLI_VK_PROFILE=RDNA2` (+ `STREAM_BYPASS=1` in
every arm), `VRAM_MAX_USED_MB=2600` prefix for desktop-present, same `.coli_usage` **and** `.coli_mfu` snapshots before
every run, arms interleaved, ~5.5 min/run + warm.

**Primary metric (pre-registered, must be added by 5b): `hit_rate_d` = decode-only store hits / decode-only store
requests, printed on the `v4_tokens` line.**
- Baseline to beat: control `hit_rate_d` (expected ≈ 0.57-0.60, derived from 55.6 % over 17,588 req with ~1.3 k residual
  prefill/pin lookups; **must be measured, not assumed** — that measurement is the point).
- **Pass:** `hit_rate_d ≥ 0.68` (fork parity at equal-and-slightly-larger capacity).
- **Marginal:** 0.62-0.68.
- **Fail / abandon the lever:** < 0.62, i.e. the frozen section did not move the number.

**Secondary (report, do not gate):** decode tok/s. Control band today **0.570 / 0.574** (`HANDOVER:31`), record 0.670;
pre-register **≥ +8 %** (≥ 0.62) as the useful bar, with the ≤ +19 % mechanism bound from §5d.

**Guards (hard):** TTFT within the S1+S2 band (148 ± 5 s) and **no > 3 % regression**; generated text byte-identical
(all arm logs already carry it); `deepseek-v4-tiny-check` green; `packed_slots` must not collapse (953 today, a frozen
set should *raise* it).

**Arms — 4 × 3 reps = 12 runs, interleaved (~80 min):**
| arm | config | what it isolates |
|---|---|---|
| **C** | today's store, `PREWARM=0` | control |
| **P** | `PREWARM=1` seeded from `.coli_mfu` (frozen pct 0) | **seeding alone** — the fork's biggest contribution |
| **F32** | frozen 32/layer + MRU tail, seeded | frozen section with recency left alive (the fork's split) |
| **F48** | frozen 48/layer (=100 %, no MRU tail), seeded | the static ceiling (80.8 %) |
| (+ optional) **X** | F48 + device-twin reclaim | the extra-slots leg (+2.1 pp) |

**Pre-registered decision rule (write it down before running):**
- `F − P < 0.02` ⇒ the *policy* is worthless beyond seeding → **ship P only**, drop the frozen section (this is what the
  fork's own adapt-vs-rec arm predicts: +2.2 pp).
- `P − C < 0.02` **and** `F − P < 0.02` ⇒ the hit-rate lever is dead at this operating point → stop, the decode gap
  belongs to bytes/stall + lanes (Option-B / fork's `moe_lanes`).
- `F48 − F32 ≥ 0.03` ⇒ the fork's 25 % MRU tail is not needed in the port (the store's LRU tail already provides it).
- Decode tok/s moving < +3 % even when `hit_rate_d` clears 0.68 ⇒ the hit rate is not the decode lever; publish that as
  the result and stop spending on it.

## 7. Size + risks

| item | LOC | files | risk |
|---|---:|---|---|
| 5b `mfu_table.{c,h}` lift | 297 (verbatim) + ~20 (call sites) | `c/mfu_table.*`, `deepseek_v4.c:5489,6391`, `deepseek_v4_internal.h:773` | low (zero deps) |
| 5b decode-only hit counter | ~30-40 | `deepseek_v4.c` store stats + `v4_tokens` line | low |
| 5a frozen section (reuse pins) + K knob + pin-cap lift | 60-90 | `deepseek_v4.c` (policy, `hot_repin_locked` neighbour, `:10451-10464`) | low-med (starves the pool's borrow path if 100 %) |
| 5c seed (rank the prewarm by `mfu_ref` + LRU re-stamp) | 30-50 | `deepseek_v4.c:10305-10390` | med (adds ~25.7 GiB of boot reads ≈ 13 s at 2 GB/s — must be in *both* arms' wall) |
| 5c device-twin reclaim | 60-100 | `deepseek_v4.c` (boundary hook), `vk_tier.*` (`resident()` already exported) | med (`v4_vkt_note`/join-failure path loses its cheap source) |
| tests | 120-200 | `c/tests` (phase counting, per-layer K, victim exemption, persistence round-trip) | — |

**≈ 500-700 LOC, no shaders, no `vk_chain.c`/`deepseek_v4_chain.h` touch** — upstreamable as two independent slices:
"the store counts decode selections separately and can freeze a share of its slots" and (separately) "…and reseeds from
that history at boot".

**Risks / OPENs**
- **R1 (attribution, the big one).** The 68.5 % figure is a *decode-only* counter in an arm whose prefill never touched
  the store. Any comparison that does not first add `hit_rate_d` repeats the 35 %-vs-68.5 % error. Mitigation: 5b is
  arm-blocking, not optional.
- **R2 (decode tok/s will move less than the hit rate).** §5d arithmetic: the CPU expert share (≈ 1.0 s/token) dominates.
  A green `hit_rate_d` with a flat tok/s is the *expected* outcome, not a bug — pre-register it as such.
- **R3 (pin starvation).** A 100 % frozen store removes the pool's cross-layer borrow (`next_pooled_empty_slot`) and the
  `pool_reserve_per_layer = 6` decode reserve (`:9219`). Post-S2 prefill bypasses the store, so measured risk is low, but
  the 6-slot reserve must stay: cap K at `slots_per_layer − 6`.
- **R4 (numerics).** Residency-only changes are byte-identical (same expert bytes, same device form). The seed is the
  exception to watch only if the extra boot traffic shifts `bw_up` → the tier's `R` → which experts stream
  (`vk_tier.c:1120-1134`): **log `R` in every arm** or the arms are not comparable.
- **R5 (RAM).** The design adds 44 KB (table) + 0 RAM for slots; the seed adds no RAM, only boot reads. The 179.6 MiB
  spare stays intact.
- **OPEN-1** `resource_plan.py` — confirm it is setup/doctor-only and never the runtime path (the runtime path is
  `coli_v4_resource_plan_compute`).
- **OPEN-2** The port's *actual* decode-only `hit_rate_d` (must be measured; the 0.556-derived 0.57-0.60 is inference
  from `s12-byp-1.log:32,41`).
- **OPEN-3** Whether the port's LRU tail already supplies what the fork's MRU section buys (arm `F48` vs `F32`).
- **OPEN-4** `bench/coli_mfu.fixed` is a *fork-produced* history; a production port must generate its own (identical
  format, so one file serves both — but the A/B rig must state which).
- **OPEN-5** The L3 tier-side overlay measured neutral at `evictions: 0`; the store-side version must be re-justified on
  the store's own eviction rate (which post-S2 is unknown — instrument it with `hit_rate_d`).

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Read-only design map written to the required path: fork mfu_table/gpu_mfu_cache/cache_reorder/expert_cache and the port store (lookup/victims/slot-count/pins/.coli_usage) all cited file:line, the three falsified premises quantified from bench logs, the design (frozen section + decode-only counting + extra slots) ranked by measured hit-rate-per-LOC arithmetic, and a pre-registered replicated-x3 falsification plan with pass/fail/reject rules; open questions marked OPEN-1..5."
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "grep/sed over fork and port trees (mfu_table.*, gpu_mfu_cache.*, cache_reorder.c, expert_cache.*, expert_slot_pool.*, deepseek_v4.c, vk_tier.c, route_trace.h, Makefile.deepseek-v4)",
      "result": "passed",
      "summary": "all cited line ranges verified in-tree"
    },
    {
      "command": "grep -ho 'decode: ...' bench/up2276/*.log; grep hit_rate bench/up2276/*.log",
      "result": "passed",
      "summary": "port decode device share 13.2-14.0%; store hit rates control 36.1% / bypass 55.6% / fork 68.5% (16,254 req)"
    },
    {
      "command": "python3 analysis of bench/coli_mfu.fixed (MFU1, total=1560384, 9553 nonzero) -> per-layer top-K coverage",
      "result": "passed",
      "summary": "top-16/layer 53.8%, top-32 71.0%, top-48 80.8%, top-64 87.1% at 2,064 places"
    }
  ],
  "validationOutput": [
    "target_cache arithmetic closes exactly: 48 slots/layer * 43 layers * 12.75 MiB record = 25.70 GiB == target_cache (l3-a0-hot0.log:10); the 15.0 MiB figure is the device mirror footprint (V4_EXPERT_MIRROR_MIB).",
    "Frozen-set ceiling at the port's exact capacity = 80.8% of selections (static, history-matched); current store 55.6% post-S2, fork 68.5%.",
    "Decode-tok/s bound: 115 misses/token * 8.9 ms/read <= 1.03 s/token vs 1.75 s/token wall and ~1.0 s/token CPU share => hitting 0.80 buys <= +19% decode, not 1.16 tok/s."
  ],
  "residualRisks": [
    "The port's true decode-only store hit rate is inferred (55.6% over 17,588 requests, ~13.7% of decode served on device), not measured; a decode-only counter is a prerequisite for the verdict (OPEN-2).",
    "The 68.5% fork figure is a decode-only counter from an arm whose prefill bypassed the store - any comparison without the new counter repeats the population error (R1).",
    "Decode tok/s is dominated by CPU expert compute (~1.0 s/token), so a correct implementation may still show a flat tok/s; pre-registered as expected (R2).",
    "A 100% frozen store removes the pool's cross-layer slab borrow and eats the 6-slot/layer decode reserve unless K is capped (R3).",
    "bench/coli_mfu.fixed is fork-produced; a production port must generate its own history (OPEN-4)."
  ],
  "noStagedFiles": true,
  "diffSummary": "No code changes (read-only scouting). One file written: the design map at the configured output path.",
  "reviewFindings": [
    "blocker corrected: task premise '48x43x15MiB = 30 GiB vs 25.7 target' is a unit error - the store record is 12.75 MiB and target_cache is fully spent, so 'grow slots within target_cache' is impossible.",
    "blocker corrected: 35% vs 68.5% is a population mismatch (30,305 vs 16,254 requests); post-S2 the port measures 55.6%, so the like-for-like gap is ~13pp.",
    "blocker corrected: the fork's own A/B prices frozen-MFU membership at +2.2pp over pure recency (adapt 75.0 vs rec 72.8), most of its edge being capacity + warm seeding.",
    "no other blockers found in this scouting pass"
  ],
  "manualNotes": "Two things a worker should not have to rediscover: (1) the port's pin machinery (hot_pins, already victim-exempt in all three selectors and already the gate for rows16 packing) IS the frozen section - extending it costs ~60-90 LOC instead of a new victim policy; (2) the seed is the load-bearing half (the fork's v5_cpu_pool_warm + LRU-age re-stamp), and every bench arm runs COLI_V4_PREWARM=0 today, so the baseline is a cold store. Also worth flagging to the orchestrator: the decode tok/s gap (0.555 vs 1.16) is very likely not a hit-rate problem at all - the arithmetic in section 5d bounds this lever at <= +19% and the fork's own lane work (PLAN_moe_lanes, +23%) is the shape that matches the measured gap."
}
```
