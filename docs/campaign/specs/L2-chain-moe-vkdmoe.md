# L2 — wire DeepSeek V4's routed-expert MoE through upstream's `vk_dmoe` (implementation spec)

Status: DESIGN, implementation-ready. Read-only lane; no code changed by this spec.
Base refs: port `3064378e` (`port/up-2276`, frozen; all port cites are this ref via `git show`),
Q-l2's tree `c5d88880` (`c/vk_dmoe.h`, `c/vk_chain.c`, `c/deepseek_v4_chain.h` are byte-identical
between the two — verified by empty diff, so Q-l2's anchors hold), fork `d11fba5b`.
Prior art already in git: **`port/dmoe-s1`** (`5d6b9b7b` + `2bde007c`, parked, NOT merged) — the S1
slice Q-l2 designed was built and measured; see §0 and §8 before writing any code.

---

## 0. Verdict up front (read this before anything else)

1. **The naive premise is falsified on this rig.** "Move the 134–216 s of host-side routed experts
   onto the device" is not achievable by wiring alone, because `vk_dmoe`'s layer gate is
   **all-or-nothing per layer** (`d->on[i] = n == E`, `vk_dmoe.h:273-275`) and a DSV4-Flash layer is
   256 experts × 15.0 MiB = **3.75 GiB** (`bench/up2276/merge-all2-r1.log:18`, "budget 7.79 GiB = 337
   experts of 15.0 MiB (fmt 7 gs 32)") against a 7.79 GiB tier budget that must serve 43 layers.
2. **It was tried and measured.** The S1 arm (`COLI_VK_DMOE=n` + `COLI_VK_TIER_PIN_LAYER=n`) is on
   `port/dmoe-s1`; the L3 campaign re-armed it and recorded: *"TTFT **doubled** (with and without
   RATE=0): a whole pinned layer (265 of 520 residents) strangles prefetch admission (12,644 → 1,890
   prefetches, used-rate collapses, disk loads 19.7k → 34.5k)"* (commit `98fcee51` message — the
   **only** place the disk-load 19.7k→34.5k figures exist: they are commit-message-only, with no
   in-tree bench log; the in-tree corroboration is `docs/HANDOVER-2026-10-23.md` §2.3, which quotes
   the TTFT doubling and the prefetch collapse 12,644→1,890 and the "parked; observability kept"
   verdict, but not the disk numbers). A device-pinned layer is a
   measured negative for prefill on 16 GiB. **Do not re-land the pin-based prefill arm.**
3. **What remains real:** (a) the fmt-7 chunk kernel arm (open Q5, §2) — cheap, test-covered,
   dormant until a layer can be resident; (b) a **host-pool-placed layer** (new lever, §3 Stage C)
   as the only untried way to satisfy `on[i]` without strangling device prefetch — bounded, honest
   expectation ~3–5 s TTFT for one layer, ≤3 % decode; (c) upstream alignment: "V4 joins vk_dmoe" is
   the shape of upstream's own direction (dossier §4.6) and the PR-shaped slice of this lane.
4. The 134–216 s wall itself is **byte/stall economics, not device-compute absence**: R-l1 §1
   (counter mismatch; 11,127 streamed instances vs 11,008 unique places = 1.01× re-read; 22.4 s of
   PCIe at 8.59 GB/s vs 3.9 s reported wait) and the engine-store hit-rate work (S7, `b35b076b`)
   own that gap. L2 is a prerequisite vehicle and an alignment play, **not** the TTFT lever.

---

## 1. The contract as it stands at `3064378e` (all verified against the ref)

### 1.1 What `vk_dmoe.h` provides (678 lines — `wc -l` at every ref of this lane: `3064378e`,
`130aa73d` (this branch's base), `port/up-2276`, `merge/up176`, `upstream/dev`; unchanged since the
#2276 merge. *Lane erratum said 679; every reachable ref measures 678, so the verified count
stands.*)

| fn | line | contract |
|---|---|---|
| `vkc_dmoe_prepare(d, lo, L, E, K, D, I, rows)` | `vk_dmoe.h:511` | once per step. Gates: `COLI_VK_CHAIN_MOE != 0`, `rows > VKC_DMOE_ROWS` only if `d->big`, primary device, `vkt_ready/vkc_moe_ready/vkc_route_ready`, `1<=K<=32`, `K<=E<=1024`. Reads the tier table (`vkc_dmoe_read:263`); big steps need `D%64==0 && I%64==0` (`:528`) and ≥1 layer whose formats `vkc_moe_rows_ready` accepts (`:533-536`). |
| `vkc_dmoe_upload(d)` | `:561` | at **every** frame start of the step: `vkt_settle()` then re-read/patch (`vkt_dev_changes`) and write the table. |
| `vkc_dmoe_on(d, layer)` | `:592` | `on[layer-lo] && epoch == vkt_epoch() && !(big && rows_off[i])`. |
| `vkc_dmoe_layer(d, layer, n, lg, bias, x, rt, mp)` | `:600` | `n > VKC_DMOE_ROWS` → `vkc_moe_rows` (`:610`); else hybrid (`:627`, needs `d->hybrid && hx_n[i] > 0 && act==0`) or `vkc_route`+`vkc_moe` (`:640`). Output in `d->y`; ids rank-ordered. |
| `vkc_dmoe_ids(d, layer)` | `:646` | host ptr to `rid[L][cap][K]` after the frame. |
| `vkc_dmoe_free/report` | `:649/:661` | buffers + the stg/hybrid/patch report lines. |

`VKC_DMOE_ROWS` = 8 (`:52`) is a **ceiling on the per-pair path, not a minimum** — decode S=1 is
served by `vkc_moe`, which accepts `S >= 1` and decodes fmt 7 today (`chain_moe.comp:184` `block_7`,
`:319` grouped scales; `moe_fi(7)==0` only skips the format-specialised pipeline, `vk_chain.c:2201`).

Epoch discipline (`vk_dmoe.h:29-36`, the header's own warning): a layer the host steps through runs
the tier, which may evict/free/upload experts; a frame that read the table earlier would read freed
memory (crash/wrong tokens on a software device). Hence `vkc_dmoe_upload` at every frame start and
the `vkt_epoch()` compare in `vkc_dmoe_on`. V4's chain runs the host step at **every** MoE layer
today, so upload must follow each host layer (mirror `olmoe_chain.h:646`).

### 1.2 Where V4 stands apart (the gap this lane closes)

* `deepseek_v4_chain.h:90-91` includes only `vk_chain.h`, `vk_kv_split.h` — no `vk_dmoe.h`
  (callers today: `olmoe_chain.h:57`, `qwen36_chain.h:77`, `qwen38_chain.h:59`).
* The host MoE step: `deepseek_v4_chain.h:1312-1324` — `coli_v4_moe_routed(...)` between frame A1's
  `vkc_finish()` (`:1301`) and the next layer's `vkc_begin()` (`:1325`); `ch->host_ms` accumulates it
  and `v4c_report` (`:1483-1494`) prints it ("140877.7 ms of routed experts on the host" in
  `merge-all2-r1.log`). The chunk loop is `:1210`, the layer loop `:1288`, A2 (shared expert) `:1310`.
* The tier's table counts **only primary-device residents** (`vk_tier.c:3050-3062`, `dev_entry`:
  `state==VS_RESIDENT && dev==0 && ex`) — but "residents" include **host-pool placements**
  (`set_place(v,2)` → `dev=0, host=1`, `vk_tier.c:231-233`): pool experts have entries whose
  addresses point into pinned host RAM the device reads by BDA over PCIe. This is the seam Stage C
  (§3) uses.
* The router on the host: `route_bf16_impl` (`deepseek_v4.c:11118-11190`) — `score =
  sqrt(softplus(logit))`, `selection = score + bias`, top-K by selection (lower expert on a tie),
  `w = score/total * routed_scaling_factor`. Maps exactly to `VkcRoute{kind=2, has_bias=1,
  n_group=1, topk_group=1, norm=1, temp=1, scale=routed_scaling_factor, norm_eps=0}` — `chain_route.comp`
  implements kind 2, bias-for-pick-only, lower-expert-on-tie, norm-1 (verified `vk_chain.h:404-421`).
* Activation: V4's SwiGLU clamp (`g=min(g,lim), u=clamp(u,±lim)`) is identical in `chain_moe.comp:354`,
  `qmatmul_grp_mx.comp` GATE_UP epilogue, and the CPU `host_pairs` (`vk_tier.c:2030-2036`). One
  numerics class.
* Hash layers (`i < config->num_hash_layers`, `deepseek_v4.c:677`) route via a token→expert table
  (`ffn.gate.tid2eid`) that `vkc_route` cannot express → they keep the host step. The tiny fixture
  has `num_hash_layers=1` (`c/tools/make_deepseek_v4_tiny.py:267`).
* Geometry (DSV4-Flash): E=256, D=4096, K=6 (`deepseek_v4.c:12689-12690` gates), I=2048 (12.75 MiB
  raw e2m1+ue8m0; the tier's f32-scale form is the logged 15.0 MiB), experts fmt 7 gs 32 both
  matrices. `D%64==0`, `I%64==0`, `rowWords%4==0`, `gs%32==0` — every mx host gate passes.

### 1.3 The parked S1 branch (what already exists — reuse, do not rewrite)

`port/dmoe-s1` (`5d6b9b7b`, `2bde007c`; diff vs `port/up-2276`: 201 insertions over 6 files):
* `deepseek_v4_chain.h`: `#include "vk_dmoe.h"`; `VkcDmoe dm; VkcBuf *lg, *gbias;
  ColiVkTensor *gate; const float *gate_bias;` in `V4Chain`; `v4c_dmoe_arm()` (env `COLI_VK_DMOE=n`,
  one non-hash layer, **rows ≤ VKC_DMOE_ROWS only**, gate via `v4c_plain(w,"ffn.gate.weight",11)`,
  bias via `v4c_val`, `vkc_dmoe_prepare(&dm, n, 1, E, K, D, I, rows)`); the layer-loop branch
  (in-frame `v4c_shared` + `vkc_matmul(gate, nrm → lg)` + `vkc_dmoe_layer`, `vkc_layer_recorded`
  frame-splitting, kv-split end-of-frame special case); `v4c_join(ch, nr, dev)` taking `dm.y`;
  `vkc_dmoe_upload` at both frame starts; `vkt_dev_count` books after `vkc_submit(1)`; report line;
  `v4c_dmoe_drop` at off/cut.
* `vk_dmoe.h`: `vkc_dmoe_layer_env()` (the `COLI_VK_DMOE` parse).
* `vk_tier.c`: the PIN_LAYER block — **already merged** to `port/up-2276` in `0c6ddae2`
  (`vk_tier.c:918-928` warm-start queueing + `:989-998` `hot_pin` pinning, env at `:2815`), whose
  comment says it outright: *"COLI_VK_TIER_PIN_LAYER (the COLI_VK_DMOE arm's scaffolding)"*.
* Tests: `test_vk_chain.c` (+22), `test_vk_tier.c` (+39).

---

## 2. Open Q5, answered: does fmt 7 (gs 32) fit `vkc_moe_rows`' item/amap/coop path?

**Yes — the float path fits with a pipeline swap plus a 36-byte push constant. No new kernel arm is
needed. No coop (matrix-unit) variant exists or is required.** Evidence, line by line:

* `chain_moe_rows.comp` **mode 1, the etab/items planning loop** (anchored by symbol: the block
  after `// mode 1: one workgroup`; at `130aa73d` it is `:73-126`, etab words `:106-113`, items
  `:118-120`, the two indirect-dispatch sizes `aux[0]/aux[4]` `:124-125`) writes one 16-word `etab`
  per expert per pass:
  `[0..3]` gate w+scales BDA, `[4..7]` up, `[8]` row count, `[9]` first packed row, `[10]` fmt,
  `[11]` rowWords, `[12]` gs, `[14..15]` block-table address; `items[] = (expert, first row, output
  block, 1)`; `nob1=(I+31)/32`, `nob0=(D+63)/64`; `aux[0]/aux[4]` drive the two indirect dispatches.
* `qmatmul_grp_mx.comp` reads **exactly that**: `etab[eb+0..3]`, `[+4..7]`, `[+8]`=S, `[+9]`=xoff,
  `[+11]`=rowWords, `[+12]`=gs (`:60-70`); x through `amap[xr]/kgat` (`:100-105`), `y[yr]` with
  `yr=amap[...]` (`:145-152`); `BO=32` GATE_UP / `64` down — the same output-block geometry the
  planner emits. Bindings 0..4 identical to `qmatmul_grp_bd.comp`.
* The only deltas vs the wired bd/q pipelines: push constants `{I,O,limit,ibase,kgat,rpw,act,a,b}`
  = **36 B** vs today's 24 B (`qmatmul_grp_mx.comp` **`layout(push_constant)`** — at `130aa73d`
  `:33` — vs `vk_chain.c:2700/2705`; the layout allows
  128 B, `vk_chain.c:517`), and no specialization constants. Shared memory: GATE_UP
  (2·32+32)·17 vec4 = 26,112 B < `ROWS_GRP_SHARED` 35,648 (`vk_chain.c:2653`) — no new bar.
* The mx shader is **in production** as the tier's expert-batch mode 4 (`xb_grp_mx_init`/
  `xb_grp_mx_pipe`/`xb_grp_record`, `backend_vulkan.c:4662+`; landed `0e79f870`), and the `.spv`
  Makefile rules already exist (`c/Makefile:764, 955-960`).
* The rejection today is exactly two lines: `our_fmt(f) = f==1||f==2||f==4` (`vk_chain.c:2598`) and
  `vkc_moe_rows_ready`'s `q = our_fmt(gfmt) && our_fmt(dfmt)` (`:2665-2669`). Decode (S ≤ 8) is
  **not** rejected anywhere — `chain_moe.comp` decodes fmt 7 (`:184`, `:319`).

**Route costs:** (a) extend `vkc_moe_rows` to fmt 7 via the mx pipelines — **~55–70 LOC in
`vk_chain.c` + ~6 test LOC; no shaders, no Makefile** (enumeration in §6). (b) a new fused fmt-7
chain-MoE kernel (sibling of `chain_moe_gv.comp`) — 250–450 LOC + tuning; **only** if the generic
`chain_moe.comp` fmt-7 per-pair path measures slow at S=1/K=6 (unmeasured; `rpw=64/spl=8` is
i4-shaped, plausible 1.3–2× miss) — deferred, trigger in §7. (c) re-encode fmt 7 → fmt 1/2/4 at
load — **rejected**: e2m1 codes are not representable by the linear i4 LUT (a requantisation, new
numerics), 167 GB to rewrite, and it would desync the tier's tensors from the file.

**Reconciling Q-l2's "60–90 LOC" with the dossier's "300–800 LOC":** both are right, different
scopes. 60–90 = the fmt-7 GEMM plumbing inside `vk_chain.c` **only** (route (a); Q-l2 §3a's
7-point enumeration verified against the ref, item by item). 300–800 = the whole L2: engine wiring
of `vk_dmoe.h` into `deepseek_v4_chain.h` (the parked branch's 121 lines there + 14 in
`vk_dmoe.h`), epoch discipline, books/report, the fmt-7 arm, tests and ENVIRONMENT rows. Reconciled
total for everything in §3: **~215–240 code LOC + ~45 test/doc LOC** — inside the dossier's band,
at its floor.

---

## 3. Chosen route (prefill AND decode), staged — with rejected alternatives

**Stage A — re-land the parked wiring (decode/verify only).** Rebase `port/dmoe-s1`'s
`5d6b9b7b`+`2bde007c` onto `port/up-2276` (the PIN_LAYER half is already merged; drop the duplicate
`vk_tier.c` hunk). Keep `COLI_VK_DMOE=n` opt-in, default 0, one non-hash layer, rows ≤ 8. No perf
claim; this is the oracle/wiring vehicle (§5) and the upstreamable "V4 joins vk_dmoe" PR body.

**Stage B — the fmt-7 chunk arm (route (a), §2).** `vkc_moe_rows` learns fmt 7 through the mx
mode-4 pipelines; `vkc_moe_rows_ready(7,7)` becomes true; `vkc_dmoe_prepare`'s big path stops
rejecting DSV4 layers (`rows_off[i]` clears). Gate behind its own opt-in (`COLI_VK_DMOE_ROWS=1`,
mirroring `COLI_VK_CHAIN_GEMM_ROWS`'s precedent at `deepseek_v4_chain.h:1189-1201`) because a
prompt row's bits then depend on the chunk — the same invariant break GEMM_ROWS already documents.

**Stage C — the residency lever that is NOT a device pin: pool-place one layer.** New tier knob
`COLI_VK_TIER_POOL_LAYER=n` (~20–30 LOC beside the PIN_LAYER block, `vk_tier.c:918-928`): queue
layer n's 256 experts into the **host pool** at warm start (`set_place(v,2)`) instead of device
slots. `vkt_dev_table` then counts all 256 → `on[n]=1` **without touching device residency or
stream slots**, so the measured prefetch-strangling mechanism (§0.2) does not fire. Prefill chunks
read the layer's experts over PCIe inside the mx GEMMs (~4–8 GB/s → 3.75 GiB ≈ 0.5–0.9 s per
chunk-visit vs ~3.3 s host compute/layer); decode S=1 takes the hybrid arm (CPU computes the pool's
pairs in place, overlapped — the CPU fmt-7 kernel exists: `host_fmt_ok` accepts 7 at
`vk_tier.c:1750-1756`, `dev_codes_fp4`/`dev_dot` at `:1819-1890`) or `vkc_moe` reading over PCIe.
Set `d->big = 1` in `v4c_dmoe_arm` and lift the `rows > VKC_DMOE_ROWS` cap only when Stage B is in.

**Rejected:**
* **Device-pinned whole layer (the dossier's implicit S1 residency plan, Q-l2 §3's precondition)** —
  measured ×2 TTFT (`98fcee51`); prefetch 12,644→1,890 (in-tree: HANDOVER §2.3); disk loads
  19.7k→34.5k (**commit-message-only**, `98fcee51`). Dead on 16 GiB.
* **Route (b) new kernel** — deferred with a measurement trigger (§7); not needed for correctness.
* **Route (c) requant** — §2.
* **"All layers"** — 43 × 3.75 GiB = 161 GiB; the dossier's "almost never all-resident on a 167 GB
  model" is arithmetic, not policy.
* **Prefill-value claims from the 215.9 s host-MoE line** — R-l1 §1 showed the byte accounting behind
  that wall is stall-dominated; do not promise it.

---

## 4. Seam list at `3064378e` (file : function : line — every touch point)

**Stage A (re-land; anchors are the parked diff's context lines):**
1. `c/deepseek_v4_chain.h:90-91` — add `#include "vk_dmoe.h"` after `vk_kv_split.h`.
2. `c/deepseek_v4_chain.h:96-130` (`V4Chain`) — add `VkcDmoe dm; VkcBuf *lg, *gbias;
   ColiVkTensor *gate; const float *gate_bias;`.
3. `c/deepseek_v4_chain.h` new `v4c_dmoe_arm`/`v4c_dmoe_drop` beside `v4c_layer_free` (`:639-644`
   context) — env parse, hash-layer skip (`uses_hash_router`), `v4c_plain(w,"ffn.gate.weight",11)`
   (`:364-374`), `v4c_val(w,"ffn.gate.bias")`, `vkc_dmoe_prepare(&dm, n, 1, E, K, D, I, rows)`.
4. `c/deepseek_v4_chain.h:1104` (`v4c_forward_seg`) — call `v4c_dmoe_arm(ch, rows)` after the
   `v4c_cache` loop (`:1161` context); `vkc_dmoe_upload` + bias write before the layer loop
   (`:1349` context, after `slot_pos`).
5. `c/deepseek_v4_chain.h:1288-1326` (layer loop) — the dmoe branch between the FFN-norm records
   (`:1293-1295`) and A1's submit: `v4c_shared` + `vkc_matmul(ch->gate, ch->nrm, 0, ch->lg, 0, nr)`
   + `vkc_dmoe_layer(&ch->dm, i, nr, ch->lg, ch->gbias, ch->nrm, &rp, &mp)`, `vkc_layer_recorded`
   (`vk_chain.h:96-104`), kv-split frame-end special case; host path keeps
   `vkt_stream_prefetch` (`:1300`) and gains `vkc_dmoe_upload` after `vkc_begin()` (`:1325`).
6. `c/deepseek_v4_chain.h:1081-1086` (`v4c_join`) — `dev ? ch->dm.y : ch->routed` as the addend.
7. `c/deepseek_v4_chain.h:1367+` (after `vkc_submit(1)`) — `vkt_dev_count(ch->dm.lo, nr, ch->dm.K,
   vkc_dmoe_ids(&ch->dm, ch->dm.lo))` when the armed layer ran.
8. `c/deepseek_v4_chain.h:1483-1494` (`v4c_report`) — the COLI_VK_DMOE line (always prints when the
   env named a layer — `2bde007c`'s fix).
9. `c/vk_dmoe.h:127-140` — `vkc_dmoe_layer_env()` (COLI_VK_DMOE parse; distinct from
   COLI_VK_CHAIN_MOE).
10. `c/vk_tier.c:2815-2816` — PIN_LAYER env read (already merged, `0c6ddae2`).

**Stage B (fmt-7 arm, all in `c/vk_chain.c` + tests):**
11. `c/vk_chain.c:129-133` (KC struct, beside `mod_grpq/grpq`) — `VkShaderModule mod_mx[2];
    VkPipeline mx[2]; uint8_t mx_tried[2];`.
12. `c/vk_chain.c:2582-2596` (beside `grpq_pipe`) — `mx_pipe(v)`: load
    `qmatmul_grp_mx.spv`/`qmatmul_grp_gate_up_mx.spv`, `make_pipe(mod, NULL)`, no coop variant.
13. `c/vk_chain.c:2598-2611` — `our_fmt` unchanged; add `mx_fmt(f) = (f == 7)`;
    `rows_pipe1(v,f,coop)` → `f==7 ? (coop ? VK_NULL_HANDLE : mx_pipe(v)) : …`;
    `rows_coop` → 0 for 7.
14. `c/vk_chain.c:2665-2669` (`vkc_moe_rows_ready`) — `q = (our_fmt(g)&&our_fmt(d)) || (g==7 &&
    d==7)`, plus `mx_pipe(0) && mx_pipe(1)` in the conjunction.
15. `c/vk_chain.c:2700/2705` (`vkc_moe_rows`'s `pg`/`pd`) — for `p->gfmt==7` push the 36-byte
    `{I,O,limit,ibase,kgat,rpw,act=0,a=0,b=0}` structs.
16. `c/vk_chain.c:3373-3381` (destroy) and `:2388-2414` (`vkc_prewarm`'s rows block, the
    `pw->ex_ours` loop at `:2410`) — destroy the mx modules/pipelines; prewarm them with the same
    empty-item record (a late-made pipeline slows every later launch — the block's own comment).
17. `c/vk_chain.h:469-470` (`VkcPrewarm`) — either reuse `ex_ours` or add `ex_mx` so the prewarm
    knows to build the mx pipelines.
18. `c/tests/test_vk_chain.c:3366-3425` (`test_moe_rows_q`) — generalize the fmt-4 byte/group
    sizing (`rg = D/2`, `ng = D/gs`, `g = (fmt==4||fmt==7) ? gs : 0`) and add rows at `:4466-4470`:
    `test_moe_rows_q(7, 32, 40, 4, 12, 512, 256);` and a small-shape variant
    `test_moe_rows_q(7, 32, 7, 2, 6, 256, 256);`.

**Stage C (pool-placement lever):**
19. `c/vk_tier.c:918-928` (`vkt_plan`, the PIN_LAYER block) — `COLI_VK_TIER_POOL_LAYER=n`: queue
    layer n's experts with `set_place(v, 2)` (host pool) instead of device, subject to
    `room_dev`/pool capacity (`T.h_budget`), and pin them in `hot_pin` (`:989-998`) so promotions
    cannot churn them; env read beside `:2815`; sizing/report beside `:2830`.
20. `c/deepseek_v4.c:14212-14332` (DSV4's `VktConfig`) — **R-l1 OPEN-4, resolved: not a missed knob for V4 today**.
    `.stage` is unset (unlike `olmoe.c:1235`, `qwen36.c:7709`, `qwen38.c:3166`), but the carve it would enable is
    doubly gated on **block formats** (`vk_tier.c:2794`: `T.c.stage && blocks && …`, where `blocks` scans for
    `gu_fmt/dn_fmt >= 100`; and `vkc_stage_sizes`, `vk_dmoe.h:320-324`, returns 0 for fmt 7) — V4's experts are
    all fmt 7, so setting `.stage` would be a **no-op**, and if the format gate ever loosened it would carve
    device budget (`vk_tier.c:2781-2797`) for staging fmt 7 never uses. Leave it unset; document the reasoning
    beside the config so a future block-format V4 knows the knob exists.

**Engine wiring context (canonical sequence to mirror):** `c/olmoe_chain.h:504-620` —
`olc_dmoe` (`:513`, `dm.big = 1` at `:175`), upload at frame start (`:583`), the layer branch
(`:597-616`), host fallback + upload (`:618-646`), `olc_dmoe_done` ids→`rt_count/ehit_mark/
vkt_dev_count` (`:519-537`).

---

## 5. Oracle and gate plan (there is no fmt-7 device-MoE numerics oracle today — dossier §4.5)

**Class law (inherited):** thresholded, not bitwise. `vkc_moe_rows`' float accumulation is not
bit-identical to `vkc_moe`/CPU (rank-order vs ascending-expert-id sums — CPU at
`deepseek_v4.c:6233-6241`, the shaders' rank-order sums at `vk_chain.h:428-434` and
   `chain_moe_rows.comp:74-80`); the tier's own mode-4 class measured
worst rel err 3.8e-07 (`0e79f870`). The bf16 round at `v4c_join` absorbs most of it — **assert, never
assume**.

1. **Unit oracle (Stage B's gate, ships with the code):** `test_moe_rows_q(7, 32, …)` —
   `vkc_moe_rows` (mx pipelines) against `vkc_moe` (the generic fmt-7 `chain_moe.comp` path) on
   random e2m1 weights with ue8m0→f32 scales, tolerance `1e-4·max(1,ref)` in floats (the existing
   row's rule; no coop variant exists so the 2e-3 matrix-unit branch never fires). This *creates*
   the missing fmt-7 oracle at exactly the level the dossier demanded, from upstream's own harness
   (`test_vk_chain.c:3395-3410`).
2. **Router oracle:** `vkc_route` kind-2 vs `route_bf16_impl` on random logits+bias — ids equal
   (incl. tie order), weights within 1e-6 rel. New ~30-line test beside `test_moe_rows_q` (both
   live on device buffers already built there).
3. **Chain/token gate (Stage A/B):** the `deepseek-v4-tiny-check` fixture class
   (`c/Makefile:856-876`; generator `c/tools/make_deepseek_v4_tiny.py` — HIDDEN=128, LAYERS=3,
   EXPERTS=4, TOPK=2, MOE=128, **experts fp4/e8m0 gs 32 = fmt 7**, `num_hash_layers=1`,
   token-exact greedy + teacher-forcing expectations baked in). Run it with `COLI_VK_DMOE=<a
   non-hash layer>` (layer 1 or 2; layer 0 is hash): **primary gate = token-exact**; if the
   numerics class breaks it, the pre-registered fallback is a thresholded gate — max |Δlogit| ≤
   1e-3·max(1,|logit|) on the prompt's first-token logits and greedy tokens equal over ≥32 tokens,
   recorded as a new expectations file, not a silent tolerance. D=I=128 satisfies the %64 gates, so
   the tiny fixture exercises `vkc_moe_rows` too once `big` is on.
4. **Gate extension (exact deliverable):** a `deepseek-v4-tiny-check-dmoe` target = tiny-check with
   the armed env, plus the vk gate set already green at tip (`vk-tier-check`, `vk-chain-check`,
   `vk-strict-check`, `test_v4_serve_framing`, `cu_tier.c -DCOLI_CUDA -fsyntax-only`). No `.golden`
   re-record needed (that is the fold's cost, not this lane's).
5. **Invariant guard:** Stage B changes a prompt row's bits (chunk-dependent accumulation) — same
   class as `COLI_VK_CHAIN_GEMM_ROWS=-1` (`deepseek_v4_chain.h:1189-1201`). Keep it opt-in and
   documented in the ENVIRONMENT row; decode/verify rows must keep the per-pair path's bits.

---

## 6. LOC estimate and risk list

**LOC (reconciled; see §2 for the 60–90 vs 300–800 reconciliation):**
| stage | files | LOC |
|---|---|---|
| A re-land | `deepseek_v4_chain.h` 121, `vk_dmoe.h` 14 | ~135 (already written on `port/dmoe-s1`) |
| B fmt-7 arm | `vk_chain.c` ~55–70, `vk_chain.h` ~2, tests ~6–10 | ~65–80 |
| C pool lever | `vk_tier.c` ~20–30, `deepseek_v4.c` ~2, ENVIRONMENT/docs ~10 | ~30–40 |
| **total** | | **~230–255** |

**Risks:**
1. **`vkt_epoch` freed-memory reads** (`vk_dmoe.h:29-33`): V4's chain runs the host tier step at
   every non-armed layer; each can evict/free experts an in-flight frame's table names. Mitigation
   is exactly the header's discipline — `vkc_dmoe_upload` at **every** frame start (parked branch
   does: before the layer loop and after each host layer's `vkc_begin`), `vkt_settle()` inside it,
   epoch compare in `vkc_dmoe_on`. Residual risk: the kv-split frame-end special case in the armed
   branch (the parked code's `ch->ks.on` path) — keep it; review any new submit point.
2. **VRAM competition:** dense chain ≈6.3–6.4 GiB (6,794,838,940 B of matrices + buffers;
   `merge-all2-r1.log`) +
   tier 7.79 GiB on a 16 GiB RX 6900 XT. Stage C avoids device VRAM (pool = pinned host RAM;
   HOST_GB must be ≥ ~3.9 GiB for one layer + heat tail — the 5–8 GiB pools already run on this
   rig). Stage B's dmoe buffers are small (`tab` 43·256·128 B, `rid/rwt/hid/y` ~ MiB class at
   2048-row chunks). `vkc_dmoe_prepare` already fails soft (`d->off`) on buffer loss.
3. **Fallback / partial-residency semantics (the "almost never all-resident" clause):** the
   all-or-nothing gate **is** the fallback — a layer whose experts are not all resident (device or
   pool) simply keeps today's host step; no partial-layer device MoE exists or is added (a zero
   entry is skipped by `chain_moe`, which would silently drop experts — never bypass `on[]`).
   Overflow inside Stage C: if the pool cannot hold all 256, the lever must **decline to place any**
   (print once, arm stays off) rather than place a partial set — a partial set wastes pool bytes and
   still fails the gate. Streaming (`vkt_stream_prefetch`) and the armed layer interleave badly by
   construction (every streamed epoch flips `on[]`); the armed layer must not be a stream target —
   pool-pinned slots are not (they are residents), keep it that way.
4. **Numerics:** §5. The tiny-check token-exact gate is the arbiter; the fallback threshold is
   pre-registered, not post-hoc.
5. **Merge outlook:** `vk_dmoe.h` untouched by all 47 commits since #2276 (`git log b90a369e..HEAD
   -- c/vk_dmoe.h` = 0). `vk_chain.c`'s conflict surface is the KC struct/prewarm/shutdown region
   (mm8 lives there). Stage B confined to `vk_chain.c` + tests rebases cleanly; Stage A touches
   `deepseek_v4_chain.h` (in-flight `COLI_VK_CHAIN_GEMM_ROWS`/host-pool series — the parked branch
   already sits beside both).
6. **Hybrid decode path:** `COLI_VK_HYBRID` needs timeline semaphores and `hx_n[i] > 0`; on RADV
   verify `vkc_hybrid_ready()` before claiming the decode arm — else S=1 falls to `vkc_moe` reading
   pool experts over PCIe (≈ break-even vs host; measure, don't assume).
7. **Pool BAR pressure:** 3.75 GiB of BDA-mapped pinned RAM plus the existing pool; the 8 GiB-pool
   arms ran on this rig, but re-check BAR/`vkMapMemory` behaviour with the dense chain resident
   (VRAM guard `VRAM_MAX_USED_MB` prefix per HANDOVER §6).

---

## 7. Arm design (DESIGN ONLY — do not run; no GPU use in this lane)

**Arms (all on the parity rig, 2,515-token prompt / 64 decode tokens, RDNA2 profile
`COLI_VK_PROFILE=RDNA2`, `COLI_VK_TIER_STREAM_BYPASS=1`, desktop-present guard, ×3 interleaved reps,
existing `bench/up2276/run-arm2276.sh`):**
* **C0 control:** Stage A+B+C merged, all levers off (byte-identical behaviour — the default-0
  gates prove it).
* **D1 decode-only wiring:** `COLI_VK_DMOE=<n>` (n = a hot non-hash layer, e.g. the layer the
  `.coli_usage` history ranks first), **no** residency lever. Expectation: the arm stays off
  (prepare fails: tier never holds 256 of one layer) and the run is bit-identical to C0 — a
  negative-control that the gates fail safe.
* **D2 pool-placed decode:** D1 + `COLI_VK_TIER_POOL_LAYER=n` + `HOST_GB≥5`. Expectation: the armed
  layer runs in-frame (hybrid or PCIe `vkc_moe`); decode delta bounded by one layer's share
  (~1/43 of the 140.9 s host line ≈ ≤3 % decode wall) + one fewer `vkc_finish` per forward.
  Falsifier: decode delta within ±1 % (×3 noise band) → the wiring is orchestration-cheap at this
  residency; stop, ship Stage A+B as alignment only.
* **P1 pool-placed prefill chunks:** D2 + Stage B + `COLI_VK_DMOE_ROWS=1` + `dm.big=1`. Read: TTFT,
  the chain line's "ms of routed experts on the host", tier `stream:`/prefetch counters (must stay
  ≈12.6k prefetches — if they collapse, the pool placement is strangling like the pin did: STOP),
  `vkc_dmoe_hyb_report`/stg lines. Expectation: one layer × **4 chunk-visits** ×
  host-compute→PCIe-GEMM swap — the standing 2,515-token prompt runs **4** chunk steps
  (768+768+768+211; every chunk of the prompt passes through every layer, so the armed layer is
  visited once a chunk). Chunks are sized by `vkc_chunk_rows` from free memory (`COLI_VK_CHAIN_ROWS`
  sets them, `COLI_VK_CHAIN_ROWS_MAX` caps the default 8192) and round to 256-row multiples above
  256 — the rig's logs say "prompt chunks of up to 768 rows" (`bench/up2276/base-18g-r1.log:22`,
  `prompt=2515` at `:31`), so parameterize the band by the chunk count the run actually takes:
  at 4 visits the §3 per-visit figures (≈0.5–0.9 s PCIe-GEMM vs ≈3.3 s host compute a layer-visit)
  give ≈ −9.6–11.2 s TTFT; the earlier "−2.5–5 s at 2 chunk-visits" in this spec was the wrong
  chunk count. Falsifier: TTFT delta ≤ +1 s or prefetch count drops >10 % →
  falsified; record and park Stage C's prefill half.
* **K1 kernel microbench (no model):** `test_vk_chain`'s new rows + a one-off loop of
  `vkc_moe_rows(7,…)` vs `vkc_moe(7,…)` at S∈{1,8,512,2048}, K=6, E=256, D=4096, I=2048 — decides
  route (b)'s trigger (per-pair generic path >1.5× slower than the grouped path at S=1) and gives
  Stage B its throughput number.

**Expected effect (pre-registered, honest):** D2 ≤ +3 % decode; P1 scales with the chunk count —
≈ −9.6–11.2 s TTFT at the standing 4-chunk cut (§7 P1 above, `COLI_VK_CHAIN_ROWS`
parameterizes it); both must clear
the ×3 interleaved noise band or the lane ships code without perf claims. **Falsification of the
lane's premise** is already on record (§0.2); these arms bound the *residual* value only.

---

## 8. Stop-findings

1. **Q-l2's "60–90 LOC" claim holds — but only for the fmt-7 kernel arm (route (a)).** Verified
   against `3064378e` item by item (§2, §4.11-18): ~55–70 LOC in `vk_chain.c` + ~6 test LOC, no
   shaders, no Makefile. The dossier's 300–800 covers the whole L2 (engine wiring + epoch
   discipline + books + arm); reconciled total ~230–255 (§6). The **minimal PR-shaped slice** is
   Stage B alone (fmt-7 in `vkc_moe_rows` + `test_moe_rows_q(7,…)`): self-contained, test-gated,
   zero behaviour change for every existing engine (`vkc_moe_rows_ready(7,7)` only becomes callable
   by a V4 that asks) — that is the "when wanted" of Q-l2's phrasing. The **full wiring** (Stages
   A+C) is a second PR and carries the measured-negative history in its message.
2. **The premise is partly broken — loudly:** the S1 lever was built (`port/dmoe-s1`), re-armed in
   the L3 campaign, and **doubled TTFT** via prefetch strangling (`98fcee51`, HANDOVER-2026-10-23
   §2.3). Any spec that prices L2 as "the 134–216 s lever" is wrong: the wall is byte/stall
   economics (R-l1 §1: 1.01× re-read ratio, 22.4 s PCIe vs 3.9 s wait) and store hit-rate (S7's
   domain). `vk_dmoe` **can** express topk-6 routed experts per token at chunk scale (the
   item/amap/etab machinery is row-count-agnostic; §2) — what it cannot do is hold a 167 GB expert
   set's layers on a 16 GiB card, and the all-or-nothing gate turns that into zero layers.
3. **Q-l2's blocking OPEN is stale:** `COLI_VK_TIER_PIN_LAYER` **exists** at `3064378e`
   (`vk_tier.c:918-928`, `:989-998`, env `:2815`) — merged in `0c6ddae2` and documented as this
   arm's scaffolding. Do not re-implement.
4. **R-l1 OPEN-4 resolved — not a missed knob for V4:** DSV4's `VktConfig` (`deepseek_v4.c:14212-14332`)
   never sets `.stage`, but the staging carve is gated on block formats at **two** layers (`vk_tier.c:2794`
   `blocks` scan; `vk_dmoe.h:320-324` `vkc_stage_sizes` returns 0 for fmt 7) — with all-fmt-7 experts, setting
   `.stage` is a no-op today and would only carve device budget for nothing if the format gate loosened.
   Answer to R-l1: intended-by-construction for this model class; revisit only for a block-format V4.
5. **Q-l2's hybrid OPEN resolved:** the CPU fmt-7 pair kernel exists — `host_fmt_ok` accepts fmt 7
   (`vk_tier.c:1750-1756`), `dev_codes_fp4` + `dev_dot` implement it (`:1819-1890`); the
   `I/gs > 2048` float fallback never fires at I=2048/gs=32 (64 groups).
6. **`COLI_VK_CHAIN_MOE` defaults on** once `vk_dmoe.h` is included — inert for V4 because nothing
   calls `prepare` without `COLI_VK_DMOE`; keep the parked branch's separation (its `vk_dmoe.h:127-
   140` comment states it).
7. **No dmoe-arm bench log survived in-tree**; the measured negative lives in the `98fcee51` commit
   message + HANDOVER §2.3. Quote those, not numbers from this spec's §7 (which are designs). The
   disk-load 19.7k→34.5k pair is **commit-message-only** (absent from HANDOVER §2.3 and from every
   in-tree log); the TTFT doubling and prefetch 12,644→1,890 are corroborated in-tree
   (HANDOVER §2.3).

---

## 9. Implementation checklist (10 lines, no re-derivation needed)

1. `git checkout -b port/dmoe-l2 port/up-2276 && git cherry-pick 5d6b9b7b 2bde007c` — drop the
   duplicated `vk_tier.c` PIN_LAYER hunk (already in base via `0c6ddae2`); keep everything else.
2. `c/vk_chain.c`: add `mod_mx/mx/mx_tried` to KC (`:129-133`), `mx_pipe()` beside `grpq_pipe`
   (`:2582-2596`), `mx_fmt`+`rows_pipe1`/`rows_coop` fmt-7 branches (`:2598-2611`),
   `vkc_moe_rows_ready` `|| (g==7 && d==7)` + `mx_pipe(0)&&mx_pipe(1)` (`:2665-2669`), the 36-byte
   `pg/pd` structs for `p->gfmt==7` (`:2700/2705`), destroy (`:3373-3381`), prewarm beside the
   `ex_ours` loop (`:2410-2414`, add `ex_mx` to `VkcPrewarn` `vk_chain.h:469-470`).
3. `c/tests/test_vk_chain.c`: generalize `test_moe_rows_q`'s sizing to `fmt==7` (`rg=D/2`,
   `ng=D/gs`, `g` set) and add `test_moe_rows_q(7,32,40,4,12,512,256)` + `(7,32,7,2,6,256,256)`
   at `:4466-4470`; add the kind-2 router-vs-`route_bf16_impl` test (§5.2).
4. Run `make -C c vk-chain-check` (or the tree's equivalent) — the fmt-7 rows must pass at 1e-4.
5. Stage C: `COLI_VK_TIER_POOL_LAYER=n` in `vkt_plan` beside `:918-928` (`set_place(v,2)`, decline
   unless all E fit the pool, print once) + `hot_pin` pin (`:989-998`) + env at `:2815`; leave DSV4's
   `VktConfig.stage` unset (§8.4 — the carve is block-format-gated and fmt 7 never stages).
6. In `v4c_dmoe_arm`: set `ch->dm.big = 1` and allow `rows > VKC_DMOE_ROWS` **only** when
   `COLI_VK_DMOE_ROWS=1` (new opt-in, documented like `COLI_VK_CHAIN_GEMM_ROWS` at
   `deepseek_v4_chain.h:1189-1201`).
7. Add `deepseek-v4-tiny-check-dmoe` (tiny-check with `COLI_VK_DMOE=<non-hash layer>`; primary =
   token-exact, fallback = the §5.3 thresholded logit gate as a new expectations file) and run the
   full gate set (`vk-tier-check vk-chain-check vk-strict-check deepseek-v4-tiny-check
   test_v4_serve_framing`, `cu_tier.c -fsyntax-only`).
8. Update `docs/ENVIRONMENT.md` rows: `COLI_VK_DMOE`, `COLI_VK_DMOE_ROWS`, `COLI_VK_TIER_POOL_LAYER`,
   `.stage`; cite `98fcee51`'s measured negative for the pin variant in the PR text.
9. Arms per §7 (design already pre-registered): C0/D1/D2/P1 ×3 interleaved + K1 microbench;
   decision rules as written (D1 must be bit-identical; D2 ≤+3 % or stop; P1's prefetch-collapse
   guard).
10. Ship order: PR#1 = Stage B alone (fmt-7 rows + tests, "when wanted" slice); PR#2 = Stage A
    re-land (opt-in wiring, alignment story); Stage C lands only if P1 clears its falsifier.
