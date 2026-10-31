# Barrier census — GPU sync objects + host serialization points, fork vs port (2026-10-25)

Lane: **audit-barriers** (CPU, read-only, manager-run comparative-audit wave). Trees examined:
**fork** `/root/Projects/colibri-ds4-vulkan` @ `d11fba5b`, **port** `/root/bench-worktrees/up2276-merge` @ tip
(`0c847722`). Neither repo touched. Every number below is either (a) arithmetic from committed logs in
`bench/up2276/`, (b) code-anchored at the named site, or (c) a labeled estimate whose bound is stated.
No GPU was run for this audit; measurement designs are in §6.

## 0. Executive stop-finding (read this first)

**GPU-side synchronization is NOT a material term in the fork-vs-port gap — on either side.**

- Port, decode window (V-g1's instrumented legs, 63 one-row forwards): **87 submits/token** cost
  **3.8–4.5 ms/tok inside `vkQueueSubmit`** and the whole fence-wait-vs-device-time excess is
  **5.16–5.58 ms/tok**. Tier decode fence waits add **0.44–0.50 ms/tok**. Total GPU-sync budget
  ≈ **4.3–5.0 ms/tok measured, ≤ ~10 ms/tok with every bounded slop term** — against a
  **1,620 ms/tok decode wall**. That is **0.3–0.6 %**. Eliminating *every* barrier, submit and
  fence on the GPU side would buy less than 1 % decode.
- Fork: its own records price a submit+fence round trip at **≈ 0.1 ms on this RADV stack**
  (`docs/decode-gpu-full-residency-review-2026-10-02.md`: "Submit+fence ≈ 0.1 ms"), with ~10
  submits/layer-token in that census (≈ 430 fence waits/token, "~430 ms host serialization is
  exactly this"). The fork then **measured the class dead**: the max-GPU campaign removed 131
  submits/token (mHC device chain) and **lost 8.9 %**; compgpu **added** 69 submits/token and was
  the only consistent positive — "host-work removal beats submit removal"
  (`470ac196`, `d4c504c7`, `4edbf82d`; summarized C-perf-evidence §3). sclk dips to 500 MHz between
  bursty submits dominate any submit-count arithmetic on this box.
- **The asymmetry runs the OPPOSITE way to the brief's hypothesis.** At the command-buffer level the
  port is the *leaner* submitter at decode: 87 CBs/token (2/layer + tail) vs the fork's ~250–430
  (§2.3). The fork's 2× decode advantage is the **expert fold** (routed experts device-resident,
  one fused submit/layer) — exactly CAMPAIGN.md's 1.84× attribution — not its sync-object diet.
- The real serialization is **host-side**: port decode = chain waits 235.0 + **tier MoE CPU 821.9**
  + **forward glue 518.8** ms/tok (V-g1's exact block decomposition); port TTFT's mass is the
  engine-thread expert-stream economics (X/S0: staging 105.6 s; AC: carve MOEH 448 s), not locks.
- One prior anchor is **corrected** here (§5, C-1): the "disk read inline under `state->mutex`"
  premise from R-l1 does not describe the standing rig's store at the tip — the engine links the
  hot-rows16 store whose `lookup_hot` **releases the mutex around the read** (per-expert loading
  reservations; the mutex-held `lookup` remains in-tree but is reached only by the base open the
  hot store itself replaces at `deepseek_v4.c:10734`). The engine-thread serialization R-l1
  measured is real, but its mechanism is "serial one-at-a-time reads on the engine thread", not
  one lock held across I/O.

Everything below is the census that substantiates this.

---

## 1. Method and sources

- Logs (all in `port/bench/up2276/`): `s1-d-dprof.log`, `s1-{d,k,n}-r*.log`, `p1-c0-r1.log`,
  `s3-{c3,l,f}-*.log`, `fork-r1..r4.log`, `fork-full-r3/r4.log`, `fork-noexperts-r1/r2.log`,
  `gemv8-step0-prof-{8,24}.log`. Decode-window numbers use **63 one-row forwards** as the divisor
  (V-g1's "reading note": the chain line's `N fwd` counts window openings; divide by the CLI count).
- Research docs: `docs/research/V-g1-dprof-2026-10-24.md` (the decode-window instrument), `X-ob0-s0-…`
  (prefill host-split), `AC/AB-ob1-s3-…`, `R-l1-byte-economy-map-2026-10-23.md`, `C-perf-evidence.md`,
  fork-side `docs/decode-gpu-full-residency-review-2026-10-02.md`, `PLAN_submit_merge.md`.
- Code anchors are given as `file:line` at the tree stated above.
- The port's **exact per-run barrier count is not printed at tip**: `VkcStats.barriers` ticks at every
  emission site (`vk_chain.c:791,2674`) but no report line prints it. The audit-placement lane was
  steered to add exactly that print. Counts below therefore split into *exact* (submits, fences,
  frames — printed) and *derived* (barriers — structural floor + static hazard analysis, bounds given).

---

## 2. GPU-side census

### 2.1 Queue topologies

| | port | fork |
|---|---|---|
| queues asked from the driver | up to **3**: `G.queue` (main/chain), `G.tqueue` (tier batch; second queue of the main family, else a compute-only family — "RADV's async compute"), a transfer-only family for staged uploads (`backend_vulkan.c:1270-1320,1544-1545`) | **1** (`G.queue`, `queueCount:1`, `backend_vulkan.c:2451,2579`); a second device would get its own |
| standing rig reality | tier line prints "**own queue**" (`s1-d-r1.log`); the staged-upload "[VK] memory:" line is absent from every standing log → the uploader's dedicated queue is not active there; decode runs **chain-queue + tier-queue** | single queue for dense, cells, expert groups, uploads, head |
| semaphores | **2 timeline semaphores**, `KC.tsem_g/tsem_h` (`vk_chain.c:683-689`) — the dmoe **hybrid** path's host↔device ordering only; **0 binary semaphores**; **no cross-queue semaphore anywhere** | **0 semaphores** of any kind (`grep Semaphore` = 0 hits) |
| cross-queue ordering mechanism | **host-side only**: uploads finish on their thread (fence), land via the `done` list at a quiescent point (`vk_tier.c` `quiesce()`), and the chain's dmoe re-reads the tier table after `vkt_settle()` (`vk_dmoe.h:605`). No GPU-GPU dependency object exists between the two queues | n/a (one queue: submission order *is* the sync) |
| image layout transitions | **none** — every surface is a storage buffer; all barriers are global `VkMemoryBarrier`s | **none** — same |
| busy-waits (host) | chain frames: spin `COLI_VK_CHAIN_SPIN_US` default **2000 µs** then block (`vk_chain.c:731-745`); backend/tier fences: spin **300 µs** (`backend_vulkan.c:2462-2468`), tiled-GEMM waits spin to 50 ms; hybrid host wait spins 20 000 polls then `vkWaitSemaphores` (`vk_chain.c:885-893`) | all waits spin **300 µs** then block (`vk_fence_wait`, `backend_vulkan.c:4186-4206`) |

### 2.2 Port — sync objects per forward

**Decode token** (host-step path, dmoe unarmed — every standing decode arm):

| family | count/token | emission site | class (§2.4) |
|---|---:|---|---|
| chain CB submits (= frames) | **87** exactly (43 A1 + 43 A2 + 1 tail; 5,481/63 = 86.99, V-g1) | `vkc_submit`, `vk_chain.c:821-871`; A1/A2/tail record sites `deepseek_v4_chain.h:1400,1414,1459` | intra-queue submit |
| chain fence waits | **87** blocking-classified (5,480/63), reached through **43 `vkc_finish()` drains** that scan all 16 ring frames (`vk_chain.c:779-789`) + ring-wrap waits in `vkc_begin` | `frame_wait`, `vk_chain.c:735-760` | host fence |
| chain pipeline barriers — structural | **174** (1 opens + 1 closes every frame: `barrier_now` at `vkc_begin` `:817`, `vkc_submit` `:834`) | `vk_chain.c:786-792` | intra-CB global memory barrier |
| chain pipeline barriers — hazard | **derived, not printed**: `hazard()` fires on RAW/WAR/WAW conflicts and track-overflow (`vk_chain.c:917-934`). The A1 recorders are in-place SSA chains (`v4c_pre`: matmul→split→collapse→**bf16 in place**→norm→**bf16 in place**, `deepseek_v4_chain.h:1112-1118`; attention similar `:1152-1180`) → a hand-trace of those chains prices ≈0.5–1.0 barriers/op, so at G1's measured **61.6 ops/layer-token** that is **~30–60/layer → ~1.3–2.6 k/token** (floor 0, ceiling ≈ ops 2,649). The one in-tree *measurement* is the `vk-chain-check` harness: **28,704 barriers / 10,594 frames = 2.71/frame** (E-baseline.md) — but that workload runs 0.62 ops/frame (structural-2-dominated) vs **31.7 ops/frame** at parity decode, so it bounds nothing at parity; the true count needs the print (§6.1). Independent derivation agrees: the sibling placement census (this wave) calls the class **bounded-dead** at ≤ 9.7 ms/tok either way | `hazard()` call in `record()` `:977` | intra-CB |
| indirect-dispatch barriers | 0 at decode (dmoe path only: `record_indirect` `:2674`) | — | intra-CB |
| timeline semaphore ops | **0** in standing arms (2 objects exist; the dmoe-**hybrid** mode would add 1 wait + 1 signal per hybrid step) | `vk_chain.c:848-856` | device↔host timeline |
| tier batch submits + fence joins | **~43 + ~43** (one `issue`/`join` per layer-step with ≥1 resident expert; `vk_tier.c:2330-2495,2503-2560`) | `xb_issue`→`xb_record_submit` (`backend_vulkan.c:5572-5612,5416-5570`), `xb_join` (`:5635-5661`) | second queue, submit + host fence |
| tier batch barriers | **~3–7 per batch** (≈150–300/token): grouped route `gu→barrier→down` (`xb_barrier` sites `backend_vulkan.c:4899,5019,5408,5505,5519,5529`), a transfer→compute barrier for host-pool expert copies (`:5434`), a closing compute→**HOST** barrier for the mapped-y read (`:5553,5938`) | `xb_barrier` `:5212-5216` | intra-CB (own queue) |
| promotions | decode-set arms: 612 MiB/63 tok ≈ 9.7 MiB/tok through the uploader thread (cond handshakes, backend submit path); s3/s1 arms: **0** (bank instead) | `promote()` `vk_tier.c:851-900` | background submit |

**Prefill chunk** (s1-d set, 10 chunk-windows of ≤2048 rows; `s1-d-dprof.log`):
prompt frames 6,474−5,355 = **1,119 ≈ 112/chunk**; ~4,856 ops/chunk ≈ **116 ops/frame** → barriers
≈ 2/frame + ~50–100 hazard/frame (same derived class) ≈ **6–12 k/chunk**; dmoe-armed arms add
`record_indirect` barriers + explicit `vkc_barrier()` around staged fetches (`vk_dmoe.h:625-627,671-673`)
and `vkt_settle()` per dirty table upload. Tier streaming: **16,254 sub-batches** per run in the R=4 arm
(683 in R=16), each a submit+fence join on the tier queue with its 3–7 barriers. **Prompt `vkQueueSubmit`
totals 8.4–10.4 ms for the whole prompt** — 0.007 % of the 158 s TTFT window.

### 2.3 Fork — sync objects per forward

**Decode token** (GPU-FOLD stack, hardwired `75f78246`; census skeleton from the fork's own
`decode-gpu-full-residency-review-2026-10-02.md` §1, adjusted for what landed by `d11fba5b`):

| family | count/layer-token | notes |
|---|---:|---|
| attention cell / segment submit | 1 | qkv-pre + selection train + the ~16-dispatch attention segment folded to ONE submit (`COLI_DSV4_VK_ATTN_CELL_DEC`, +4.12 % replicated); ~8–10 intra-CB barriers between its stages (`backend_vulkan.c:8627…8823`) |
| mHC pre (attn) + pre (ffn) | ~2 | the fused single-token `mhc_dec_pre`; the 3-dispatch device chain at S=1 was measured 3.7× WORSE and stays off |
| compressor projections/scan | ~1 | GPU-FOLD hardwiring (2026-10-11); the dec2-comp *fold* onto the open buffer was refused (−2.1 %, `d4c504c7`) |
| route gate | 1 | GPU matvec + host top-6 |
| FFN opener | 1 | **deferred** submit (default on, `cd8ee8ff`): submits without waiting, flushes at the route site — the fork's only decode queue-ahead |
| routed expert group | 1 | fused single submit: QDQ→barrier→gate/up (`pf4_id` ONE dispatch)→barrier→swiglu→barrier→QDQ(hid)→barrier→down→[barrier→reduce] ≈ **5–6 barriers** (`backend_vulkan.c:12900-13110`) |
| shared expert | ≤3 | "3 matvec submits + host glue" per the 2026-10-02 census; the SHARED_DEFER fold was refused (−4.6 %) |
| head argmax | 1/token | bf16 matvec + host argmax |
| **submits + fence waits** | **≈ 6–9/layer → ~260–390/token** (the 2026-10-02 census said ≈10/layer ≈ 430/token; the attn-cell fold removed 2/layer, GPU-FOLD added the compressor ones back). Exact tip count needs a `COLI_VK_CB_SESSION=2` trace (§6.5) | every submit is followed by an immediate `vk_fence_wait` (queue drained) except the opener |
| **intra-CB barriers** | ≈ **15–20/layer → ~650–900/token** | 104 `vkCmdPipelineBarrier` sites in `backend_vulkan.c`, all global memory barriers, all compute→compute |
| cross-queue anything | **0** | single queue, no semaphores, no timeline |

**Prefill cell** (the fork's own instrumented census, `PLAN_submit_merge.md` §1): **9–10
submit+wait round trips per 128-token cell** (hc1 pre, prologue, comp_scan, the joined segment,
hc2 post, hc2b pre_norm, route, bank, hc3); measured `v4_prefill_gpu submits=4511 fences=4511`
over 344 cells (13.1/cell incl. the mHC pre pair); the cell-tail merge measured −1/cell (4167).
The 2026-10-13 utilization probe: at 8.5–250k context a cell runs 80–119 ms wall, GPU executes
only 38–67 ms, "the host main thread is **asleep 87 % of the wall** (26/30 gdb samples in
`drmSyncobjWait`)" — the fence chain, not barriers, is the prefill shape.

### 2.4 Cost classes on RADV, with the measured anchors

| class | objects | evidence-supported cost |
|---|---|---|
| **intra-CB global memory barrier** | port chain ~1.1–2.4 k/tok est. + tier ~150–300; fork ~650–900 | No direct measurement exists (§6.2 designs one). **Bounded above** by the submit path: 87 chain submits incl. their ~1–2.5 k recorded barriers cost **3.8–4.5 ms/tok total** (`d_submit_ms`, V-g1 table: 237.6–283.6 ms / 63) → the whole record+validate+submit pipeline averages **44–52 µs/frame**. Per-barrier cost is therefore ≤ a few µs driver-side and invisible in `d_dev_ms` (A1 device 223.5–238.3 ms/tok is 97.7 % of A1 wait). |
| **submit (vkQueueSubmit)** | port 87/tok + tier ~43/tok; fork ~260–390/tok | port: measured above; fork: "≈ 0.1 ms" per submit+fence round trip (fork's own RADV number) — but its marginal value is dominated by **sclk residency** (500 MHz dips between bursty submits), which *reverses the sign* of submit-count reductions (three independent forks measurements, C-perf §3). |
| **host fence wait (spin→block)** | port 87 chain + ~43 tier; fork ~260–390 | port chain: the wait-vs-device excess is **5.16–5.58 ms/tok** (V-g1 R1, ×2 stability ±0.09); tier: 0.44–0.50 ms/tok. Spin-waste bounded 4–13 ms/tok (G1 SF-3). Fork: its 430-wait era ≈ 430 ms/tok host glue — the fork then *removed the host work*, not the waits. |
| **cross-queue (implicit serialization)** | port only: chain queue ∥ tier queue | No semaphore/fence ties them; ordering is host-side (quiesce/settle). The tier's decode share under the chain's fences is bounded by tier `waited` 0.5 ms/tok and promote traffic ~72 ms/tok of bus occupancy that "does not sit under the chain's fences" (V-g1 R3/H1 dead). **No measurable cross-queue cost is in evidence at decode.** |
| **layout transition** | none on either side | — |

### 2.5 Totals and the architectural comparison

| per decode token | port | fork |
|---|---:|---:|
| command buffers submitted | **87** (+~43 tier batches) ≈ 130 | **~260–390** |
| fence waits (host) | ~130 | ~260–390 |
| intra-CB barriers | ~1.3–2.5 k (derived; floor 174+~215) | ~650–900 |
| queues | 2 | 1 |
| semaphores / timeline ops | 2 objects / 0 ops | 0 / 0 |
| measured sync cost | **≤ ~10 ms/tok of 1,620 (0.6 %)** | ~30–45 ms/tok of 819 (~4–5 %) at the 0.1 ms/round-trip price |

**Architectural reason the fork wins decode despite more sync objects:** every fork submit carries
*device-resident work that replaces host work* (the expert fold: routed experts in one fused
group submit; dense projections in the dec2/cell submit), while the port's 87 submits wrap a dense
chain whose per-token device time is only ~235 ms and whose MoE runs on the **host** (821.9 ms/tok
CPU + 518.8 glue). The port's per-layer `vkc_finish` drain exists because of that host step — the
A1→host-MoE dependency is **data-forced** (the host router reads `h2d`), so A2 is the only device
work that overlaps it (G1 §1). Sync-object counts are a *symptom* of where work lives, not a lever.

**What a reduction slice would look like, with ceilings from the anchors:**
- *Batched barrier elision inside frames* (smarter `hazard()` batching / per-buffer
  `VkBufferMemoryBarrier`s): ceiling = the whole GPU-sync budget ≈ **≤10 ms/tok** (0.6 %) — **not
  worth a lane on its own**; would ride along with any frame restructuring.
- *A1+A2 frame merge* (`COLI_VK_CHAIN_SPLIT`/S2 class): halves submits 87→~44; two-sided ±30–40
  ms/tok (G1 §7's own two-sided bound: costs the A2-during-MoE overlap).
- *Settle-one-fence* (S1 class): bounded by the 5.5 ms/tok gap; **unfunded per V-g1 R1**.
- *Single-queue merge* (`COLI_VK_TIER_QUEUE=0`, exists today): predicted ≈0 at decode (tier waited
  0.5 ms/tok); possibly small at prompt streaming — worth one leg in a spare window, §6.4.

---

## 3. Host-side census (per decode token unless stated)

### 3.1 Port

| sync point | count/token | protects | serializes against | measured cost / anchor |
|---|---:|---|---|---|
| chain `frame_wait` (spin 2 ms → `vkWaitForFences`) | 87 + 43 drain loops | frame reuse + the A1 h2d/cdn host reads | GPU execution of that frame | A1 wait 234.0 vs device 228.6 ms/tok → excess **5.49** (V-g1); waits counter 5,480/63 |
| `vkc_finish` drain-all | 43 | the host read of A1's outputs before the MoE | every in-flight frame (mostly already done) | inside the 5.5 ms/tok term |
| tier `quiesce()` (`T.mx` lock, done-list swap, `cv_done` wait under `T.sync`) | ~86 (1 per issue + 1 per join) | slot table, done list, room signal | the uploader thread | unmeasured directly; the tier's decode `waited` 0.44–0.50 ms/tok bounds the join side |
| tier batch join fence | ~43 | the y rows readback | tier queue execution | 0.44–0.50 ms/tok (V-g1) |
| uploader-thread handshakes (`T.cv` signal per promotion batch, `cv_room` backpressure) | 0 (bank arms) – ~16–32 (decode-set promote arms) | the promotion queue | uploader thread | promote traffic 612 MiB/63 tok; PROMOTE=0 was *faster* end-to-end (0.6577 vs 0.6077 tok/s) — residency, not sync |
| expert-store leases (`lookup_hot`) | disk-load dependent (decode share of 5.9k–68k loads/run) | slot table + LRU (mutex around reserve/publish only) | other lease threads | **corrected vs R-l1**, see §5 C-1; the standing store releases the mutex around the read (`deepseek_v4.c:10203` region) |
| stream fills at prompt (engine thread) | 410 sub-batches × 64 experts at 2bd8ac93; tip: `load_batch` (per-expert threads) + 8×16 MiB bypass stages, groups of 8 | the tier's slots | disk | **S0/X anchor: STAGE 105.6 s of a 158.9 s window (66 %)** — the dominant host serialization; S1's bank took the banked layer to 0.2 s (AA) |
| OMP regions in the host MoE | ~6 experts/layer × ~2 regions ≈ **12/layer ≈ 516/token** (+ joins) | nothing — work distribution | the whole OMP team per region | inside the tier decode CPU **821.9 ms/tok** (V-g1); the generic engine's XEXP single-region variant (`colibri.c:7138-7180`) is not wired for V4 |
| timeline-semaphore host ops | 0 standing | dmoe hybrid host↔device | — | — |

### 3.2 Fork

| sync point | count/token | measured cost / anchor |
|---|---:|---|
| `vk_fence_wait` (spin 300 µs → block) | ~260–390 | ≈0.1 ms each (fork's RADV price); the 2026-10-02 census blamed ~430 ms/tok on the fence chain; subsequent work removed host work around it, not the fences |
| ring-thread take join (`v4_ram_take_join_ms`) | 43 takes/run | **0–15 ms TOTAL per run** (`fork-r1/fork-full-r3`: `takes=43 take_join_ms=0…15`), `take_upload_ms=332`, `stream_ms≈1450` — the layer switch never waits for the stream; queue-depth 16 O_DIRECT read team (`COLI_CUDA_MOE_RAM_QD`), parallel take |
| store reads | leases release the mutex around reads (same reservation design the port inherited); streaming uses `coli_v4_expert_store_read_bytes` — **no LRU/lease/slot state, no mutex at all** (`deepseek_v4.c:13726-13755`) | the ring thread issues them off the engine thread |
| MoE lanes / v5 pilot | 4 async lanes, max_inflight 12 (boot line `fork-r1.log`) | lane-compute pool hits: decode 2.05→3.0 tok/s (C-perf KEEP) |
| persistent lookup workers | reads N+1..N+3 overlap ordered expert compute (`deepseek_v4.c:8204`) | the 2026-10-02 host-glue ~430 ms/token era |
| OMP | read team (qd16) + expert compute teams | inside its decode wall 819 ms/tok |

### 3.3 The host-side comparison in one line

The port does **on the engine thread, serially**, what the fork does **on a ring thread with a deep
read queue** (prompt expert streaming), and does **on the host with OMP** what the fork does **on
the device in one submit** (decode MoE). Those two relocations — not lock counts — are the whole
host-side story: 821.9 + 518.8 ms/tok (port decode) and 105.6 s STAGE + 448 s MOEH (port prompt)
vs the fork's take_join≈0 and its expert fold.

---

## 4. Ranked reducible synchronization

| # | item | anchor | bound | campaign stage that touched it |
|---|---|---|---|---|
| 1 | **decode host-MoE → device** (the fold; removes ~43 issue+join+2×quiesce, ~516 OMP regions, and the data-forced A1 settle per token) | V-g1: tier CPU 821.9 ms/tok | up to ~820 ms/tok (fold class, not sync class) | L2/P1 (decode half no-win as a *shuffle*); S5 shrunk after bench-S3 MISS; **the fold remains the campaign's #1 decode lever** |
| 2 | **prompt engine-thread stream serialization** (load_batch/stage bypass/bank) | X/S0: STAGE 105.6 s; AA: banked layer 0.2 s; AC: 7,757 fills, 113.63 GiB, MOEH 448 s | tens of seconds TTFT (byte economics, not locks) | S0 (instrument), S1 (bank + load_batch + bypass), S3 (reorder, verdict MISS) |
| 3 | settle-one-fence (per-layer drain → `vkc_wait_serial`) | V-g1 R1 | **5.5 ms/tok ceiling** — closed unfunded | G1 spec §7 S1; not built (correctly) |
| 4 | A1+A2 merge / split tuning | `COLI_VK_CHAIN_SPLIT` RTX datum (58.3 vs 44.4 tok/s); G1 §7 S2 | ±30–40 ms/tok two-sided | G1 spec only |
| 5 | spin budget (chain 2 ms; backend 300 µs) | G1 SF-3 | 0–13 ms/tok | G1 spec S3 (env-row-only slice); unrun |
| 6 | single-queue merge (`COLI_VK_TIER_QUEUE=0`) | §2.4 | ≈0 decode; unknown small at prompt | never run as an arm |
| 7 | intra-frame barrier elision | §2.4 | **≤10 ms/tok total GPU-sync budget** | none — and per this census, correctly so |
| 8 | OMP region collapse for the V4 host MoE (XEXP-class) | `colibri.c:7138` precedent | subsumed by #1; standalone value unknown | none |

## 5. Corrections to prior anchors (census findings)

- **C-1 (R-l1 §3 S1 premise, superseded at tip):** "each [tier load] a synchronous lease that takes
  `state->mutex` and does the disk read inline" — the engine build links the **hot-rows16 store**
  (`COLI_V4_ROWS16_STORE_OPEN` installs `lookup_hot` at `deepseek_v4.c:10734`; the standing logs'
  `v4_ssd_io mode=direct-aligned` + `v4_hot_policy … rows16=hot-pins` lines prove it). `lookup_hot`
  takes the mutex to *reserve*, **releases it around the disk read**, and re-takes it to publish,
  with per-expert `loading_expert` reservations + `load_ready` cond — different-expert reads proceed
  concurrently (same design the fork has). The mutex-held-across-read `lookup`
  (`deepseek_v4.c:8913-9021`) is the base vtable, replaced in the engine build. The *serialization*
  R-l1 measured (serial one-at-a-time engine-thread reads) was real at 2bd8ac93 and was addressed by
  `v4_vkt_load_batch` + the bypass stages; **no lock-held-across-IO remains on the standing path**.
- **C-2 (brief's anchor):** "DPROF's d_submit_ms ≈1.4 ms/tok inside vkQueueSubmit" is not
  reproducible from any committed decode line; the measured range across all legs is
  **237.6–283.6 ms / 63 tokens = 3.8–4.5 ms/tok** (V-g1 table + `s1-d/s3` logs). The 1.4 figure may
  come from a different divisor or window; every conclusion here uses the measured range.
- **C-3 (brief's example):** "'31,785 barriers' over 64 forwards ≈ ~500/decode-token" — no log or
  report line prints barriers at tip (`VkcStats.barriers` is counted, never printed; the sibling
  placement census found the same). The structural floor alone is 174/token; the hand-traced hazard
  estimate is 1.3–2.6 k/token (§2.2); the only in-tree measurement (the `vk-chain-check` harness,
  2.71 barriers/frame at 0.62 ops/frame) does not transfer to parity's 31.7 ops/frame. The true
  count needs the one-line print (§6.1). Whichever branch is right, the measured submit+wait
  budget stays ≤ ~10 ms/tok (§2.4), so the "~500" vs "~2k" question changes no verdict — but the
  print should land so the next census states a number.

## 6. Microbench / measurement designs (DESIGNED ONLY — not run; no GPU used by this lane)

1. **Barrier-count print (cheapest, do first).** Add `st.barriers` to the chain report line in
   `v4c_report` (`deepseek_v4_chain.h:2024`) and a tier equivalent (`xb_barrier` counter). One line,
   zero behavior change; run any standing arm and read the decode-window count directly. Expected
   magnitudes: chain ~1–2.6 k/token decode (hand-traced §2.2), ~6–12 k/chunk prompt; tier ~150–300/token.
   *Coordinate with audit-placement, which was steered to the same print and independently derived
   ~230–2 k/token (its §2.6).* This converts §2.2's derived row into a measurement and settles C-3's class.
2. **RADV intra-CB barrier cost.** Standalone binary on the chain's own device/pipelines: fixed
   1,024 trivial `chain_ew`-class dispatches per CB, arms with M ∈ {0, 1, 4, 16, 64, 256, 1024}
   evenly-spaced global memory barriers; measure (a) host record time, (b) `vkQueueSubmit` time,
   (c) device execution via timestamp queries; ×3 reps. Expected: per-barrier GPU cost ~1–5 µs and
   CPU-side ~0.5–2 µs on RADV/NAVI21 — i.e. 2.5 k barriers ≈ 2.5–12 ms/token worst case, matching
   the §2.4 bound. If it comes in ≥10× higher, revisit §0's stop-finding for the *prompt* path
   (116 ops/frame chunks) first.
3. **Submit/fence round-trip ladder on this box.** k ∈ {1, 4, 16, 64, 256} one-dispatch CBs each
   submit+spin-wait, vs one CB of k dispatches waited once; with and without `amd_pstate`/
   sclk pinned. Re-measures the fork's 0.1 ms figure on the parity rig and quantifies the
   sclk-residency coupling the fork's own A/Bs hit; bounds any "merge submits" slice.
4. **Queue-topology A/B (knob exists).** `COLI_VK_TIER_QUEUE=0` (shared) vs default (own) on the
   standing ttft set and decode set, ×3 interleaved. Census prediction: decode ≈0 (tier waited
   0.5 ms/tok); prompt may move if the streaming sub-batches contend with chain frames on one ring.
5. **Fork submit census at tip.** One fork run with `COLI_VK_CB_SESSION=2` (trace mode) at the
   parity prompt; count open/commit lines per decode token. Expected 250–390 (§2.3). Log-only,
   settles the fork column of §2.5 exactly.
6. **Spin sweep.** `COLI_VK_CHAIN_SPIN_US ∈ {0, 2000, 5000}` × `COLI_VK_SPIN_US ∈ {0, 300}` on the
   decode set; G1 SF-3 bounds the result at 0–13 ms/tok — a confirm-only leg.

## 7. Source index (primary anchors)

Port code: `c/vk_chain.c:786-792` (barrier_now), `:817,834` (frame open/close barriers),
`:917-934` (hazard), `:2666-2676` (record_indirect), `:735-760` (frame_wait/spin), `:821-871`
(submit + d_submit_ms), `:683-689,885-893` (timeline semaphores); `c/backend_vulkan.c:1270-1320`
(queue pick), `:324-333` (g_qmx — only when the uploader shares the main queue), `:2439-2470`
(fence spin), `:5212-5216,5416-5570,5635-5661` (xb batch record/join/barriers); `c/vk_tier.c`
header (thread model), `:151` (T.mx/cv), `:598-700` (quiesce), `:2330-2560` (issue/join),
`vkt_settle :3466`; `c/vk_dmoe.h:605` (settle), `:625-627,671-673` (explicit barriers);
`c/deepseek_v4.c:8913-9021` (plain lookup, mutex-held read), `:10082-10240` (lookup_hot,
released), `:10624-10734` (hot store install), `:14132-14200` (v4_vkt_load/load_batch).
Fork code: `c/backend_vulkan.c:4163-4210` (sync model + spin), `:2451,2579` (single queue),
`:12880-13110` (fused expert group, 5–6 barriers), `:8600-8868` (attention segment barriers),
`c/deepseek_v4.c:13726-13755` (read_bytes, no mutex), `:13829-13945` (lookup_hot),
`:18480-18560` (ring thread/qd/take), `:10922-10990` (prefill telemetry).
Docs: `docs/research/V-g1-dprof-2026-10-24.md` (decode window), `X-ob0-s0`, `AC/AB-ob1-s3`,
`R-l1`, `C-perf-evidence`; fork `docs/decode-gpu-full-residency-review-2026-10-02.md`,
`PLAN_submit_merge.md`, `docs/vulkan.md` (composition tables).
