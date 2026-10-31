# CPU parity census — fork `colibri-ds4-vulkan` @ d11fba5b vs port `up2276-merge` @ 0c847722

Lane: audit-cpu (read-only on both repos; no GPU runs). Box: i9-12900K (8P+8E, CPUs 0–15 =
8 P-cores ×2 HT, CPUs 16–23 = 8 E-cores; AVX2 + AVX-VNNI, **no AVX-512** —
`docs/experiments/mm8-2026-10-22/trial-1-raw.txt:1` "[test] CPU: … i9-12900K, 24 threads,
AVX-512 no"; `lscpu` flags confirm). One RX 6900 XT, not touched by this lane.

Arms compared (all from `/root/bench-colibri/up2276/`, all launched by `run-arm2276.sh` via
`chain6.sh`/sibling chains — 2,515-tok code prompt, 64 tokens, greedy, RAM 28 GiB, same
`.coli_usage`/`.coli_mfu` snapshots, ×N interleaved reps):

| arm class | decode tok/s (63/after_first) | experts at decode |
|---|---|---|
| fork full fold (`fork-full-r3/r4`, `fork-r1..r4`, `audit-fork-r1`) | 1.1402–1.2097 (median ≈1.19) | GPU-MFU hits + CPU tail (v5 cache on) |
| **fork fold-free** (`fork-noexperts-r1/r2`, `COLI_DSV4_VK_EXPERTS=0`) | **0.6296 / 0.6104** | **all 258/token on CPU** |
| port standing (`l2-c0-r1..r3`, `new-s256gr4-r2/r3`) | 0.5155–0.5351 | 87.4% on CPU (`l2-c0-r1`: "decode: 2047 of 16254 routed experts on the device (12.6%)") |
| port CPU-class best (`s3-l`, `base-host0`, `mm8-defaults`, `port-rdna2`) | 0.5647–0.5843 | ~80–87% on CPU |
| port host-pool best (`mm8-decode28`, `dmoe-armed`, `dprof-b`) | 0.6579–0.6706 | 77.5% on CPU (`dprof-b`: 22.5%) |

Matched compute location (dense chain on device, routed experts on CPU): fork 0.61–0.63 vs
port 0.55–0.58 → **0.06–0.08 tok/s ≈ 10–15 %**. Headline: 1.19–1.21 vs 0.66–0.67 → **~1.8×**.

---

## 1. Runtime CPU configuration parity

The decisive fact: **the fork's 1.15–1.21 and 0.61–0.63 arms were run by the same rig as the
port arms** (`chain6.sh` → `run-arm2276.sh`, fork binary at `/root/bench-worktrees/fork-ab/c`).
Every CPU-runtime knob below is therefore **identical by construction** in the numbers being
compared. The fork's *own* standing runner (repo root `run_arm.sh`) differs — it never
produced the up2276 records.

| config | fork (campaign arms, `run-arm2276.sh`) | port (same rig) | verdict |
|---|---|---|---|
| OMP_NUM_THREADS | 16 (rig `OMP=16`) | 16 | **match** — both logs print `[OMP] deepseek-v4: effective team size 16` (line 1 of every arm log) |
| OMP_PROC_BIND / OMP_PLACES | `close` / `cores` | `close` / `cores` | **match** |
| taskset/cpuset | none (rig uses none) | none | **match** — the rig's cgroup (`MemoryMax=34G`, swap 2G) is memory-only, no CPU pinning on either side |
| effective placement on this hybrid box | 16 libgomp "core" places = 8 P (1 thread/core, siblings idle) + 8 E (1 each) | same | **match, and a shared inefficiency**: static-scheduled matvec regions finish at E-core pace (~55–65 % of a P-core for this loop class). Equal on both sides → contributes 0 to the parity gap, inflates both absolutes. Never A/B'd on either engine (no E-core-exclusion arm exists in any chain) |
| engine OMP self-tune | `v4_omp_reserve_loader_cpus` (fork `deepseek_v4.c:26949`) — **disabled when OMP_NUM_THREADS is set**, exactly like the port's (`:18751-18753`) | same function, same bail (`:18757`) | **match** — rig env sets OMP_NUM_THREADS, so neither engine shrank its team; both printed team 16 |
| loader lane count (`V4_LOADER_LANES`, disk→RAM read pool) | default **9** (`DUAL_EXPERT_LOADER_DEFAULT_LANES`, `:8604`) | default **9** (`:5116`) | **match** — the dual expert loader + store read concurrency is the same inherited machinery on both (`COLI_V4_EXPERT_LOADER_COUNT` = 3 on both) |
| **decode MoE compute lanes** (`COLI_DSV4_VK_MOE_LANES`, default **6** — fork `cache_engine.h:181-193`) | **fork-full arms: ACTIVE** — pool created at v5-cache boot (`fork-full-r3.log`: `v4_gpu v5-pilot: async lanes=4 max_inflight=12`; pool sized `max(pilot=4, moe=6)=6`, fork `:15863-15876`); miss jobs and warm-pool hits compute **on the lanes** (read+compute / compute-only, fork `:9297-9436`) | **port: does not exist** — no `moe_lanes`/`pilot_pool` in the port tree; design doc `docs/research/I-decode-lanes-design.md` (main clone) was never implemented; the port's CPU experts compute **serially on the engine thread** (`v4_vk_token_finish`, `deepseek_v4.c:5547-5600`) | **NAMED DIFFERENCE (headline arms only)** — see §2/§5. Note: **inactive in the matched arm** — `fork-noexperts` has no v5 cache (no `v5-cache`/`v5-pilot` boot lines in its log) → `v4_pilot_pool(store)=NULL` → serial sync path, same as the port |
| async PILOT read-ahead (`COLI_DSV4_VK_PILOT_ASYNC`, default on) | on (default, commit `01fdc6bf`) | different mechanism (tier stream prefetch; `prefetched 12576 (10573 used)`) | fork's own G14 verdict: async PILOT is **wall-neutral** (−35 % blocking only) → ~0 expected delta; port prefetch measured in-window |
| RAM budget / expert cache target | `--memory-gb 28`; `ram_tiers … target_slots=48 target_cache=25.70GiB` | same line, same 25.70 GiB target; store hot policy `pin_slots_per_layer=16 … rows16=hot-pins` | **match** on budget; admission differs (fork ExpertCache MFU/MRU vs port store LRU+pins+stream) — the campaign's S7 lane measured decode-side store behaviour at fork parity |
| greedy / KV / state | `COLI_TEMP=0 KVSAVE=0`, `.coli_ckpt` removed, fixed snapshots | identical | **match** |
| fork's *own* runner (root `run_arm.sh`) — NOT the campaign rig | `taskset -c 0-15` (8 P-cores, 2 threads/core), `OMP_NUM_THREADS=16` (no PLACES), `V4_LOADER_LANES=9`, `V4_EXPERT_UNION=1`, `CTX=262144`, `RAM_GB=30`, max-tokens 2 | n/a | different placement class (all-P SMT vs P+E spread); produced none of the compared numbers — flagged only so nobody cross-compares the fork's internal docs (e.g. the 3.0 tok/s warm-pool record) against rig numbers |

**Verdict:** at matched compute location the CPU runtime configuration is **byte-equal**. The
only real runtime difference is architectural (compute lanes, above), and it is **off** in the
fork's fold-free arm. The P+E hybrid placement is a shared, untested cost on both engines.

---

## 2. CPU expert-compute kernel census (what runs when an expert is computed on the CPU)

Decode dispatch, matched arms (both serial per expert on the decode/engine thread, each
matvec internally `#pragma omp parallel for`):

- fork fold-free: `v5_moe_cpu_expert_slice` → `coli_v4_expert_forward_ref`
  (`deepseek_v4.c:9012-9036`, sync arm `:9381/:9406`)
- port: `v4_vk_token_finish` → `coli_v4_expert_forward_ref` (`deepseek_v4.c:5547-5572`), or the
  plain CPU loop `:6037-6046`; hybrid host-pool pairs inline in `vkt_join` (`vk_tier.c`, "37
  host pool pairs computed by the CPU in place (125.8 ms, 3400 us a pair)")

| op | fork impl | port impl | tested? |
|---|---|---|---|
| gate+up GEMV (fp4 e4m3-elem, 2048×4096 ea.) | hot path **dead at d11fba5b**: `coli_fp4_dual_matvec_rows16_v10` exists (`:29999`) but nothing ever packs (`coli_fp4_pack_rows16_v10` defined `:29725`, **zero callers**; store autopin removed — `:13786-13794` "PLAN_cache Task 6 item 7 … autopin / .coli_usage / rows16 pin packing is removed"). Actual kernel: `coli_v4_expert_forward_v17_fallback` → `coli_fp4_dual_matvec_ref` (`:29318`) → `coli_fp4_matvec_rows16_order` (row-major, rows16 *order* for bit-parity, OMP-parallel, `:28960`) | same fallback for unpinned slots; **pinned/hot slots are rows16-packed**: `coli_fp4_pack_rows16_v10` called at `:9787/:9872`, `view->block_rows=16` (`:9778`) → `coli_fp4_dual_matvec_rows16_v10` (`:11015`) — packed layout, OMP-parallel | kernels **byte-identical** (diff: `matvec_rows16_v10`, `dual_matvec_rows16_v10`, `pack_rows16_v10`, `native_quant_fp4_rows16.h` — 0 lines; `swiglu` — 0 lines). The *layout policy* differs; the port's packing is the campaign's S7 store work. **Never A/B'd fork-vs-port** (it is a port-side advantage the fork lacks) |
| down GEMV (fp4, 4096×2048) | `coli_fp4_matvec_ref` (`:29079`) → rows16_order | same, or `coli_fp4_matvec_rows16_v10` on pinned slots | identical kernels; see above |
| swiglu (+route-weight scale, bf16 rounds) | `coli_v4_swiglu` (`:28810` region) | identical | **byte-identical**, not perf-differentiated (scalar-order contract, #1136) |
| SIMD class on this box | kernels guarded `__AVX512F__`→`__AVX2__` (`:29694`); box has no AVX-512 → **AVX2 branch both sides**, `-march=native` both builds. No FMA in the fp4 hot loop (mul,mul,add — the #1136 bit-parity contract); AVX-VNNI unused by the fp4 experts (it serves int4/i8 `ggml_quants.h`/`expert_ffn.h` engines, not DSV4 fp4) | same guards, same resolution (`:22054+` region) | **match** — same ISA dispatch, same code, same gcc, same flags (§3) |
| fp8→f32 decode (shared expert, fp8-e4m3 blocks; dense fallbacks) | `native_quant.h` 110 lines: gather-LUT decode | `native_quant.h` 227 lines: **adds branchless `v4_fp8_decode8` (AVX2), `v4_fp8_decode8_bytes` (F16C), `v4_fp8_decode16` (AVX-512)** — "Replaces a slow per-element `_mm256_i32gather_ps` from a 256-float LUT" | **port-side advantage, never measured as a delta**. Scope: the shared expert (43×/token on CPU in the matched arm) + any CPU fp8 matvec. Est. small (≤10 ms/tok, §5) |
| router (gate 256×4096 f32 + noaux_tc top-k; hash-router tid2eid for layers<3) | **on device** in the compared arms — `ffn.gate.weight` hooked=1/uploaded f32 in both fork-full and fork-noexperts inventories; hash tables cached (M5-2c); CPU reference per-op fallback | **on host**: `l2-c0-r1.log` "kept on the host: norms, block scales, **the router**, the indexer's weights_proj, the mHC mixes, **the head**" — the port runs 43 router matvecs + head + mHC mixes on the CPU each decode step | **NAMED DIFFERENCE, never tested as a delta**. Fork's own precedent: moving indexer scoring to GPU was +1.4 % decode (CPU 43→22 ms/tok, C-perf-evidence). Est. 10–40 ms/tok (§5) |
| shared expert (fp8) | fork-full: computed on GPU (fp8 uploaded, mHC tail fused); fork-noexperts: CPU `coli_fp8_dual_matvec_ref` with the **gather-LUT** decode | CPU on both arm classes (`V4_SHARED_HERE`), with the **branchless** decoder | covered by the fp8-decode row above |
| decode CPU-expert scheduling | serial per expert (fold-free arm); **6-lane compute pool when the v5 cache is on** (headline arms): misses enqueue read+compute (`pilot_pool_enqueue_full`), warm hits enqueue compute-only (`pilot_pool_enqueue_compute`, the L4 work), merge in selection order — byte-identical by construction | **serial per expert always**; read overlap only (inherited loader lanes, 9); the port-side design (`I-decode-lanes-design.md`) with its 10-step plan and G1–G6 gates was **never implemented** | fork's own A/Bs: demand lanes **+23 % decode** (G15: 0.92→1.10–1.19 tok/s), warm-pool lane compute **−32 % decode wall** (2.05→3.0 tok/s, `0f1b06d2`). On the port: **never measured** — C-perf-evidence §5 ranks this "the single largest post-tier decode lever"; PORT_STATUS superseded only the *async PILOT* read-ahead half (P2.2), not the CPU compute lanes |
| expert store / hot cache | ExpertCache slot pool + MFU/MRU split (`d11fba5b` = the split-direction fix); store LRU without pins | store LRU + V4HotPolicy **pins + frozen section + `.coli_mfu` + rows16 hot-pins** (S7 lane, landed) — logs print `v4_rows16 packed_slots=458–976` (fork arms print nothing: no packing) | S7 measured: **decode-side store behaviour already at fork parity** — tested, not a gap driver |
| prefill expert batching | `V4_EXPERT_UNION` union walk + `coli_v4_expert_forward_batch_ref` (default on) | same union + batch ref (identical batch kernel +2 GGML lines) | identical; prefill-class, not decode |

**Census verdict:** at matched compute location the per-expert CPU work is **the same code,
same ISA, same OMP team** on both engines; the port is the side with the *extra* CPU-side
kernel work (rows16 hot-pins, branchless fp8 decode). The fork's CPU-side *scheduling*
advantage (compute lanes) exists only in its headline arms and was never ported or falsified
for the port's stack.

---

## 3. Build-flag diff (engine objects)

From the campaign build logs (`audit-build-fork.log`, `audit-build-port.log`) and
`c/Makefile.deepseek-v4` on both trees:

| item | fork | port |
|---|---|---|
| base CFLAGS (Linux x86) | `-D_GNU_SOURCE -O3 -march=native -fopenmp -pthread -include pthread.h` | identical |
| LTO | `LTO ?= 1` → `-flto` (default on) | `LTO ?= 1` → `-flto` (default on) |
| -funroll / per-file specials | none anywhere | none anywhere |
| unit-split compile | same `COLI_V4_UNIT_*` per-unit compile of the amalgamated `deepseek_v4.c` (incl. `COLI_V4_UNIT_NATIVE_QUANT_ROWS16.o`) | same scheme, superset of units (KV_CACHE, ATTENTION_CACHE, EXPERT_STORE…) |
| -D differences | `-DCOLI_VULKAN -DCOLI_V4_GPU_TIER -DCOLI_V4_GPU_TIER_VK`, `-DCOLI_V4_EXPERIMENTAL_DUAL_EXPERT_LOADER` | adds `-DCOLI_V4_MAX_PIN_SLOTS_PER_LAYER=16 -DCOLI_V4_PIN_RAMP_REQUESTS=24` (store pin policy constants); same loader define |
| objects linked | `backend_vulkan.o backend_vulkan_dsv4.o mfu_table.o expert_slot_pool.o gpu_mfu_cache.o miss_path.o expert_cache.o cache_reorder.o pilot_async.o …` | `backend_vulkan_v4.o vk_tier_v4.o vk_chain_v4.o mfu_table.o expert_store_registry.o …` |

**Verdict: no material build-flag difference.** Same gcc, same box, `-O3 -march=native
-fopenmp -flto` on both; the only deltas are feature `-D`s and which backend objects are
linked. The CPU expert kernels compile to the same ISA dispatch (AVX2; AVX-512 branch dead on
this box on both sides — no `-march` asymmetry to exploit).

---

## 4. The MTP / spec-decode verdict — **NOT ENGAGED in either engine's numbers; no hidden multiplier**

Config ground truth (`/root/Projects/colibri-v4-docker/models/DeepSeek-V4-Flash/config.json`):
`num_nextn_predict_layers=1` **plus the DSpark 3-stage supplement markers** —
`dspark_block_size=5`, `dspark_target_layer_ids=[40,41,42]`, `dspark_markov_rank=256`. So the
full 3-stage drafter this box's engines expect **is present in the checkpoint** (the port's
tiny fixture is not: `c/tests/test_deepseek_v4_tiny.py:326` "SKIP mtp draft … fixture has no
3-stage MTP profile").

Engagement gate (identical machinery in both trees — fork `deepseek_v4.c:14618-14626`
`v4_dspark_full_wanted`: requires **`V4_MTP!=0` AND `V4_DRAFT>0`**; decode loop `:25590-25840`;
port `:17284-17538` same). Markov drafting is a separate opt-in (`COLI_V4_MARKOV_SPEC`),
ngram drafting needs `V4_DRAFT>1`. **No rig or chain sets any of these.**

Log-line evidence:

- **Zero speculative rounds in every standing arm.** The session prints a stats line
  whenever `spec_attempts>0` (fork `:25861-25870`; port equivalent). `grep -h
  "spec_attempts\|speculative" /root/bench-colibri/up2276/*.log` over all 156 logs →
  **no match**. No `v4_dspark` boot/warning lines in `fork-full-r3/r4`, `fork-r1..r4`,
  `fork-noexperts-r1/r2`, `audit-fork-r1` (a requested-but-absent profile would have printed
  `v4_dspark warning=unsupported-checkpoint … actual_mtp_layers=1`; not present → MTP was
  never even requested). The fork's 1.15–1.21 tok/s is **plain S=1 decode**; the port's
  numbers likewise. (Consistent with the L7 lane's finding of no S 2–4 decode rows on the
  port side.)
- **The one engaged MTP arm (port-side, up176 merge tree) quantifies it on this box:**
  `merge-s256-gr4-mtp4-r1.log` —
  `v4_dspark mode=full-3stage cache=0.45GB reserve=1.17GiB load=lazy verification=exact-target` /
  `[MTP] DSpark core ready: stages=3 block=5 main_proj=4096x12288 markov_rank=256` /
  **`[MTP] rounds=1 drafted=3 accepted=0 rate=0.0%`** /
  `v4_dspark attempts=1 drafted=3 accepted=0 acceptance=0.0% adaptive_disabled=0`.
  One verify batch, zero accepts, then the auto-disable (`accepted<proposals` → `mtp_disabled=1`
  unless `V4_MTP_PARTIAL_KEEP`, fork `:25720-25724`). Cost: TTFT 201.8 s vs sibling control
  194.9 s (+6.9 s lazy drafter load), decode **0.506 vs 0.528–0.533 tok/s — MTP made it
  slower**. The ngram arm (`merge-s256-gr4-draft4-r1.log`, `V4_DRAFT=4` without MTP) fired no
  rounds at all (no stats line — prompt lookup found nothing on this code prompt), 0.533 tok/s.
- **The fork's own in-tree evidence** (`deepseek_v4.c:25714-25718`): "With recurrent
  compressed attention, a rejected suffix cannot be truncated in place: the accepted prefix
  must be replayed. **Real chat measured 10/24 accepted and 495 s for 14 visible tokens**, so
  stop full MTP after the first non-perfect block unless explicitly benchmarking it."

**Verdict:** the model's `num_nextn_predict_layers=1` never bought either engine a decode
multiplier — MTP/spec-verify was OFF in every number this campaign compares, and the single
measured engagement on this box (1 round, 3 drafted, 0 accepted, auto-disabled, −4 % decode,
+7 s TTFT) plus the fork's 10/24-accepts replay catastrophe say the upside on this
architecture/workload is ≤0 without a `V4_MTP_PARTIAL_KEEP` + drafter-warm path nobody has
priced. **The 2× headline gap is not an MTP artifact.**

---

## 5. Ranked never-tested CPU-side differences (contribution estimates)

Gap A = matched-location decode (fork 0.61–0.63 vs port 0.53–0.58; ≈0.10–0.15 s/tok).
Gap B = headline decode (fork 1.19–1.21 vs port best 0.66–0.67; ≈1.8×).

1. **Decode CPU-expert compute parallelism — fork's 6-lane compute pool, never ported, never
   falsified for the port stack.** Engaged only in the fork's *headline* arms (v5 cache on);
   inactive in its fold-free arm, so **≈0 toward Gap A**. Toward Gap B: the fork's CPU expert
   tail (its non-GPU-hit selections) computed 6-wide with compute-on-land and compute-only hit
   jobs — fork's own A/Bs price the class at **+23 % decode** (G15) and **−32 % decode wall**
   (`0f1b06d2`), i.e. of order 0.1–0.25 tok/s at the fork's operating points. The port's
   `I-decode-lanes-design.md` projected "UNPROVEN … measure (step 9)" and was never built;
   PORT_STATUS's "superseded" note covered only the async-PILOT read-ahead half. **Est. Gap B:
   ~0.05–0.15 tok/s (8–20 % of the headline gap) if the port-side overlap fraction resembles
   the fork's; could be ~0 if the port's serial compute is already hidden behind device waits
   (DPROF says it is not: 884 ms/tok CPU compute is the critical path).**
2. **Host-op placement: router/indexer weights_proj/mHC mixes/head on the port's CPU vs the
   fork's device.** Inside the port's 518.8 ms/tok "forward glue" (DPROF) vs the fork's
   ~430 ms/tok glue era number; the fork moved its indexer to GPU for +1.4 % (22–43 ms/tok).
   **Est. Gap A: 10–40 ms/tok (~1–2.5 %); Gap B: similar absolute.** Never isolated on the
   port; cheap arm if ever chased (device-upload class, upstreamable).
3. **Hybrid-core OMP placement (shared, not a fork–port delta).** Both compared arms bind the
   16-thread team one-per-core across 8P+8E; static-scheduled expert matvecs (8–16 tiles per
   thread) finish at E-core pace every region. Equal on both sides → **0 toward both gaps**,
   but it plausibly inflates *both* engines' CPU-expert mass by ~15–25 % vs a P-pinned team
   (a per-expert ~2 ms floor × ~230–260 experts/token ≈ tens of ms/tok). Never A/B'd on
   either engine (no `places=threads`/E-exclusion arm in any chain); would move the port's
   absolute decode as much as the fork's.
4. **Port-only CPU kernel advantages (wrong direction for the gap, listed for completeness):**
   rows16 hot-pin packing (packed slots 458–976/arm vs the fork's zero packing at d11fba5b —
   its store autopin was removed) and the branchless AVX2/F16C fp8 decoders. **Est. −5 to
   −15 ms/tok** (they narrow Gap A slightly); never measured as deltas. Implication: the
   matched-location gap is *not* a CPU kernel deficit — the port already runs the better
   kernels where it matters.
5. **Read-ahead/prefetch class (moe-ram ring + take=par vs tier stream prefetch).** Both
   engines prefetch; the fork's queue-ahead was measured prefill-only and wall-neutral
   (gap-spec/G1), the port's prefetch guard held (10.5k/12.6k used). **Est. ≈0 both gaps**;
   no untested lever here.
6. **MTP/spec-decode — closed by §4: 0 toward both gaps**, with the only on-box engagement
   measured negative.

**Residual after this census:** Gap A's bulk is the port's per-layer decode glue around the
(expert-compute-identical) CPU path — tier issue/join steps, view leases, ascending re-walks,
host mHC/router/head ops — which the campaign already attributes to the Option-B fold class
(one-submit cells); the items above are the CPU-side deltas *not* already inside that
attribution, ranked 1–2 first. For Gap B, the un-ported lane-parallel CPU expert compute
(item 1) is the only CPU-side lever with fork-measured double-digit percentages that the
campaign never priced on the port's stack.

---

### Evidence index (primary sources)

- rig: `/root/bench-colibri/run-arm2276.sh`, `/root/bench-colibri/chain6.sh`,
  `/root/Projects/colibri-upstream/scripts/ab-forks.sh`; fork's own runner
  `/root/Projects/colibri-ds4-vulkan/run_arm.sh`
- arms: `/root/bench-colibri/up2276/{fork-full-r3,fork-full-r4,fork-r1..r4,fork-noexperts-r1,
  fork-noexperts-r2,audit-fork-r1,new-s256gr4-r2,new-s256gr4-r3,l2-c0-r1..r3,s3-l-r1..r3,
  base-host0-r1,mm8-defaults,mm8-decode28,dmoe-armed,dprof-b-r1}.log`,
  `merge-s256-gr4-{r1,draft4-r1,mtp4-r1}.log`, `summary.txt`
- fork code: `c/deepseek_v4.c` (rows16 kernels 28724–30060, spec loop 25590–25840, moe lanes
  9297–9436, dspark gates 14618–14982, store-autopin-removed 13786+, OMP 26949+),
  `c/cache_engine.h:150-193`, `c/native_quant.h`, `c/Makefile.deepseek-v4`
- port code: `c/deepseek_v4.c` (5484–5600 tier seam, 9240–9909 hot policy/rows16, 10916–11032
  forward_ref, 17284+ spec loop, 18749+ OMP), `c/vk_tier.c`, `c/native_quant.h`,
  `c/tests/test_deepseek_v4_tiny.py:326`, `c/Makefile.deepseek-v4`
- campaign docs: `docs/research/C-perf-evidence.md` (both trees),
  `docs/research/I-decode-lanes-design.md` (main clone), `docs/PORT_STATUS.md` (P2.2
  supersession), `CAMPAIGN.md` (S7/DPROF/G1 verdicts), `docs/experiments/mm8-2026-10-22/`
  ("AVX-512 no")
