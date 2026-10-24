# Z — OB1 S1: the VRAM expert bank + the amdgpu-safe frame split (machinery landed)

**Date:** 2026-10-24 · **Lane:** OB1-S1 (manager-run campaign, `port/ob-s1` from `473fd669`)
**Charter:** `docs/plans`/`OB0-fold-transplant-plan.md` r3 §3 S1 (the frozen fork refs
`d11fba5b`; the port anchors re-verified at `473fd669` — §1 below).
**Scope:** S1's machinery only — carve/tenure/refill, `COLI_VK_DMOE_ROWS_MAX`, gates, docs.
No bench arms (the window is the manager's, after the merge); no S3 reorder.

## 1. Anchor drift at 473fd669 (re-verified, adapted — the plan's were cut at 073a03b6)

| charter anchor @ 073a03b6 | at 473fd669 | drift |
|---|---|---|
| `vk_tier.c:929-955` (POOL_LAYER plan block) | `:955-985` | +26 lines: the 67-commit merge's `ram_later`/heap-cut rework sits between; block shape unchanged |
| `vk_tier.c:865` (promote's pool skip) | `:875` | one line up; the bank's skip added beside it |
| `vk_tier.c:959-970` (hot_pin pins) | `:1089-1110` | S0's prompt-dprof fields grew the struct; the pin block's shape unchanged |
| `vk_tier.c:1179` (`st_alloc`) | `:1285` | unchanged body; the bank's carve is upstream of it (in `vkt_init`'s streaming block) so `st_alloc` needs no edit — it lazily allocates the carved count |
| `vk_tier.c:2768-2837` (sizing) / `:2845-2861` (PIN/POOL env) / `:2877` (`fit = fit_raw − slots`) | `:2857-2934` / `:2936-2957` / `:3071` | the staging carve + host-pool heap work shifted everything down; the slot-clamp arithmetic (`hotpins`, `fit_raw − slots`) is intact and is what the bank's carve composes with |
| `vk_tier.c:1548` (slot reuse) | `:1664` | unchanged (dead on the chain path — R-l1's finding stands) |
| `vk_tier.c:1408` (`issue_big` BC_DEV) | `:1523` | unchanged; S1 computes through it untouched |
| `deepseek_v4.c:6761` (`coli_v4_moe_routed`) | `:6773` | +12 lines (merge); the post-router pre-issue seam resolved to the two tier-issue helpers (`v4_vk_batch_issue` `:6395`, `v4_vk_token_issue` `:5490`) — the ids live there, not in `coli_v4_moe_routed` itself |
| `deepseek_v4.c:14127` (`v4_vkt_load_batch`) | `:14191` | unchanged; the bank's refill reads through `VktConfig.load_batch` = this reader when `COLI_VK_TIER_STREAM_BYPASS` is on |
| `vk_dmoe.h:624-639` (`vkc_dmoe_layer` big branch) | `:705-737` | the L2 staging (`stg` fetch) sits inside the branch now; the split wraps route+fetch+GEMMs per group |
| `vk_chain.c:896-905` (`vkc_layer_recorded`) | `:905-913` | unchanged; the split's `vkc_submit(0)+vkc_begin()` is its pattern |
| `vk_chain.c:2630/:2699/:2710` (`our_fmt`, `vkc_moe_rows_ready`, `vkc_moe_rows`) | `:2678/:2747/:2758` | unchanged shape; `vkc_moe_rows` gained `x_off` support (below) |
| `deepseek_v4_chain.h:683-715` (`v4c_dmoe_arm`) / `:1380-1402` (in-frame branch) | `:683-715` / `:1391-1413` | +8/−3 (S0's role stamps + merge); **no S1 edit needed or made** — checklist item 7 verified by the tiny leg (below) |

## 2. What landed (per the charter's S1 shape, deviations flagged)

**The bank is the tier's own places, not a slab** (the charter's port-native shape):
`COLI_VK_TIER_BANK_LAYER=n` —
- **plan** (`vkt_plan`, beside POOL_LAYER's block, ahead of PIN_LAYER's): layer n's E
  experts queued to place 0, all-or-nothing like the dmoe gate it serves;
- **carve** (`vkt_init`'s streaming block): the slot budget minus the bank's E — never the
  residents' — one boot ledger line (`bank=layer n, E experts (bytes), the stream slots'
  budget a -> b`), and the freed places join the residents even when streaming did not
  survive the carve (all slots became the bank). Declines, one line each, the plan the
  history's: out of range / hash layer / streaming off / no room (slots < E, or the budget
  short of bank+pins+2);
- **tenure**: `hot_pin` pins the banked layer, `promote` skips it, the victim paths skip
  pins as they already do;
- **refill** (`vkt_bank_fill`, the engine seam — `ColiV4VkTier.bank` at the two tier-issue
  helpers, post-router pre-issue): missing = routed ∧ ¬valid ∧ ¬tried ∧ slot free to fill,
  loads through `T.c.load_batch` (the bypass group reader; `.load` fallback), uploads
  sequential via `vkt_put`, `vkt_put_done` lands them and `quiesce` sets the bitmap;
  failures latch `tried` (at-most-once per tenure — the fork's route-aware refill, whose
  point was the CPU union re-reading the same experts ~4–6× a layer);
- **rotation** (`vkt_bank_switch`, the explicit seam): bitmap clear, old layer's device
  copies freed at the quiescent point with epoch publication (promote's victim-free
  discipline), new layer's places queued. Counters `bank_refills/bank_bytes` + the run
  line's `| bank: layer n, V of E valid, refills (bytes), slots a -> b`.

**Deviation D1 (found by the tiny leg, fixed):** the first cut auto-switched the bank at
the fill seam — the port's chunk-outer order visits every layer each chunk, so the bank
thrashed a place a layer (46 refills, gate never open). The charter is explicit
("S1's `BANK_LAYER=n` never switches"; S3 owns the rotation), so the switch moved to an
explicit `vkt_bank_switch` the engine never calls; the fill no-ops for any other layer.
The 2-layer gate case drives the switch through the explicit seam — which is what r2 F6
meant by "the unit seam".

**`COLI_VK_DMOE_ROWS_MAX=R`** (default 0 = today's whole chunk): `vkc_dmoe_layer`'s big
branch splits the chunk's rows into ≤R-row groups, `vkc_submit(0)+vkc_begin()` between
groups; each group routes its own rows (`l_off/i_off/w_off`) and computes them into its
own slice of y (`x_off/i_off/w_off/y_off`). `vkc_moe_rows` gained float-unit `x_off`
support (a bind offset in the gate/up pass — the only pass that reads x). The amdgpu
boundary is documented at the parse (K1's ~2–4 s class; U §2's lost chunk; ~0.1 s a
layer-visit from VRAM ⇒ R≈512 is the ~1 s class). **No `deepseek_v4_chain.h` change** —
the landed arm picks the banked layer up through `vkt_dev_table` (the POOL_LAYER proof,
item 7).

## 3. The unit evidence

- **The 2-layer case (F6)** — `test_vk_tier` "bank layer": the carve's ledger line
  (`12 -> 2` at a 24-expert budget), the armed plan (banked layer's 10 ahead of the
  history's 2, first), the table whole for the gate after the refill (`vkt_dev_table == E`),
  at-most-once (a second fill loads 0), another layer's step a no-op (the S1 invariant),
  the switch both ways: old layer's places freed (0 resident), new layer's missing refilled
  exactly (`g_loads == miss0`), its second fill 0, rows on the reference throughout
  (worst 3.4e-7 class), and both declines (out of range, no room) one line each with the
  plan the lever-free tier's exactly.
- **The ROWS-split unit** — `test_vk_chain` `test_moe_rows_split` (fmt 7, the armed
  path's format): S 40 R 16 (3 groups), S 40 R 7 (6 groups, a remainder), S 7 R 64 (1
  group) — **y bit-identical to the unsplit's** in every case (`memcmp`), the frame count
  one a group. Plus the parse table for the env (0/unset/junk/negative off).
- **The tiny gates with the bank armed** — `deepseek-v4-tiny-check-dmoe` now runs
  `COLI_VK_TIER_BANK_LAYER=1` legs: `bank=layer 1, 4 experts (120.0 KiB), the stream slots'
  budget 64 -> 60` at boot, **8+16+16 layer steps through the dmoe path, all in-frame**
  (the gate opened through the bank's residency — item 7's verification at the engine
  level), `bank: layer 1, 4 of 4 experts valid, 0 refilled` at the turn lines (the warm
  start filled them; nothing to refill at tiny), and the brio leg composes the whole S1
  arm shape (`BANK=1 DMOE=1 ROWS=1 ROWS_MAX=8`) — token-exact on every oracle.

## 4. Gates (final code, the RX 6900 XT rig)

| gate | result |
|---|---|
| `vk-tier-check` | **PASS** (bank case included; host-pairs leg too) |
| `vk-chain-check` | **PASS** (11,966 frames; the three split units bit-identical) |
| `vk-strict-check` | **PASS 3/3** (no flake fired) |
| `deepseek-v4-tiny-check` | **PASS** (63 PASS lines across both tiny targets) |
| `deepseek-v4-tiny-check-dmoe` | **PASS** (incl. the two bank legs + the ROWS_MAX-composed brio leg) |
| `tests/test_v4_serve_framing` | **PASS** (`v4 serve framing baseline: ok`) |
| `cu_tier.c -DCOLI_CUDA -fsyntax-only` | **PASS** (the CUDA double-compile carries the bank: `cut_bank_fill`/`cut_bank_switch` in the rename table) |
| `tests/vulkan_engines.sh deepseek` | **environment-blocked, pre-existing**: fails at the v41 leg (`deepseek_v41 cap=1: no matmul ran on the device`) — proven at the stashed base `473fd669` with the identical signature (the OB0-S0 lane's record, PORT_STATUS Session V) |

## 5. Default-off byte-identity vs the D11 contract (the F7-class control)

`scripts/vk_golden_parity.sh --quick --upstream-ref=073a03b6…` at the final tree, levers
off by `BASE_ENV` construction, `VRAM_MAX_USED_MB=2600`, `vram0 = 541057024 B` before
launch, 188.5 s, leg A **cache HIT** on both passes (sigs `c6bc848a93f3`/`b4764177bde0`
— the D11 fixtures, no re-record), `gpu-inconclusive: 0`:

- **PRIMARY greedy byte-identity: GREEN** — 9/9 on every leg (deploy CPU+GPU, pinned
  CPU+GPU).
- **SECONDARY CPU TF token-exact: GREEN** — 18/18 both configs.
- **GPU-env TF: at the bar** — 18/18 deploy and 18/18 pinned this run (an interim-tree
  run before the D1 fix showed the documented envelope shape instead: pinned 17/18 with
  the pos-7 `51119→2107, logit 27.192` flip, byte-identical to Y's recorded flip — the
  near-tie class, within the D11 §5 band either way).
- tiny gate GREEN 3/3.

Run artifacts: `.golden/run-20261024-162400` (interim) and `.golden/run-20261024-164643`
(final; gitignored per the fork's `.golden` rules — the cache+upstream were copied from
the `up2276-merge` lane's `.golden`, read-only, so this worktree's legs cache-hit).

## 6. What S1's arms will measure (not run here — the bench lane is the manager's)

The machinery prices exactly what the charter's r3 bars expect: at the standing arm the
carve is slot-for-slot (256 slots ≈ 3.75 GiB for the 256-expert layer), the boot line
ledgers it, the engagement counter (device-served routed share) reads from the run line
as before, and the bank's refill is the at-most-once discipline the chunk leg's first
chunk pays. `ROWS_MAX=512` is the frame-split that makes the P1 chunk question runnable
at all on this rig (U §2's lost device). S3's gate is met: the carve/tenure/refill and
the rotation seam are landed, the token-exact tiny leg ran the composed path, and S0's
prefill line is the bar the arms will be read against.

## 7. Residual notes

- The bank's refill uploads through `vkt_put`, which also takes the tier's `T.full`
  host-pool copy when that discipline is on — the fork's bank had pool warming beside it,
  so this matches the fork's shape rather than fighting it.
- `bank_switch` frees the old layer's experts with promote's victim discipline (quiescent
  point + epoch publication); a chain frame that read the table re-reads it at the next
  `vkc_dmoe_upload`, the same contract every promotion keeps — verified by the tiny legs'
  in-frame steps.
- The `hot_hash` decline reads `COLI_VK_TIER_HOT_HASH`'s first layers — the knob the
  hash-router engines already set; the dmoe arm itself refuses hash layers at its own
  parse (deepseek_v4_chain.h's line), so the two agree.
