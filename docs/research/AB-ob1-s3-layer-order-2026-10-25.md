# AB — OB1 S3: the layer-outer prompt reorder, the Option-B fold's payoff stage (2026-10-25)

**Date:** 2026-10-25 · **Lane:** OB-S3 (manager-run Option-B campaign; machinery + gates only —
the bench arms are a separate window, not run here) · **Tree:** `port/ob-s3` @ 9a138417 + this
commit. **Charter:** `plans/OB0-fold-transplant-plan.md` r3 §3 S3 (r2 F1/F6 binding; the numerics
law of §5 carried verbatim). **Rig:** the parity rig (RX 6900 XT, RADV), used for gates and the
byte-identity control only; `vram0 = 541057024 B` at the idle floor before the parity run and
after it (card2 sysfs).

## 1. Anchor drift (the charter's @073a03b6 seams at this head, before the landing)

S1 landed +782 lines since the plan's 473fd669-adjacent anchors; every S3 seam was re-verified
at 9a138417 before the work, and re-cited at the landed tree after:

| the charter's anchor (plan @ 073a03b6) | at 9a138417 (pre-landing) | at the landed tree |
|---|---|---|
| `deepseek_v4_chain.h:1288` (the chunk loop) | `:1340` | **`:1699`** (`for (int c0 = 0; !done && …)`) |
| `:1323-1363` (the c0==0 host-state lowering) | `:1326-1351` | **`:1735-1760`** (chunk path, untouched) — the layer path's own copy at `:1325-1357` |
| `:1200-1216` (the per-layer prepare/count checks) | `:1206-1222` | **`:1572-1588`** (shared prelude, before the order split) |
| `:1370` (the layer loop) | `:1377` | **`:1735`** |
| `:1389-1397`/`:1409-1416` (the ks copy-backs) | `:1400-1408`/`:1420-1427` | `:1764-1772`/`:1786-1793` (chunk); `:1470-1478`/`:1491-1498` (layer) |
| `:1442-1470` (the end-of-forward pull copy-out) | `:1449-1477` | **`:1814-1846`** (chunk); the layer path's own tail `:1485-1543` (per-layer) and `:1500-1543` (the forward's) |
| `:683-715` (`v4c_dmoe_arm`) | `:685-717` | **`:715-773`** (the `all` form + the mask) |
| `:1266-1276` (the GEMV-vs-chunk-cut comment — the numerics law) | `:1273-1283` | **`:1670-1680`** (unmoved in substance, +20 lines of anchors above it) |
| `:1194-1199` (the 3072-entry decline) | `:1197-1202` | **`:1564-1570`** — **shared prelude, before the order branch: the same lines run under both orders by construction** |
| `:902` (`v4c_chunk_rows`) | `:904` | `:973` |
| `vk_tier.c:1548` (slot reuse — dead on the chunk path) | the slots' block unchanged | unchanged; **the layer path's `vkt_stream_prefetch(i, nr)` per unit makes it live** |
| the fork's switch discipline `deepseek_v4.c:19291-19301` @ d11fba5b | — | the port's landed twin `vkt_bank_switch` (vk_tier.c `:1199`, `bank_switch` `:1154`) — S1's explicit seam, driven here |
| file sizes | chain 1703 / tier 3526 / engine 23544 | chain **2125** / tier 3526 (untouched by S3) / engine 23544 (untouched by S3) |

Drift verdict: **the seams all moved by S1's insertions only** (the dmoe arm block, the tier's
bank block, the DPROF counters); no upstream churn between 473fd669 and 9a138417 touched them
(the Y merge was the last). The engine (`deepseek_v4.c`) and the tier needed **zero** S3 edits —
the fill seam (`tier->bank` at `deepseek_v4.c:5504`/`:6396`) already fires at the host routed
step wherever the bank holds the layer.

## 2. What landed (implementation vs the charter's seams)

**`COLI_VK_CHAIN_ORDER=layer`** (default `chunk` = unset/junk → today's loop, byte-identical by
construction — the chunk loop's body is untouched; only a `!done &&` was added to its head):

- **The reorder** (`v4c_layer_outer`, chain header `:1288-1551`, ~370 lines with its contract
  comment): `for layer { for chunk { … } }`, the unit (one layer, one chunk) running the chunk
  path's layer body verbatim — the same frames, the same per-row GEMV batches, the FFN join of
  the unit before deferred to the next unit's head exactly as the chunk path defers it across
  the layer boundary. The `A2 ∥ host-MoE` overlap and the `vkc_layer_recorded` frame bounding
  (`sent` carried across units) carry over unchanged.
- **The window-rings reservoir** (`ch->xall`): the prompt's streams uploaded once, resident
  across each layer's pass; each unit copies its rows in/out of the chunk's scratch
  (`vkc_copy` D2D, recorded). The reorder needs the chunks' **lists and RoPE tables side by
  side too** — the first cut wrote them once at layer lo and every later layer's unit read the
  *last chunk built* (the bug §4 below); the landed form gives each chunk its own device
  region (`V4cFwd.lbase`/`csW`/`csC`, `VkcDsAttn.l_off`/`VkcDsTopk.l_off` were already
  offset-parameterized — zero shader changes), built and written once at layer lo's unit,
  read by every layer's unit of that chunk.
- **The per-layer bank rotation**: `vkt_bank_switch(i)` at each layer **head** (the primary
  chain only — the second device keeps its own serving), over the quiescent tail the layer
  before left (each layer **tail** does `vkc_submit(1)`: the switch's precondition, per
  `vk_tier.c`'s contract "nothing reads the old layer's experts"), then the tier's own fill
  seam refills at most once a tenure at the layer's first host routed step. `slot_pos` is
  snapshotted before the first layer's pass (`sp0`) and each layer head's lowering tests the
  snapshot — the live `slot_pos` has followed the earlier layers' chunks, but a later layer's
  mirrors still hold the state the snapshot describes. The marking pass stays idempotent
  (every layer writes the same positions).
- **`COLI_VK_DMOE=all`** (the minimal `lo..L` form, ~55 lines in the arm + the parse): one
  `vkc_dmoe_prepare` over the chain's range (vk_dmoe.h's own support — the port's arm was the
  only restriction), the per-layer gate tensor looked up at each visit (one gate a layer — a
  loop over 43 layers cannot cache one), hash layers and gate-less layers masked to the host's
  step (`ch->dmar`), the router's bias written per unit. The arm **declines with one line**
  when the reorder is not taking the forward (decode, a verify, a single chunk, the reservoir
  not fitting) — the chunk-outer loop caches one gate for its one armed layer, so `all` there
  would compute with the wrong gate. `v4c_cut` drops the whole arm (any cut below L), and the
  exit report carries the range form.
- **The deferred books**: `vkt_dev_count` and DSpark's taps read host-mapped memory, so they
  drain at the loop's wait points — a host-step unit's A1 wait, the split's copy-back, each
  layer tail's submit — through a small queue of dmoe units; a tap is read from `xall` (the
  joined rows' home), never off the scratch the next unit's load takes.
- **Counters/report**: `COLI_VK_CHAIN_ORDER=layer: N layer-ordered prompt forwards, M
  layer-chunk units` at exit (the engagement line, beside the tier's bank run line).
- **Declines**: a prompt whose streams/lists/tables do not fit beside the chunk's scratch runs
  in the chunk order with one line (and the reserves are restored — a freed `xd`/`list`/`cs`
  is re-reserved before the chunk path could need them); `all`'s decline paths each print one
  line; the 3072-entry decline and the per-layer count checks stay in the **shared prelude**
  (see §1) — the same lines run under both orders.

**LOC vs the charter** (loop restructure 400-700, hoist 100-200, ks re-plumb 100-200,
counters 50-100): landed **+433** in the chain header (the loop is a *second* driver beside
the untouched chunk loop rather than an in-place restructure — the byte-identity argument is
stronger and the default path carries no diff), +9 in vk_dmoe.h, +20 in the Makefile (three
gate legs), +docs. Under the band because the ks copy-backs and the pull copy-out were
*copied* rather than re-plumbed (the unit is the layer body verbatim), and the engine file
needed nothing.

**Deviations from the charter's sketch, justified:** (i) the prepare/count checks stay in the
prelude, not moved to the layer head — a mid-forward decline after device work would need
rollback machinery for zero benefit (the checks are order-independent); (ii) the per-layer
lowering runs at the layer head but the *stale test* reads the pre-pass snapshot, not the
chunk path's live `slot_pos` — the live map follows the earlier layers' chunks and would miss
stale slots in later layers' mirrors (this is the KV-contract crux, §4); (iii) a layer **tail**
wait (`submit(1)`) per layer, where the chunk path waits once per chunk — the bank switch's
quiescence precondition requires it, and the exposure it adds is the layer's last unit's async
frames, mostly unavoidable in the layer-outer structure anyway.

## 3. The KV/attention contract across the window rings (the stop-rule check — it HOLDS)

The invariant that makes layer-major legal, verified line by line and then empirically: a
layer's pass is self-contained. Its window ring sees the same (chunk, position) sequence it
would in chunk-outer — the ring is per-layer, the chunks within a layer run in order, the
lowering at the layer's head makes the pre-`start` rows exact, and no ring slot is read stale
because the stale test reads the snapshot of the state all mirrors shared at the pass's start.
The compressed rows (whole or split) advance per (layer, chunk) identically — `vkc_kv_place`/
`push` per unit, the per-unit copy-back after each A1, exactly the chunk path's per-(layer,
chunk) set in a different order. The split's host mirror is per-layer, so a later layer's
first push sees its own untouched watermark. The empirical proof: **the landed path is
bit-equal to the chunk order at the tiny fixture** (the streams at the forward's end compared
under `V4C_LO_DEBUG`, 8-token prompt, rows 2/3/4, three layers: identical floats), and the
brio/prefix/tiny oracles are green at every cut tried.

## 4. The bug the gates caught (recorded for the method, not the shame)

The first cut wrote the chunks' lists and RoPE tables once at layer lo and assumed "no layer
changes them" — true per device frame, false across the forward: layer lo's **next chunk**
overwrites the buffers before the later layers' units read the chunk they are visiting. The
symptom was exactly the numerics law's shape: the ECHO logits moved with the chunk cut
(row-0 predictor 6/59/55 at rows 2/3/4 against the chunk order's 55 at every cut), the tiny
oracle still token-exact on its own prompts (the margins there do not sit on the boundary),
`L=1` bit-equal, `L=2+` diverging — the layer-1 units were reading chunk-2 lists as their
own. Found by the brio `echo-is-the-head` check (a GPU-vs-GPU cross-shape comparison the tiny
teacher-forcing cannot replace), root-caused by a logits dump (0.13-0.26 absolute logit
divergence — a wrong list, not a reassociation) and a stream-level debug print, fixed by the
per-chunk device regions of §2. A second bug (a heap overflow: the host RoPE buffer written
at device-region offsets) crashed the first rebuild of the fix and was caught immediately.
Both are gone; the landed path is the bit-equal one.

## 5. Unit evidence (the reorder's, at tiny — the tiny-check-dmoe gate's three new legs + the manual matrix)

- **Bit-equality vs the chunk order** (the numerics law at `GEMM_ROWS=0`): the forward-end
  streams identical at rows 2/3/4 (§3); the brio numeric channel (read-only ECHOs, echo-is-
  the-head, the pin check, generation-with-tail) **PASS at rows 2, 3 and 4** with the layer
  order alone.
- **The composed fold** (`ORDER=layer ROWS=4 BANK=1 DMOE=all ROWS=1 ROWS_MAX=8`): token-exact
  on every oracle; engagement deterministic — the boot carve `bank=layer 1, 4 experts
  (120.0 KiB), the stream slots' budget 64 -> 60`, the run line ending `bank: layer 2, 4 of 4
  experts valid, 4 refilled` (the rotation 1→0→1→2 across the forward's layers), and
  `COLI_VK_DMOE=all: layers 0..2, 2 layer steps through the dmoe path (2 in-frame, 0 hybrid)`
  — layer 0 is the fixture's hash layer (masked, host step), and each armed layer's **first
  chunk pays the host step** while the fill seam publishes its places, the rest compute
  in-frame: exactly the designed warm-up discipline, counted per layer.
- **The frame-split composed** (`ROWS_MAX=2` at rows 4): `4 in-frame` steps, each unit's
  grouped GEMMs split into 2-row groups, token-exact.
- **Per-layer rotation counts / at-most-once**: the tiny run lines carry `4 refilled` total
  across three tenures (one fill's worth of experts each — the bitmap cleared per switch, no
  re-read); `L=1` runs show zero rotation (the loop drives it, nothing else).
- **Decline paths**: `DMOE=all` without the order → one line, exit line `0 layer steps …
  none: the host's step kept every one`, text exact; the 3072-entry decline is shared-prelude
  (§1) — the identical lines run under both orders, and the armed legs prove the prelude
  executes with the order set (the tiny fixture cannot *fire* it: `MAX_POSITIONS=128` against
  the (3072−W)·ratio threshold — the construction argument is the evidence, honestly
  recorded); the reservoir decline line is exercised by code review (its failure action is
  the chunk path, which the whole gate set covers).
- **The prefix leg** (`ORDER=layer ROWS=4`, prefix harness): PASS — layer-ordered
  continuations over pinned prefixes (`start > 0`, the head lowering against the snapshot).

## 6. Gates (final code; the rig, gates only — no bench arms)

| gate | result |
|---|---|
| `vk-tier-check` (VK=1) | **PASS** (bank cases incl. the 2-layer rotation unit + host-pairs) |
| `vk-chain-check` (VK=1) | **PASS** (11,966 frames — S1's count unchanged: the reorder adds no op to the tested paths) |
| `vk-strict-check` (VK=1) | **PASS 3/3** |
| `deepseek-v4-tiny-check` | **PASS** (23 PASS lines; the fixture regenerated with the port-baseline venv, transformers 5.14.1 — byte-identical `ref.json`, confirming the generation is deterministic) |
| `deepseek-v4-tiny-check-dmoe` | **PASS** (63 PASS lines: S1's five legs + the three new S3 legs — the reorder at rows 4 ×2, the composed fold) |
| `tests/test_v4_serve_framing` | **PASS** (`v4 serve framing baseline: ok`) |
| `cu_tier.c -DCOLI_CUDA -fsyntax-only` | **PASS** (the tier untouched by S3; re-run for the record) |
| `tests/vulkan_engines.sh deepseek` | **environment-blocked, pre-existing**: `vkCreateInstance failed: -9` → `FAIL: deepseek_v41 cap=1: no matmul ran on the device` — **proven at the stashed base 9a138417 with the identical signature** (the v41 leg compiles no S3 code; the rig's v41 leg cannot see the device, exactly as at S1's 473fd669 proof) |
| byte-identity vs the D11 pin (`scripts/vk_golden_parity.sh --quick --upstream-ref=073a03b6…`) | **GREEN** — tiny/real-deploy/real-pinned all GREEN, **ALL HARD GATES GREEN**, `gpu-inconclusive: 0`, 200.3 s, leg A cache-hit, `vram0` the exact idle floor before and after |

A note for the manager, recorded not fixed (gate policy, not S3's to change): running the
`COLI_VK_DMOE=1 COLI_VK_DMOE_ROWS=1` brio leg **standalone against a previously-run-mutated
`.coli_usage`** can flip its pin check (`pinned predictor … differs … 1e-4` at this fixture
draw) — the pinned 1-row extension takes the per-pair dmoe path, the cold multi-row chunk the
grouped path, and the lever's own documented chunk-cut class puts ~3e-3 between them at some
draws. It is **pre-existing at base 9a138417 with the identical signature** (proven), and the
gate target itself is deterministic-green because it regenerates the fixture (a fresh
`.coli_usage`) before the legs. The check's tolerance vs the lever's documented class is a
decision for the campaign, not this lane.

## 7. What the arms will measure (not run here — the bench window is the manager's)

The bars stand re-expressed against S0's decomposition (X): STAGE 105.6 → < 53 s **and** MOEH
49.2 → < 25 s, or TTFT 159 → ≤ 134 s. What the machinery prices: with the bank composed
(`ORDER=layer BANK=1 DMOE=all ROWS_MAX=512`), each layer's first chunk pays the fill (the
layer's routed experts, disk→VRAM, once — the at-most-once discipline per tenure) and the
rest compute in-frame from VRAM; the stream slots (or the bank's carve) stop thrashing
per-chunk; the staging mass that owned 66 % of TTFT becomes per-layer instead of per-chunk.
Without the bank (`ORDER=layer` alone) the slots become the bank — reuse distance 43 → 0 —
the cheaper arm to read first. The engagement lines to watch: the chain's `layer-ordered
prompt forwards / layer-chunk units`, the tier's `bank: layer n … refilled` per tenure, the
dmoe exit line's in-frame count (the first-chunk host steps are expected and priced), and
S0's prefill line (the STAGE/MOEH buckets are the bars). The amdgpu boundary holds by
construction: each unit's submissions are the chunk path's own A1/A2 frames plus the
`ROWS_MAX` split — no new submission class.

## 8. Residual notes

- The layer tail's per-layer `submit(1)` adds L waits a forward (43 vs the chunk path's 2):
each waits only the layer's last unit's async frames (the switch's quiescence precondition).
Priced into the arm, not hidden.
- The `all` arm's `vkc_dmoe_upload` re-reads the whole lo..L table per unit after each epoch
bump (the bank rotation bumps it per layer): ~880 KB a read at model scale, host-side —
bounded, noted for S5's settle work if it ever shows.
- `v4c_chunk_rows`' fit line does not subtract the reorder's fixed bytes (the reservoir, the
side-by-side lists/tables — ~2×n×HD×4 + n×(nkind×LR + 2×rows+rmax)×4); the reserves
themselves decline safely when they do not fit (one line, the chunk order runs), and at the
standing arm's 2-chunk shape the headroom dwarfs them. A very long prompt declines to the
chunk order — correct, and the decline line says so.
- The second device's chain takes the reorder too (its own seg); its bank/`all` arms stay off
(the primary's), as the single-layer arm always was.
