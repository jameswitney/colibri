# AH — PW-A1: demand-growing decode residency (`COLI_VK_TIER_DECODE_GROW`)

**Date:** 2026-10-25 · **Lane:** pw-a1 (`port/pw-a1`, from `2c57868e`, the PW-D merge). GPU used for
gates only (no bench arms — the window is the manager's). Pre-registered frame (CAMPAIGN.md's parity
wave, the placement census's asymmetry row 6): the port's decode is served by a **fixed** warm-started
tier — `resident 277, evictions 0`, decode device share 13.1–22.5 % — where the fork's decode set
**grows by demand** (252 refill + ~414 decode installs ≈ 8.3 GiB of experts on the card at decode,
toward `gpu_cap=954`, ranked by its MFU table). This slice is that growth as a **policy lever,
default off**, per the house law's D11 contract for residency changes.

## 1. Where the places come from (the budget arithmetic)

The warm start spends the tier's budget exactly (the census's `7.81 of 7.85 GiB`, `evictions 0` —
the S-store map's §5c: every extra place must come from outside `target_cache`). The lever takes its
places from exactly two sources, in order:

1. **Genuinely free VRAM, probed live.** The tier's boot budget could only *guess* what the chain,
   the KV mirror and the head take — at the first decode-class step they have all taken it, so the
   arm probes what the device actually has free (`VK_EXT_memory_budget`, via `coli_vk_mem_budget`)
   less a reserve (`COLI_VK_TIER_DECODE_GROW_RESERVE_GB`, default 0.5 GiB — the KV's growth,
   scratch, the driver) and grows `T.dmax[0]`/`T.budget`/the tier pool limit by that many expert
   places (fmt 15's 12.75 MiB each, AE's basis: ~374 residents at the standing 7.85 GiB budget, so
   every free GiB is ~81 more).
2. **Stream slots retired one at a time, only beyond that.** At a decode step the slots are idle
   staging (big prefill steps alone fill them — X's 183 GiB of cold-expert staging ran through 256
   slots), so their bytes are the room that costs nothing but the next prompt's stream breadth. The
   demand installs retire the live slot end one place at a time (floor of two, `st_alloc`'s least —
   the stream stays alive, narrower), each retire moving the slot's bytes to the residents' budget
   (`dmax[0]++`, pool limit += one expert).

`COLI_VK_TIER_DECODE_GROW_GB` (optional) bounds the whole growth, both sources together. The brief's
traps are the design's ordering: free VRAM **first**, slots only beyond (prefill STAGE pain is paid
only after the free room is gone), and no victim ever gives way — growth only takes free or retired
bytes, so **the warm set stands** (`evictions 0` stays 0; the census's "the set NEVER changes" is
answered by growing *beside* it, not churning it).

## 2. The rank (which experts the growth installs)

The fork's installs ranked by its decode-only MFU table; the port's twin is S7's landed
`.coli_mfu` counting (`b35b076b` — decode-only counts, `hit_rate_d`, never prefill). The engine hands
the tier that table at `vkt_init` (`VktConfig.decode_heat`, `coli_v4_expert_store_mfu_history` — rows
only where the geometry is the fork table's own, 256 experts × ≤43 layers; NULL otherwise and the
growth never arms, one decline line), and the tier keeps its own flat copy.

At the arm, the **cutoff** is the K-th largest decode-only count over the experts the device does not
hold (the fork's `cache_reorder` rule), K = free places + retirable slots (the cap binding both).
Then, per decode-class step (`S ≤ VKT_UP_ROWS` — the same class the report's decode-share line
counts):

- a routed expert **at or above the cutoff** installs into a grown place — free VRAM, or a slot
  retired for it — **never a victim's** (`vkt_note`'s dg branch; the counter is the report's
  `decode grow: N installed by decode-only rank`);
- a routed expert **below the cutoff installs not at all** at that decode step: the grown room is the
  rank's, and an ordinary free-room install (which admits by live heat) would spend it before
  decode's hottest arrive. A cutoff of 0 — more room than the table's nonzero counts, or a cold
  table — admits every demand: the fork's demand installs, room-bounded;
- `promote` (the host-pool path) gets the same rank gate wherever grown room exists, so the
  merged-history warm cannot spend the growth before decode's hot;
- prefill steps are untouched (the growth never takes a note's ordinary free-room install during a
  prompt; the slots it retired are the only prefill cost, paid at the next prompt's breadth).

`vkt_wants` mirrors the gate exactly (the no-side-effects twin the engine's converted-expert check
reads). Two extra layers (an MTP head) are outside the growth (`kind_of(layer)` — main layers only).

## 3. Unit evidence (`tests/test_vk_tier.c` `decode_grow`, RX 6900 XT / RADV)

A 2-layer × 8-expert model, int8: the merged history warms experts 0–2 each layer (counts 100); the
**decode-only** table ranks 4..7 = **40, 30, 20, 10** — ranked differently than the merged history by
construction. Warm start fills the budget exactly (6 of 6).

- **Leg A — free VRAM** (cap 2.5 experts, reserve 10 KiB; no stream, so no slots):
  `decode grow armed: 14.79 GiB free less 1.0 KiB reserve -> 2 places, 0 stream slots beyond,
  budget 6 -> 8 experts, cutoff 40`; the decode sequence routes below-cutoff experts (5/6/7) first
  and often — they never install — and the residents go **6 → 8 (curve 6 6 8 8, monotone), the
  hottest expert (40) of each layer resident, evictions 0**, rows within 1.9e-07 of the reference;
  the report line: `decode grow: 2 installed by decode-only rank (cutoff 40), 0 of the stream
  slots' places (slots 0 -> 0)`.
- **Leg B — the slots beyond** (reserve 99 GiB kills the free part; 6 stream slots; cap 3.5
  experts): a big step a layer first (the slots allocate, the arm sees them — `0 places, 3 stream
  slots beyond, cutoff 30`); then **6 → 9 residents as three installs retire slots 6 → 3** —
  (0,5) and (1,5) at count 30, (1,4) at 40 — the fourth hot expert refused by the cap
  (`!resident(0,4)`), the below-cutoff (6/7) never installed; report: `decode grow: 3 installed by
  decode-only rank (cutoff 30), 3 of the stream slots' places (slots 6 -> 3)`.
- **Leg C — the default** (env unset, same decode sequence): **6 residents, no growth clause** in
  the report — the warm set stands exactly as before.

The engagement print (the run line's own device-share clause now carries the growth): the `[VK] tier`
report's `decode grow:` clause with installs/cutoff/slots, and the one-time arm line with the probe
arithmetic.

## 4. Default off / armed-inert (the D11 contract)

The lever is env-gated (`COLI_VK_TIER_DECODE_GROW`, unset/0 = off) and *geometry-gated* (no
decode-only table ⇒ one decline line, growth stays off). Proofs at tiny:

- **default ×2**: `deepseek-v4-tiny-check` (tiny/prefix/brio harnesses ×2 runs) token-exact against
  the oracle — the unset path runs the standing fixed-set tier;
- **armed**: `COLI_VULKAN=1 COLI_VK_TIER_DECODE_GROW=1` at tiny — the fixture is 4 experts × 3
  layers, not the fork table's geometry, so the engine hands no table and the tier prints
  `[VK] tier deepseek_v4: COLI_VK_TIER_DECODE_GROW: the engine gave no decode-only counts to rank
  by; the growth stays off, the warm set stands` — oracle token-exact (the armed path cannot touch
  a non-fork-geometry model).

The D11 class note stands for the armed path at fork geometry: residency changes can flip near-tie
tokens (greedy channel governs, count-band) — the unit rows here are reference-exact because the
growth installs *add* places without touching any resident's bytes.

## 5. What this lane fixed to finish (the resume)

The prior lane's cut died at the tier-check run. Three defects surfaced when it ran:

1. `dgrow_retire` **double-freed the slot's tensors** — the slot's `ColiVkExpert` owns its three
   tensors (`coli_vk_xb_expert_free` frees them; `vkt_shutdown`'s teardown frees the expert, never
   the tensors beside it); the cut freed both. Crash in the driver's free path, leg B.
2. The **rank gate only gated the dg branch** — a below-cutoff expert's ordinary free-room install
   took a grown place first (leg A's `curve 8 8 8 8`, report `0 installed`, residents 8 by the wrong
   experts). The gate now covers the whole decode-class note path (and `vkt_wants`, and `promote`).
3. The engine's hand-over referenced `MFU_EXPERTS_PER_LAYER`/`MFU_NUM_LAYERS` **outside the store
   unit that owns `mfu_table.h`** — every `COLI_V4_UNIT_*` compile of `deepseek_v4.c` with the Vulkan
   path failed to build (the plain CPU build never compiled `v4_vk_tier_start`). The geometry check
   was already inside `coli_v4_expert_store_mfu_history`; the call site now just calls it. A test
   bug beside it: leg B stepped `layer t` with t = 0,1,2 on a 2-layer model (out of range).

## 6. Gates (all green, run-1 discipline)

vk-tier (both modes: default + host-pairs) · vk-chain (12,039 frames) · vk-strict (run 1) ·
`deepseek-v4-tiny-check` ×2 (the fixture's torch regeneration is not installed on this box — the
shared banked fixture, byte-identical config/ref/tokenizer, was used; the harnesses are the gate) ·
tiny-dmoe (all 8 legs: dmoe tiny/prefix/brio-rows, bank tiny/brio-composed, order tiny/prefix,
fold-brio-composed) · the armed-inert tiny leg · serve-framing · cu_tier syntax
(`cu_tier.c -DCOLI_CUDA -fsyntax-only`). `vulkan_engines.sh deepseek` stays environment-blocked on
this rig (Lavapipe-scoped DSpark assertions, pre-existing at the base).

## 7. Open for the manager (no bench arms here)

- The model-scale growth at fork geometry is the arm's own first-decode print (`decode grow armed:
  <free> free less <reserve> -> <K> places, <slots> stream slots beyond`) — **not measured in this
  lane** (no bench arms). The census's fit lines say the free class at standing is ~1 GiB after
  everything (~81 places at fmt 15) plus the retirable 254 slots; the probe makes the honest number
  at run time, and the cap bounds it.
- The fork's ~6.5 demand installs a token at decode (its uncapped class) will here be bounded by
  `COLI_VK_TIER_PROMOTE`'s per-forward note cap (`promo_cap`, 16 at standing) — the growth changes
  *where* those installs land and *which* experts they take, not the note rate. If the manager wants
  the fork's per-token install class, that cap is the next knob to price at W1/W2.
- The decode-only counts the rank reads are the run's own `.coli_mfu` (seeded by whatever history is
  on disk); a cold table gives cutoff 0 (demand-bounded), a warm one gives the fork's rank.
