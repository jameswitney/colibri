# PW-P design note — the fork's always-on prefill bank and the QUEUE_AHEAD/CELL_TAIL submit structure, re-derived for a future lane

Status: **design note only** (the prefill wave's item (e); nothing implemented here). The
levers landed in this wave are the ring-side ones — `COLI_VK_TIER_STREAM_ROWS_ADAPTIVE`
(R floor), `COLI_VK_TIER_STREAM_DEPTH` (read depth), `COLI_VK_TIER_STREAM_GROUP` (fill
groups), `COLI_VK_TIER_STREAM_PRED` (plan coverage). This note names the fork's two
remaining prefill mechanisms and the port seams a future lane would cut, so the next
lane does not have to re-derive them from the fork.

## 1. The prefill bank always-on (fork `0b5eed9a`, G18: the gate 256→1)

The fork's evidence (docs/research/C-perf-evidence.md §2): a GPU prefill expert bank
beats the CPU union at every length (prefill-only −2.2 s @11 tok → −708 s @4093), and
the fork's fix for the 20–256-token band — which its gate had left on the CPU — was not
a new mechanism but a **gate change: 256→1**, the CPU union kept only as the VRAM
refusal fallback. The mechanism is the whole-chunk fused prefill bank: expert-major,
grouped GEMMs, one descriptor cache (B-fork-inventory V6; `eg2_bank_ensure_pool` /
`egm_bank_execute`, fork `backend_vulkan.c:10696`, `:12625`, entries `:13145-13311`).

The port's substrate is already landed, in three pieces:

- **`COLI_VK_TIER_BANK_LAYER`** (S1, `c/vk_tier.c` `bank_switch`/`vkt_bank_fill`): one
  layer's experts resident on the device for a tenure, carved from the stream slots'
  budget (`98fcee51` rule), refilled at most once per tenure through the bypass group
  reader. This is the bank's *residency* half.
- **The rotation seam** `vkt_bank_switch`, waiting on the layer-outer reorder
  (`COLI_VK_CHAIN_ORDER=layer`): the port's engine is chunk-outer, so a bank that
  followed the visit order would thrash a place a layer. The fork is layer-outer, which
  is *why* its bank is always-on — it visits a layer's bank once per chunk boundary, not
  once per token.
- **The compute half** is the tier's ordinary big-step path: a banked layer's routed
  experts are all residents, so `issue_big` runs them as grouped sub-batches with no
  streaming at all — the expert-major shape the fork's bank fuses in one submit.

What a future lane owes for "always-on": (a) the gate arithmetic — the port's equivalent
of 256→1 is arming the bank for *every* main layer (or the hot ones) rather than one
env-named layer, which multiplies the carve by the layer count and needs the rotation
(seam above) to keep one tenure at a time; (b) the VRAM-refusal ladder — the fork keeps
the CPU union as the fallback, the port's is the tier's existing refusal ladder
(`vkt_dev_table` all-or-nothing, the bank decline lines); (c) the numerics bar — the
fork's bank adds an f32-sum drift class (C-perf-evidence.md), so the gate is the
token-exact oracle, as S1's was.

## 2. QUEUE_AHEAD / CELL_TAIL — the one-submit prefill cell

The fork's prefill cell is one submit per cell with the fence **left pending**
(G1-pipeline-gaps.md, anchors at fork `d11fba5b`): the attention segment submits with
its fence pending (`cell_join_commit_nowait`, fork `backend_vulkan.c:6378-6391`), the
mHC tail records into a private command buffer whose **leading barrier** — gated on
`g_tail_seg_pending` — replaces the fence with a queue-order memory dependency
(`:6558-6573`), and the tail close is the ONE wait point (`coli_vk_dsv4_tail_close`,
`:6583-6615`). `COLI_DSV4_VK_QUEUE_AHEAD` default on, prefill-only arming at
`deepseek_v4.c:11141-11148`. Numerics class: identical dispatches in identical order,
barriers replace fences → **bitwise**.

The port's shapes to reuse (no new queue machinery needed for a first cut):

- **The deferred join (T1)**, parked on `port/cs-deferjoin` with its structural
  diagnosis: leaving a sub-batch's fence pending past the join point is exactly the
  queue-ahead idea at the tier's granularity. A prefill lane's first queue-ahead lever
  is reviving that branch against `st_join_half`/`join_big` — the join waits only when
  the rows are actually consumed.
- **The sub-batch halves** (`issue_big`'s `T.hf[0..1]`, `coli_vk_xb_sub_*`) are already
  the cell-tail's double-buffer; what they lack is the *cross-layer* pending fence
  (the engine joins at the MoE block's end, so the queue drains a layer at a time). The
  seam is `vkt_join`'s caller: the engine's settle, not the tier, is where the port's
  queue drains.
- **The uploader's own queue** (`COLI_VK_STAGED`, a transfer queue of its own) already
  overlaps commits with compute — the fill-group lever (`COLI_VK_TIER_STREAM_GROUP`)
  is what keeps that queue fed; a queue-ahead lane composes with it, not instead of it.

Pre-registered falsifiers, as the campaign's style owes: (1) bank always-on — the
token-exact oracle plus the carve ledger (each banked layer's slots must come out of
`COLI_VK_TIER_STREAM_SLOTS`, never the residents'); (2) queue-ahead — bitwise outputs
(barriers-for-fences is the fork's own numerics class) and the fence-wait bucket in the
DPROF window lines going down while `waited` does not grow.
