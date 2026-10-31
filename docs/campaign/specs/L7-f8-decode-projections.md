# L7 — mm8/F8-class decode projections (implementation-ready spec)

Lane: spec-L7 of the manager-run parity campaign (2026-10-23). Read-only design; no arms were run for this document.
Port anchors: `port/up-2276` @ **3064378e** (read via `git -C /root/Projects/colibri-upstream show 3064378e:<path>`; line numbers below are that ref's).
Fork anchors: `/root/Projects/colibri-ds4-vulkan` @ **d11fba5b** (= tag `port-source-2026-10-19`).
Evidence docs: `/root/bench-worktrees/up2276-merge/docs/` (read-only worktree; docs stable).
Ranked item: HANDOVER-2026-10-22.md §6.1 (line 90) — "#1 remaining decode item… Est: decode 0.65 → ~0.9–1.0. Parity-class: write the F8 envelope language first; opt-in."

---

## 0. STOP-FINDINGS — the premise as handed down is partly wrong; read before spending anything

The lane was commissioned as "port the fork's mm8 4.73× win to decode". Four findings correct that framing. **The lane is still worth doing** (a real, code-anchored kernel gap exists, §4), but its expected effect size is *unmeasured*, and no fork kernel can be copied for the win.

**SF-1. The fork's decode never ran mm8, and the 4.73× is an S=128 prefill number.**
- mm8 refuses S<2 in the fork twice: `ds4vk_mm8_dispatch` `if (!pipe || !G.plyt_mm8 || S < 2 || groups < 1) return 0;` (fork `c/backend_vulkan.c:1104`) and the decode-side comment "the deployed decode kernel — mm8 requires S>=2" (`c/backend_vulkan.c:13730`, the `ds4vk_record_fmt8_s1` prologue). The port's landed mm8 has the identical gate: `if (ti->fmt == 12 && S >= 2 && …)` (`c/vk_chain.c:1496` @ 3064378e, landed `cc66bf61`).
- The fork's own commit message for the 4.73×-class kernel states the measurement condition: "the four attention-projection GEMMs … ran the token-major qmatmul.comp fmt=8 **at S=128**, re-reading each weight matrix once per token (4.1 GiB of weight traffic per wq_b/wo_b dispatch) and sitting at ~151 GMAC/s = ~8% of the IC roofline" (fork commit `232c3d5`, 2026-09-18; follow-up `79faf62`). The mechanism of the 4.73× is *weight re-use across tokens*; at S=1 there is exactly one token, so **that mechanism does not exist at decode**.
- Where the fork's decode actually gets projection throughput: the legacy S=1 fmt-8 GEMV, folded into fewer submits — `ds4vk_record_fmt8_s1` (`backend_vulkan.c:13726-13740`) inside dec2 (`ds4vk_dec2_qkv_impl`, `:15682`; block comment "PLAN_decode_gpu_residency slice 3a: the fused DECODE dense chain", `:13715+`), whose shaders state the body is "**VERBATIM qmatmul.spv's fmt=8 S=1 branch** — each row is bit-identical to the per-op GEMV" (`c/shaders/dec_qa.comp:8-11`; same claim `dec_rows.comp:13-14`). The wo_a chain at tokens==1 collapses 9 dispatches to one via `qmatmul_s1g.spv` (`backend_vulkan.c:15258-15290`, env `COLI_DSV4_VK_WO_S1G`, default on, `:1653`) — **bitwise, and measured GPU-time-neutral** (B-fork-inventory.md:116 "WO_S1G (GPU time neutral)").
- Net: the fork's decode advantage over the port is the expert fold (1.84×, `DSV4_VK_EXPERTS=0` arm, O-day2 §10), not projection kernels; the fork-minus-fold decode (0.61–0.63) sits *at* the port's 0.654 (O-day2 §6). The fork's own S=1 submit/glue folds around the GEMV measured wash-or-negative (C-perf-evidence.md §3; dec2 itself +4.12%, mHC fusion +19% — both already realised in the port's chain, P-dossier §3.3).

**SF-2. The port's decode projections are already F8 — weights *and* activations. "f32-GEMV" names the kernel/accumulator, not the weights.**
- The chain's matrices upload as "fp8 as fmt 12, bf16 as fmt 11" (bench/up2276/decode-prof.log:35; 897 matrices, 6480.1 MiB, 43 layers / 41 compressing / 21 indexing, `:15`). Every fp8 matrix's input is rounded to E4M3 per 128 exactly where the CPU rounds it (`v4c_e4m3`, `c/deepseek_v4_chain.h:932-936`; header contract lines 15-18).
- What is actually missing: at S=1, fmt 12 falls through to the **generic** `qmatmul.spv` GEMV. In `matmul_aligned` the vectorized decode-GEMV family is gated by `per = fmt==1 ? 16 : fmt==4 ? 32 : fmt==11||fmt==14 ? 8 : fmt==10 ? 4 : 0` (`c/vk_chain.c:1485`) — **fmt 12/13 are absent**, so `v4 = … && per && …` is false (`:1487`), `g2` needs `fmt == 1` (`:1511`), the tiled GEMM needs S≥2, and the call lands on `record(KC.pipe[P_GEMV], …, (ti->O + 7) / 8, S, 1)` (`:1559`) — `qmatmul.comp`'s one-word-per-lane path with per-element bounds checks, the exact path `chain_gemv.comp`'s header was written to replace ("qmatmul.comp reads one 32-bit word per lane per step and checks every element against I; … short of loads in flight and long on instructions", `c/shaders/chain_gemv.comp:10-13`). DeepSeek V4 is the one engine whose whole dense trunk is fmt 12 — so **the tuned decode GEMV never runs for this model**.

**SF-3. The "760 f32-GEMV matmuls" count and the "1.6 s/token of device wait" attribution are both softer than the handover line suggests.**
- 760 = 6083 chain matmuls ÷ 8 reported forwards (decode-prof.log:32). Direct enumeration of the recorders gives, per decode token: **553 `vkc_matmul` dispatches** (mHC mixes fna/fnf 2×43; wq_a/wq_b/wkv/wo_b 4×43; shared sh1/sh3/sh2 3×43; compressor cwkv/cwg 2×41; indexer iwkv/iwg/iwq/iwp 4×21 — call sites listed in §4.3) **plus 344 `vkc_mla_hgemv` wo_a-group dispatches** (8/layer, `deepseek_v4_chain.h:1063-1065`) = 897 GEMV-class dispatches/token, matching the 897 device matrices exactly. The 760 number and the enumeration differ by bookkeeping (forward counting vs op counting), not by an order of magnitude — both are "several hundred S=1 GEMVs per token".
- The 1.6 s/token device wait (12924.4 ms ÷ 8, decode-prof.log:32) has **no per-op attribution on the port**: P-optionB-dossier-2026-10-22.md:519-521 open-question 4 says exactly this ("the port has … no per-op table like the fork's. Needed before any decode claim", citing O-day2 §6). The whole 0.65→0.9–1.0 estimate assumes a large share of that wait is the fmt-12 GEMV bucket; **that assumption is testable in one command** (§7 Step 0) and must gate the build.

**SF-4. There is no int8-activation path to port.** The fork's activation envelope is E4M3-per-128 dynamic QDQ (quantize→dequantize, UE8M0 block scale computed per token per block at runtime — `c/shaders/qdq.comp:1-20`, "a bitwise replica of the CPU reference `coli_fp8_activation_qdq_ref`"), consumed by mm8 as f32 (`qmatmul_mm8.comp:52-56`, X `[S][I] fp32`). "int8-activation" in HANDOVER §6.1 / O-day2 §6 is loose language for "quantized-activation". The port already performs the identical rounding (`vkc_dsv4_round` VKC_DS_E4M3 via `v4c_e4m3`). A *true* int8 activation would change the model's arithmetic contract (CPU-kernel parity) — a different, larger parity class, **out of scope for L7** and not demanded by any fork evidence.

**Bottom line:** L7 restated correctly = *"give the fmt-12 (fp8) class the port's tuned S=1 decode GEMV (`chain_gemv.comp`), which currently excludes it, behind an opt-in knob, after a one-command attribution check that the fmt-12 GEMV bucket is actually a large share of the decode device wait."* The fork contributes the *numerics template* (bitwise-preserving S=1 shader discipline, arithmetic e4m3 decode) and the *occupancy lesson* (dec-qkv v1→v2: "65 workgroups cannot hide VRAM latency", `dec_rows.comp:15-17`), not a portable kernel or a transferable 4.73×.

---

## 1. The measured starting point (what any L7 claim must beat)

All from this rig, RX 6900 XT (RADV NAVI21), DeepSeek-V4-Flash, 2,515-token prompt / 8–64 tokens:

| fact | value | source |
|---|---|---|
| port decode, decode-critical config (pool 8 GiB + PROMOTE=32) | **0.654 tok/s** | O-day2 §6 table |
| same arm, chain device wait | **12924.4 ms / 8 forwards = 1.615 s/token** | decode-prof.log:32 |
| chain matmuls reported | 6083 over the window (⇒ the "760/token") | decode-prof.log:32 |
| dense matrices on device | 897 (6480.1 MiB): fmt 12 fp8 + fmt 11 bf16 | decode-prof.log:15,35 |
| per-token GEMV-class dispatches (enumerated) | 553 `vkc_matmul` + 344 wo_a `vkc_mla_hgemv` = 897 | §4.3 seam list |
| fork decode, fold ON / fold OFF | 1.162/1.155 vs 0.630/0.610 | O-day2 §10 |
| mm8 (S≥2, prefill) on the port | TTFT 257.7/261.6 → 229.5/239.8 s; decode unchanged 0.586–0.612 | ENVIRONMENT.md `COLI_VK_MM8` row @ 3064378e |
| mm8 microbench S=128 | 2,107–4,183 GMAC/s vs GEMV 185–241 | same row; `docs/experiments/mm8-2026-10-22/` |
| ideal floor for the dense read | ~6.2 GiB of fmt-12 weights/token ⇒ **~15–19 ms at 350–450 GB/s** | arithmetic from decode-prof.log:15 |

The gap between ~17 ms (bandwidth floor) and 1615 ms (measured wait) is either (a) mostly kernel inefficiency on the fmt-12 class — then L7 has a very large ceiling, far above the handover's 0.9–1.0; or (b) mostly elsewhere (attention/mHC/round/copy ops, launch gaps, small-O underfill, host sync) — then L7 is a dud. **Nobody has measured which.** Step 0 (§7) is therefore the first deliverable of the build, not an optional extra.

---

## 2. The F8 envelope language (deliverable 1)

### 2.1 The reusable statement (house law, PORT_PLAN F8 + C-perf-evidence §4)

> **F8 envelope (numerical contract language).** The Vulkan paths are **thresholded, not bitwise**, against the CPU: the terms of every sum are identical and exact (E4M3-grid activations rounded per 128 where the CPU rounds them; e4m3 weights; UE8M0 power-of-two group scales whose fold is exact), but the *order of summation* is the device's. A kernel change that keeps the terms and changes only the association is a **reassociation-class change**: run-to-run byte-identical, never bitwise vs the incumbent, bounded by a *measured envelope* against an fp64/e4m3 reference over the real shapes and the production data class. Greedy generation under such a change diverges on borderline logits with a prompt- and build-dependent envelope (measured flips at token 1…28 across prompt classes; C-perf-evidence §4); tool/agent classes have held 64 tokens. Therefore: (i) never claim "token-for-token identical" without naming the envelope; (ii) the default must be byte-identical (knob off = today's bits, every prefix-resume check and verify row unchanged); (iii) the opt-in arm's evidence = envelope microbench + run-to-run determinism + the engine's token-exact tiny oracle + (before the knob becomes deployment-reachable) the real-checkpoint golden leg.

PORT_PLAN F8 (line 215): "Numerical contract language: greedy output is expert-history dependent; the tier is thresholded, not bitwise; the envelope is prompt- and build-dependent. Never claim 'token-for-token identical' without the envelope."

### 2.2 What "activation-quantization envelope" means for the S=1 GEMV — concretely

- **Granularity (already fixed by the CPU contract — L7 changes nothing here):** per **token**, per **128-input block**, a **dynamic** scale: `max|x_block|` floored at 1e-4 → UE8M0 exponent `e = clamp(ceil_log2(max/448), -127, 127)` → every element encode/decode on the E4M3-FN grid (fork `qdq.comp:3-8`; port `vkc_dsv4_round` VKC_DS_E4M3 called by `v4c_e4m3`, `deepseek_v4_chain.h:932-936`). **No per-channel weight-side change, no calibration set, no offline pass** — the envelope is computed at runtime, per token, exactly as the CPU kernel does. Weight side stays fmt 12: e4m3 weights, one f32 (UE8M0-derived) scale per row per 128-input group.
- **What the L7 kernel may and may not change:** it may change how the *already-rounded* x is read (16-byte vector loads, LDS staging), how rows map to lanes/subgroups (`lpr`), and how partials associate (per-step partial × group scale vs per-word). It may **not** change the terms: no re-quantization of x, no folding of non-power-of-two scales, no bf16 rounding sites moved.
- **Numerics class of the recommended kernel (§4):** reassociation (chain_gemv's four parallel partials `a0..a3` vs qmatmul's per-word `a`). Identical terms ⇒ envelope of the same nature as mm8's landed one: mm8 measured ≤ 2.6e-6 vs the fp64/e4m3 reference over six real shapes × S 2–128, with the GEMV's own at 7e-8…1.7e-7 (ENVIRONMENT.md `COLI_VK_MM8` row; commit `cc66bf61`). L7 must measure its own envelope at S 1–4 (§6).
- **The alternative class — bitwise — is available but costs the design:** the fork's S=1 shaders stayed bitwise by keeping qmatmul.spv's exact lane→word assignment and per-word partial (dec_qa.comp:8-11, qmatmul_s1g.comp:13-22, qmatmul_s1_fp4.comp:18-22). If review prefers bitwise over the tuned shape, the kernel must replicate `wi = lane; wi += sgsize`, the within-word k order, and the per-word `(x·e4m3)·scale` partial — forfeiting the 16-byte-step structure that is the point of `chain_gemv.comp`. **Recommendation: take the reassociation class + measured envelope (mm8 precedent); the bitwise variant is the fallback if the envelope gate fails.**

### 2.3 The env knobs (COLI_VK_* family, house grammar: default byte-identical, refusal falls through)

| knob | default | meaning |
|---|---|---|
| `COLI_VK_CHAIN_GEMV8` | `0` | `0`: every fmt-12/13 matmul at S ≤ 4 stays on `qmatmul.comp`'s GEMV — today's bits, what `COLI_VK_CHAIN_GEMV=0` already documents for the other formats. `1`: every *eligible* fmt-12/13 matmul with S ≤ 4 takes `chain_gemv.comp`'s vectorized GEMV (fmt 12/13 arm) — a **reassociation-class** break, the same class and knob grammar as `COLI_VK_MM8=1`. Eligibility: `rowWords % 4 == 0`, `I % 4 == 0`, `gs % 16 == 0` (a 16-value step never straddles a scale group), staging fits `XS` or the `XG` variant takes it. A refusal (no pipeline, unaligned, past staging without XG) falls through to the same paths as `0`, exactly mm8's refusal grammar (`cc66bf61`). |
| (existing, untouched) `COLI_VK_CHAIN_GEMV` | on | the shader family's master switch (`vk_chain.c:534`); `GEMV8=1` with `GEMV=0` is a no-op — document in the row. |
| (existing, untouched) `COLI_VK_CHAIN_GEMV_NR` | on | verify rows sharing weight loads keep a decode row's bits *within the new class* (chain_gemv.comp:30-37 guarantees per-row op order under NR) — the class differs from qmatmul's, which is the documented break. |

Naming note: `GEMV8` reads "the fp8 formats join the GEMV family" beside `COLI_VK_CHAIN_GEMV2`; if review prefers explicitness, `COLI_VK_CHAIN_GEMV_FP8` — one spelling, decide at review, do not ship both.

Interaction with mm8 (must be pinned in code and test): mm8's gate runs first (`vk_chain.c:1496`, S ≥ 2); `GEMV8` takes only what mm8 declined, so with `COLI_VK_MM8=1` a 2–4-row verify takes mm8 and with mm8 off it takes GEMV8 — never both, never neither-when-eligible. Prompt rows S ≥ 5 are out of scope (tiled GEMM / mm8 territory).

---

## 3. Where the fork's decode projection throughput actually comes from (the trace demanded by the brief)

1. **The GEMV itself**: the legacy token-major fmt-8 S=1 dispatch, `ds4vk_record_fmt8_s1` (fork `backend_vulkan.c:13726-13740`) — `qmatmul.spv`'s fmt=8 S=1 branch, a subgroup per row. **Same per-MAC work as the port's `qmatmul.comp`**; no throughput edge.
2. **Submit folding** (host-side win, already matched by the port's per-layer frames): dec2 = wq_a(QDQ)+q_norm+rope+wq_b+wkv in ONE submit (`ds4vk_dec2_qkv_impl` `:15682`, shaders `dec_qa/dec_rows/dec_fin.comp`); the attention segment joins wo_a/wo_b/mHC (`ds4vk_wo_record` `:15035`, `:15420`); the FFN opener joins shared-expert + route gate (`deepseek_v4.c:21404+`). Fork's own measurements: dec2 +4.12%, the other folds neutral-to-negative (C-perf-evidence §3); the port's chain already records a layer's dense half in one frame (A1 submit `deepseek_v4_chain.h:1297`, A2 `:1310`).
3. **Dispatch-count collapse at S=1**: `qmatmul_s1g.spv` (wo_a's 8 groups + gather → ONE dispatch, bitwise, `backend_vulkan.c:15258-15290`) — measured **GPU-time neutral** (B-fork-inventory:116). Port equivalent today: 8 `vkc_mla_hgemv` calls/layer (`deepseek_v4_chain.h:1063-1065`) — parity of class, nothing to gain per the fork's own record.
4. **The expert half** (where the 1.84× lives): eg2 bank + `qmatmul_s1_fp4.spv` (S=1 fp4 expert GEMV, `backend_vulkan.c:702-709` block, `:10779`) — MoE-side, **not** the dense projections; covered by lanes L1–L3 of the dossier, not L7.
5. **mm8**: prefill only (SF-1).

Conclusion: the fork has **no S=1 fp8 projection kernel faster per-MAC than the port's current path**. L7's win, if any, comes from the port's *own* tuned-GEMV design (16B steps, LDS-staged x, `lpr` occupancy shaping, NR row-sharing, no bounds checks — `chain_gemv.comp:1-37`) being extended to the format that happens to be this engine's entire dense trunk.

---

## 4. Kernel design + reuse audit (deliverable 2: the seams)

### 4.1 Reuse audit — what exists, what is new

| candidate | verdict |
|---|---|
| port `chain_gemv.comp` (VKC_P_GEMV4, `vk_chain.c:538-556`) | **the vehicle** — extend with a fmt-12/13 arm. Already has: uvec4 (16 B) loads/lane/step, LDS x staging with bank pad (`xi()`), `lpr` lanes-per-row incl. `lpr=0` for few-long-rows, `XG` variant for rows past staging, `NR` 1/4 pipelines whose per-row op order preserves a decode row's bits within the class, zero bounds checks (host-gated alignment). Missing only: fmt 12/13 decode in `rowpart()` and the host `per` entry. |
| port `chain_hgemv.comp` (wo_a groups, fmt-12-capable, `vk_chain.c:2030-2048`) | already serves the 344 wo_a dispatches; **leave alone** unless Step 0 shows the `PK_MLAW` bucket hot (then a Phase-B grouped axis, fork-s1g-style, is a wash per the fork's own record — do not build speculatively). |
| port `qmatmul_mm8.comp` at S=1 | rejected as the primary vehicle: BN ≥ 2 tiles idle ≥ half the N-threads at S=1, and its win mechanism (cross-token weight reuse) is absent; split-K exists for small-O but the GEMV shape is the natural S=1 form. (If review disagrees, an `mm8` S=1 refusal-relaxation is a ~40-line experiment — but it duplicates §4.2 for no mechanism.) |
| fork `qmatmul_s1_fp4.comp` | **not reusable** — fmt 10 (fork's e2m1+packed-E8M0 expert format), not fmt 8/12 dense; its *discipline* is the template (dedicated S=1 form, arithmetic decode, always-LDS x, host refuses I > 6144, bitwise-vs-generic contract). |
| fork `dec_qa/dec_rows/dec_fin.comp` | not the vehicle (submit folds, generic GEMV body, wash class per C-perf-evidence §3); `dec_rows.comp:15-17` is the occupancy evidence. |
| fork `qdq.comp` | not needed — the port's `vkc_dsv4_round` already makes the identical rounding in-frame. |

### 4.2 The change, concretely (Phase A)

1. **`c/shaders/chain_gemv.comp`** — add fmt 12 (and 13 while there) to `rowpart()`: per 16-value step, load `uvec4` (4 words = 16 e4m3 values), decode each with the arithmetic e4m3 (copy `qmatmul.comp:57-64`'s `e4m3()` verbatim — the LUT form is deliberately rejected, `qdq.comp:33-37` documents the ~1.5 GB/s gather collapse of the glslang lowering (a dynamically-indexed constant array copied to scratch + a gathered load per decode; the driver is unnamed there)), accumulate into the four side-by-side partials, multiply the step's partial by the one group scale `scale[o*ng + (16·q)/gs]` (a 16-aligned step never straddles a 128- or 32-group; gate `gs % 16 == 0` on the host). ~50–70 GLSL lines mirroring the fmt-1 branch.
2. **`c/vk_chain.c` `matmul_aligned`** — `per` table: `fmt == 12 || fmt == 13 ? 16` (`:1485`); the `v4` gate then admits fmt 12/13 for `path < 0` (decode/verify rows) exactly as fmt 1 today (`:1487`); knob gate `gemv8_mode()` wraps the fmt-12/13 admission (default refuse); engagement counter `KC.st.gemv8++` beside `KC.st.gemv_xg` (`:1547`), printed in the chain report (`deepseek_v4_chain.h:1490`) — the G17 "gate on engagement counters" discipline. ~15–25 lines.
3. **No new pipeline objects** — the four existing chain_gemv pipelines (`gemv4/gemv4x/gemv4n/gemv4xn`, `vk_chain.c:544-551`) serve the new format arm; no Makefile change (same `.comp` → `.spv`).

### 4.3 Seam list at 3064378e (file : function : line)

**Port (all `git show 3064378e:<path>`):**

| seam | anchor | role |
|---|---|---|
| the generic-GEMV fallback L7 replaces | `c/vk_chain.c:1559` (`matmul_aligned` final else, `P_GEMV` grid `(O+7)/8 × S`) | today's decode dispatch for fmt 12 |
| the `per`/`v4` gates to extend | `c/vk_chain.c:1485-1488` | format admission for the vectorized GEMV |
| mm8's gate (ordering interplay) | `c/vk_chain.c:1496-1500` | S ≥ 2, runs first; `PK_MM8` kind at `:1497` |
| pipeline creation + `COLI_VK_CHAIN_GEMV` | `c/vk_chain.c:532-556` | the four NR/XG variants, XS staging sizing |
| `vkc_gemm_rows` pin (verify rows = decode bits) | `c/deepseek_v4_chain.h:1204` (`vkc_gemm_rows(prompt ? gemm_rows : 0)`) | the rows policy L7 must respect |
| the activation rounding sites (inputs, unchanged) | `c/deepseek_v4_chain.h:932-936` (`v4c_e4m3`) | E4M3-per-128, the CPU contract |
| per-token matmul call sites (the 553) | `c/deepseek_v4_chain.h:953` (mHC `fn`), `:979` (compressor `wkv`/`wg`), `:996-999` (`wq_a`), `:1014` (`iwq`), `:1018` (`iwp`), `:1030` (`wq_b`), `:1035` (`wkv`), `:1067-1068` (`wo_b`), `:1075-1077` (`sh1/sh3/sh2`) | the op classes the brief asked to enumerate |
| wo_a groups (the 344, separate op) | `c/deepseek_v4_chain.h:1063-1065` (`vkc_mla_hgemv` loop, `og > 1`) → `c/vk_chain.c:2030-2048` | Phase-B-only territory |
| the kernel to extend | `c/shaders/chain_gemv.comp:1-37` (contract), `rowpart()` `:72+`; e4m3 arithmetic decode to copy: `c/shaders/qmatmul.comp:57-64`, fmt-12 reference branch `:117-133` | |
| stats + report | `c/vk_chain.h:839-854` (`VkcStats`), `c/deepseek_v4_chain.h:1490` (chain report line) | engagement counter |
| attribution tooling (exists, no edit) | `COLI_VK_CHAIN_PROF=2` → `c/vk_chain.c:686-700` (query pools), `:3266-3282` (`vkc_prof_print`, per-(fmt,S,O,I) matmul ms); `COLI_VK_CHAIN_BENCH=mm8` + `COLI_VK_BENCH_S=1` → `c/tests/test_vk_chain.c:3230+` (six real fmt-12 shapes, GEMV line printed with the knob off); `COLI_VK_CHAIN_BENCH=1` GEMV bench `:2859+` (needs a 2-line fmt-12/gs extension of `bench_gemv`) | Step 0 |
| tests to model on | `c/tests/test_vk_chain.c:2957-3080` (`test_mm8_case` / `_tiles` / `_refusals`: fp64/e4m3 ref, distinct scales, determinism, dispatch counting, refusal fallback) | the L7 gate suite |
| docs row to add | `docs/ENVIRONMENT.md` beside `COLI_VK_MM8` (row 232 @ 3064378e) | house clause order |

**Fork (d11fba5b), for the numerics/occupancy precedents:** `backend_vulkan.c:1104` (S<2 refusal), `:13715-13740` (dec2 block + `ds4vk_record_fmt8_s1`), `:15258-15290` (s1g), `:15682` (dec2 impl), `:1653` (`ds4vk_wo_s1g_wanted`); `c/shaders/dec_qa.comp:8-13`, `dec_rows.comp:13-17`, `qmatmul_s1g.comp:13-22`, `qmatmul_s1_fp4.comp:18-22`, `qdq.comp:1-20`, `qmatmul_mm8.comp:24-56`.

---

## 5. Numerics gate plan (deliverable 3)

Layered, exactly the mm8 landing's shape (`cc66bf61` + `7bbad9e2`; all gates green at `d1a2abba`, PORT_STATUS §"the regression the gates caught"):

1. **Op-level envelope (new test, `c/tests/test_vk_chain.c`)** — `test_gemv8_case(O, I, S∈{1,2,4}, distinct scales)`: upload fmt 12 (gs 128) with e4m3-grid x, e4m3 weights, power-of-two scales (reuse `e4m3_val`/`e4m3_rnd`, `:2968-2979`); compute the fp64/e4m3 reference; run knob-off (qmatmul GEMV), knob-on twice (determinism), assert: ok flags, `VkcStats.gemv8` counts the dispatch (engagement, never vacuous), envelope vs reference under a measured tolerance (mm8's `1e-4` cap held; expect ≤ ~1e-5 class — *measure, then pin*), and print (never gate) GEMV8-vs-GEMV. Shapes: the six real ones (`3230`'s table) at S 1–4 **plus** one unaligned/refusing shape (`I % 4 != 0`, `gs % 16 != 0`) asserting the fall-through.
2. **Verify-rows equality within the class** — extend `test_verify_rows` (`:2910+`) to fmt 12: each row of an S=2..4 call must equal the same row through S=1 *on the new kernel* (the NR contract, chain_gemv.comp:30-37).
3. **Tiny oracle (existing gate, must stay green)** — `deepseek-v4-tiny-check` is **token-exact** teacher-forcing + greedy vs the CPU-generated oracle (`tests/test_deepseek_v4_tiny.py:60-78`). The knob off must be *bit*-identical (no dispatch counted); the knob on must still pass token-exact on the tiny fixture — this is the engine-level thresholded-oracle leg (the tiny model is well-conditioned; it proves the class, not the envelope).
4. **Standard chain gates** — `vk-chain-check`, `vk-tier-check`, `vk-strict-check` (unchanged expectations with the knob off; the knob on adds only the new suite).
5. **The 4.1 h `.golden` leg — when required:** *not* to land (default 0 is byte-identical; every existing gate and prefix-resume check is untouched — the mm8 precedent landed exactly so). It **is** required before the knob becomes deployment-reachable: entering a `COLI_VK_PROFILE=RDNA2` set, or any doc presenting it as a recommended config — i.e. G2 "real checkpoint greedy at 8/28/64 tokens within the recorded envelope" + the real-checkpoint golden parity leg (PORT_PLAN §7 G2, F10's ≈4.1 h re-record). Until then the arm's engine-level evidence is the tiny oracle + the envelope microbench, with the envelope stated per F8.

---

## 6. LOC estimate + risks (deliverable 4)

| item | LOC |
|---|---|
| `chain_gemv.comp` fmt-12/13 arm | 50–70 |
| `vk_chain.c` (per entry, knob, counter, report, refusal) | 15–25 |
| `test_vk_chain.c` (gemv8 case + verify-rows ext. + refusals + bench_gemv fmt-12 lines) | 130–190 |
| `docs/ENVIRONMENT.md` row + `deepseek_v4_chain.h` report word | 3–5 |
| **Phase A total** | **~200–290** |
| Phase B (only if Step 0 shows `PK_MLAW` hot): grouped wo_a single dispatch | +200–300 (new shader or hgemv group axis) — *do not build speculatively; the fork measured this class neutral* |

**Risks:**
- **R1 — attribution risk (the big one):** if the fmt-12 GEMV bucket is a minor share of the 1.6 s/token wait, Phase A moves nothing end-to-end. *Mitigation: Step 0 gates the build; falsification thresholds in §7.*
- **R2 — numerics:** the reassociation envelope must be measured, not assumed (RNI/FMA contraction is codegen-sensitive, C-perf-evidence §4(c)); a failed envelope gate falls back to the bitwise variant (§2.2), costing the 16B-step design and most of the expected win.
- **R3 — envelope *build* cost per token: none.** The activation quantization already runs (`v4c_e4m3` per 128, dynamic per token per block, in-frame); the kernel consumes the rounded x. No new pass, no calibration, no scale buffer. (Stated because the brief asked; the only added per-token work is the same scales read 1/4 as often.)
- **R4 — `COLI_VK_PROFILE=RDNA2` interaction:** the profile *fills unset variables only* (ENVIRONMENT.md row 251), so arms compose (`profile` + explicit `COLI_VK_CHAIN_GEMV8=1`); but the decode/ttft/balanced sets must **not** gain the knob until the arm measures a win and the golden leg (§5.5) is done — otherwise the profile silently exports an unproven parity-class break. Conversely `COLI_VK_CHAIN_GEMV=0` (family master off) must silently neutralise `GEMV8` — pin in the test.
- **R5 — stream-bypass arm interaction:** `COLI_VK_TIER_STREAM_BYPASS=1` (ENVIRONMENT.md row 282) changes *which cache sees prefill stream bytes*; it is bit-identical and prefill-side, so it does not confound a decode L7 arm — but the campaign discipline says hold it fixed across arms (it alters store counters the tier report prints, keeping logs comparable).
- **R6 — cross-engine:** `chain_gemv.comp` is shared by every chain engine; the fmt-12/13 arm is dead code for engines without fmt-12 tensors, but the `per`-table edit touches the shared admission path — run `tests/vulkan_engines.sh deepseek` + one non-DSV4 family (G3), as mm8 did.
- **R7 — mid-merge lane hazard:** this spec's anchors are pinned to 3064378e; re-verify the five `vk_chain.c` seam line numbers on the merge head before editing (the port tree is being merged in another lane).

---

## 7. Arm design (deliverable 5 — DESIGN ONLY; nothing was run for this spec)

**Step 0 — attribution (commands exist today; run first, ~10 min, no code):**
```
COLI_VK_CHAIN_PROF=2 <engine> <model> "<2,515-tok prompt>" --max-tokens 8   # per-(fmt,S,O,I) matmul ms, costliest first (vk_chain.c:3266-3282)
COLI_VK_CHAIN_BENCH=mm8 COLI_VK_BENCH_S=1 <test_vk_chain bench entry>       # the six real fmt-12 shapes at S=1, GEMV line = today's kernel (test_vk_chain.c:3230+)
```
Read: (a) the share of decode device time in `GEMV other` at fmt 12 vs attention/mhc/norm/rope/copy buckets; (b) per-shape µs vs the ~17 ms/token bandwidth floor.
**Go/no-go:** build only if fmt-12 GEMV ≥ ~25% of the decode-window device time AND ≥ one big shape sits ≥ 3× off the floor. Record the numbers either way (a negative Step 0 closes L7 honestly and re-ranks the campaign).

**Step 1 — microbench A/B (after Phase A):** `COLI_VK_CHAIN_BENCH=mm8 COLI_VK_BENCH_S={1,2,4}` with `COLI_VK_CHAIN_GEMV8={0,1}`: GB/s of weights per shape. Expect the chain_gemv header's class (its record on an RTX PRO 4000, `chain_gemv.comp:26-27`: int4 146→190 GB/s, int8 314→370; `few`/`lpr=0` exists precisely for the wkv-like small-O shapes the fork's v1 lost 2.2 ms/layer on).

**Step 2 — engine arm (the deliverable's A/B):**
- Runner: `/root/bench-colibri/run-arm2276.sh <c-dir> <tag> [ENV=…]`, `RAM_GB=28`, machine otherwise idle (HANDOVER §7).
- Base (decode-critical, held fixed): `COLI_VK_PROFILE=RDNA2` decode set — i.e. `COLI_VK_MM8=1 COLI_VK_TIER_HOST_GB=8 COLI_VK_TIER_PROMOTE=32` (row 251; explicit env wins over the profile, so add only the L7 knob beside it).
- Arms: (A) base; (B) base + `COLI_VK_CHAIN_GEMV8=1`. **×3 interleaved reps**, medians; 2,515-token prompt / 64 tokens (the campaign's standing shape).
- Controls: `vram0` floor guard clean; engagement counter `gemv8` > 0 in every B log (G17 — an arm with 0 engagements is a vacuous pass); chain report's matmul/wait lines and `COLI_VK_CHAIN_PROF=2` on one B rep for the bucket-shift evidence; store counters comparable (hold `COLI_VK_TIER_STREAM_BYPASS` fixed across arms, R5).
- **Expected effect size:** honest bound, not the handover's — if Step 0 says the fmt-12 bucket is X ms/token and the microbench says the new kernel is k× faster on it, the predicted decode-wall delta is ≈ X·(1−1/k) · (overlap factor ≤ 1). The handover's 0.65→0.9–1.0 corresponds to removing ~0.35–0.55 s/token — plausible only at the high end of Step-0 attributions; state the prediction *before* the run (pre-registered, the S7 campaign's own discipline).
- **Falsification criteria (write these in the arm log):** (i) Step-0 gate fails → lane closed, negative recorded; (ii) microbench speedup < 1.3× on every big shape → kernel not the issue, stop; (iii) engine decode delta < +5% median (inside the campaign's noise band, G4's −5% floor is a *regression* gate, not a win gate) → record neutral-negative and do not add the knob to any profile set; (iv) tiny-check token-exactness fails with the knob on → numerics bug, fix before any arm is believed.

---

## 8. Implementation checklist (10 lines, executable without re-derivation)

1. Run Step 0 (`COLI_VK_CHAIN_PROF=2` decode window; `COLI_VK_CHAIN_BENCH=mm8 COLI_VK_BENCH_S=1`); record fmt-12 share + per-shape µs; apply the ≥25% / ≥3× go/no-go. A no closes the lane with a documented negative.
2. On the merge head, re-verify the seams (`vk_chain.c` `per`/`v4`/mm8-gate/P_GEMV-fallback; `chain_gemv.comp` `rowpart()`), then extend `rowpart()` with the fmt-12/13 arm: uvec4 step → 16 arithmetic-e4m3 decodes (`qmatmul.comp:57-64` verbatim) → four partials × one group scale (`gs % 16 == 0` host-gated).
3. `vk_chain.c`: add `per` entries (12/13 → 16), the `COLI_VK_CHAIN_GEMV8` lazy knob (default 0 refuses; 1 admits; `COLI_VK_CHAIN_GEMV=0` neutralises), `KC.st.gemv8` counter + chain-report word; mm8's S≥2 gate stays first.
4. Write `test_gemv8_case` (+ verify-rows fmt-12 extension, + refusal cases) modeled on `test_mm8_case` (`test_vk_chain.c:2957-3080`); measure and pin the envelope tolerance; assert engagement counts and determinism.
5. Extend `bench_gemv` (`test_vk_chain.c:2859+`) to fmt 12 (gs 128) so `COLI_VK_CHAIN_BENCH=1` covers it.
6. Gates: `make -f Makefile VK=1 ARCH=native -j16 vk-chain-check vk-tier-check vk-strict-check`; `deepseek-v4-tiny-check` (knob off bit-identical, knob on token-exact); `tests/vulkan_engines.sh deepseek` + one non-DSV4 family; rebuild `deepseek_v4` before any arm.
7. Add the `COLI_VK_CHAIN_GEMV8` ENVIRONMENT.md row beside `COLI_VK_MM8` in the house clause order (default-cell; what runs where; the reassociation class + measured envelope; what 0 preserves; refusal grammar; Step-0/microbench/arm numbers with their log paths).
8. Microbench A/B (`COLI_VK_CHAIN_BENCH=mm8`, `COLI_VK_BENCH_S={1,2,4}`, knob 0 vs 1); then the engine arm: base = RDNA2-decode set (`MM8=1 HOST_GB=8 PROMOTE=32`, RAM_GB=28) vs base+`GEMV8=1`, ×3 interleaved, medians, engagement counter checked > 0 in every B log.
9. Apply the falsification rules (§7); on a win ≥ +5% decode median, schedule the 4.1 h `.golden` leg + real-checkpoint greedy (8/28/64) **before** adding the knob to any `COLI_VK_PROFILE` set; on anything less, record the negative and leave the knob default-0.
10. Update HANDOVER §6.1 / the campaign ledger with the measured attribution (the 760/897 and 1.6 s/token figures corrected by the Step-0 profile), so no later lane inherits the 4.73×-at-decode reading.

---

## 9. Step-0 results — NO-GO, the lane closes on the pre-registered rule (2026-10-23, lane impl-L7A)

Run on the gemv8 worktree head `707cf2e3` (= `port/up-2276` @ `3064378e` + the 176-commit upstream merge; `vk-chain-check`/`vk-tier-check` PASS at the head before any edit). Rig: the campaign's RX 6900 XT (RADV NAVI21), VRAM at the ~541 MiB idle floor before each leg. Config: the decode-critical set `COLI_VK_MM8=1 COLI_VK_TIER_HOST_GB=8 COLI_VK_TIER_PROMOTE=32` + the runner's standing env (`COLI_TEMP=0 KVSAVE=0 V4_PREFIX_CKPT=0 COLI_VULKAN=1 COLI_V4_PREWARM=0 OMP=16`), `--memory-gb 28`, the 2,515-token prompt (`bench/prompt_2k.txt` @ `3a193815`, 8,944 B — the file was missing from the tree and recovered from git; the `coli_usage.fixed` snapshot no longer exists, so the legs ran on the model's live `.coli_usage` with `.coli_mfu` restored — the prefill chunking differed between legs because of it; the S=1 rows below are decode-only by construction, so the decode window is unaffected).

**Unit microbench** (`COLI_VK_CHAIN_BENCH=mm8 COLI_VK_BENCH_S=1`; at S=1 GMAC/s ≡ GB/s of weights, 1 B a value):

| shape (O×I) | qmatmul GEMV | vs the tuned floor |
|---|---|---|
| 32768×1024 | 127.5 GB/s | 2.5× off |
| 4096×8192 | 93.8 GB/s | 3.4× off |
| 2048×4096 | 85.1 GB/s | 3.8× off |
| 4096×2048 | 89.7 GB/s | 3.6× off |
| 1024×4096 | 64.8 GB/s | 4.9× off |
| 512×4096 | 32.6 GB/s | 9.8× off (small-O; the tuned GEMV underfills there too — 144.9 GB/s on int8 640×2560) |

Tuned floor measured the same day, same card, the existing bench (`COLI_VK_CHAIN_BENCH=1 COLI_VK_BENCH_FMTS=1`, chain_gemv fmt-1 int8): **315.3 / 325.2 GB/s** on the two big shapes. Criterion (b) **passes**: four big shapes sit ≥ 3.4× off the floor.

**Attribution profile** (`COLI_VK_CHAIN_PROF=2`, `--max-tokens 8` vs `--max-tokens 24`; the decode window is the 16-token difference; logs preserved at `/root/bench-colibri/up2276/gemv8-step0-prof-{8,24}.log`):

| quantity | per decode token |
|---|---|
| decode wall (23 tokens / 40.698 s) | **1,770 ms** (0.565 tok/s) |
| chain device wait (fence waits, `wait_ms` diff) | **438.7 ms** |
| chain device time (PROF timestamps, tier-concurrent) | **242.2 ms** |
| fmt-12 S=1 GEMV bucket (7 shapes, 4.02 GiB/token read at 77 GB/s effective) | **57.3 ms** (46.5 ms on the standalone-bench basis) |
| of the timestamp buckets: mla weights 71.1 / attention 63.8 / **fmt-12 GEMV 57.3** / mhc 36.1 / fmt-11 GEMV ~9 / dsa 6.2 / rope 6.4 / element-wise 4.7 / norm 2.8 | |

**Criterion (a) fails**: the fmt-12 GEMV class holds **13.1 %** of the decode device wait (57.3/438.7) and **23.7 %** of the chain's timestamp device time (57.3/242.2) — below the ≥ 25 % bar on the metric the rule names, and below it on the friendlier metric too. No speculative verifies fired in either leg (no S 2–4 rows anywhere), so the S=1 bucket is the whole class; with `COLI_VK_MM8=1` the verify rows would belong to mm8 anyway, exactly the arm-B world.

**Two corrections to §1's premises, both closing the lane harder:**
- The motivating "1.615 s/token of device wait" was bookkeeping, not decode: `wait_ms` is a whole-run counter and the ÷8 hung prefill's ~11.5 s of wait on 8 tokens. The measured decode-window chain wait is **439 ms/token** — the fmt-12 GEMV is ~57 ms of a 439 ms wait, not a large share of 1,615 ms.
- Even the perfect kernel buys almost nothing end-to-end: 4.02 GiB/token at the 320 GB/s tuned floor is 13.8 ms, so the ceiling is **43.5 ms/token ≈ 2.5 %** of the 1.77 s decode wall — under falsification (iii)'s +5 % engine bar before any noise or overlap, i.e. the pre-registered prediction says a green Phase A could not clear its own win gate.

**Verdict: NO-GO** (rule §7 Step 0: (a) ∧ (b); (a) fails). Phase A is not built; the worktree stays at `707cf2e3`, untouched. The errata of 2026-10-23 (the P-optionB-dossier attribution, the int4/int8 header labels, the RADV hedge) are applied above.

**What the decode effort should pivot to instead** (from these numbers, not from the 4.73×-at-decode reading):
1. **The expert side owns the wall.** 1,770 ms/token of wall against 242 ms of chain device time: ~77 % of the token is the routed-expert path. The tier's own line: `device 20,541 ms, CPU share 123,638 ms, waited 11,942 ms` over the run, and at decode only **20.5 % of routed experts ran on the device** (`decode: 1218 of 5934`). Decode-side expert placement/residency (the S7 store-MFU axis: decode-only history, frozen sections, pin ranking) is where whole seconds per token exist, not fractions.
2. **Pipeline/concurrency gaps, not kernels.** The chain's decode wait (439 ms) is ~1.8× its timestamp device time (242 ms): ~200 ms/token disappears into tier/chain interleaving and fence waits. An arm that overlaps the chain's dense half with the tier's expert half (or batches the fence) has a larger bound than any GEMV rewrite.
3. If a chain-side kernel lane is still wanted, the measured order is **PK_MLAW (71.1 ms/token) > attention-dec (63.8) > fmt-12 GEMV (57.3) > mHC (36.1)** — and the MLAW/Phase-B grouped axis stays pre-judged a wash by the fork's own s1g record (§4.1), so the honest chain-side candidate is the attention/mla-dec buckets, each still ≤ ~4 % of the wall.
