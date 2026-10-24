# Placement & submission census — fork vs port (comparative audit, 2026-10-25)

**Lane:** CPU-only, read-only on both trees. **Fork** = `/root/Projects/colibri-ds4-vulkan` @ `d11fba5b`
(demand misses honour the MFU/MRU split). **Port** = `/root/bench-worktrees/up2276-merge` @ current tip
(`port/up-2276`, S1/S3-era, chain-DPROF in tree).

**Evidence base (all legs the parity rig: RX 6900 XT / RADV, 2,515-tok prompt, 64 tokens,
`--memory-gb 28`, OMP 16, `vram0` at the 541 MB idle floor on every leg):**

- Fork (full fold: `COLI_DSV4_VK_DENSE=1 COLI_DSV4_VK_EXPERTS=1 COLI_V4_DIRECT=1`):
  `fork-r{1..4}`, `fork-full-r{3,4}` (2026-10-22/23) + **fresh same-day** `audit-fork-r{1,2}`
  (2026-10-24, `/root/bench-colibri/up2276/`).
- Fork ablation (VRAM expert tier off, `COLI_DSV4_VK_EXPERTS=0`): `fork-noexperts-r{1,2}`.
- Port controls: `p1-c0-r{1..3}`, `l2-c0-r{1..3}`, `s3-c3-r{1..3}`, `ob-s0-r{1,2}` +
  **fresh same-day** `audit-port-r{1,2}` (both `rc=0`; r2 finished mid-census). The lane also
  produced `audit-text-coding-fork.log` (a different prompt class — 218.7 GB payload, decode
  0.86 tok/s — noted as out-of-shape, not folded into the medians).
- Port instrumented: `dprof-a-r{1,2}`, `dprof-b-r1`, `dprof-c-r1` (G1/DPROF), bank arms
  `s1-{c1,d,k,n}-r*` (S1), order arms `s3-{c3,l,f}-r*` (S3).
- Campaign docs: `docs/research/{R-l1,S,T,U,V,X,AA,AB,AC,Z}*` in the port tree; specs
  `specs/G1-pipeline-gaps.md`; `plans/OB0-fold-transplant-plan.md`; fork's own
  `PLAN_submit_merge.md`, `PLAN_cache.md` and in-code measurement comments.

**Standing walls at the census shapes (medians):**

| | fork | port | gap |
|---|---:|---:|---:|
| TTFT s | 106.6 (103.4–108.2, 8 legs incl. today's) | 154.8 (151.9–159.6, 13 legs incl. today's) | **~48 s (1.45×)** |
| decode tok/s | 1.21 (1.16–1.23; today 1.18/1.20) | 0.556 (0.538–0.570; today 0.545/0.556) | **~2.2×** |

---

## 1. The memory map, side by side

Model facts both engines share: 43 MoE layers × 256 routed experts = 11,008 expert records; one
record = 3 tensors (2048×4096, 2048×4096, 4096×2048); ~254 unique expert visits per decode token
(16,254 decode visits / 64 tokens — identical counter both engines); card 16 GiB VRAM, 28 GiB
cgroup, same `.coli_usage`/`.coli_mfu` snapshots.

### 1.1 Prefill

| class | fork | port |
|---|---|---|
| dense weights | **VRAM only**, per-layer upload at boot (133–153 MiB/layer, fp8 + bf16 head 1010 MiB; `v4_dense_resident layers=43 bytes=6.267GiB`), host fp8 copies **returned to OS** after upload ("D7 … VRAM is the source of truth", per-layer lines; `fork-full-r3.log:71`+) | **VRAM only**: chain fit takes 43/43 layers, 6.79 GiB matrices + 50.6 MiB chain buffers, 7.11 GiB device-held (`p1-c0-r1.log` chain lines); 6.02 GiB host RAM given back; kept on host: norms, block scales, router, indexer proj, mHC mixes, head (RSS 1.3 GiB) |
| KV cache | elastic, `kv_base=0.06GiB` at this prompt; compressor/attention state device-resident in the cell pipeline | elastic, same `kv_base` class; chain owns attention state on device ("absorb attention", 4 streams) |
| activations | 128-token **cells**, activations live device-side between the cell's submits (PLAN_submit_merge §1 anatomy) | 2048-row **chunks** ("prompt chunks of up to 2048 rows"), segment inputs staged host→device per step — the STAGE mass (below) |
| routed experts — VRAM | **whole-layer bank**: 256 slots (one layer's entire expert set), fp4-elem slabs, filled by the ring take at every layer switch ("moe-batch=on bank=256-experts", `fork-full-r3.log:72`; `V4_GPU_BANK_MIB 3277` ≈ 3.2 GiB cap, `c/deepseek_v4.c:16638`) | **stream slots**: 256 device slots carved inside the 7.85 GiB tier budget, 8 stages × 16 MiB, cold experts with ≥4 rows only (`vk_tier.c` `st_alloc` :1342, budget print :3198; "stream: 86 steps, 10,482 cold experts (183.25 GiB, 8.16 GB/s)") |
| routed experts — host RAM | **ring**, 3.19 GiB mmap, exactly one layer's 256 experts, owned by the prefetch worker thread ("moe-ram=on ring=3.19 GiB qd=16 take=par", `fork-full-r3.log:23`); + the v5 CPU pool exists but prefill reads bypass it (`read_bytes` path, fork `deepseek_v4.c:13726`) | **store LRU** 48 slots/layer (2,064 slots ≈ 25.7 GiB target_cache) + stream fills **bypass it** (S2: `COLI_VK_TIER_STREAM_BYPASS`, fills read past the cache) + host pool 272 experts / 4 GiB pinned |
| routed experts — disk | one full pass per prompt: 11,008 records × 12.75 MiB = 137.4 GiB streamed through the ring (`prefetched=11008 consumed=11008`); run payload 199.8–202.8 GB | 10,482 cold experts × ~17.9 MiB = 183.25 GiB streamed (86 steps = 2 chunks × 43 layers, chunk-outer); run payload 250.4–251.0 GB (**1.24–1.25×** the fork's — R-l1 confirmed, §4) |
| per-expert record size | **12.75 MiB** (fp4-elem, 3 × 4,456,448 B; log `slab=12.8MiB`) | **15.0 MiB quoted / 28.8 MiB effective per slot** (fmt 7 fp8 gs 32, up+down; "budget 7.85 GiB = 277 experts", resident 7.81 GiB / 277) → **the fork packs 2.26× more experts per GiB of VRAM** |

### 1.2 Decode

| class | fork | port |
|---|---|---|
| dense weights | same VRAM set (untouched) | same (untouched) |
| routed experts — VRAM | **v5 GPU cache, MFU-ranked, demand-growing**: post-prefill refill installs 252 experts (`post-prefill refill target=252 installed=252`, `fork-full-r3.log:4093`); during decode 1,242 fp4 upload lines = **~414 more demand installs** (~6.5 experts/token — the non-resident visits being uploaded then computed on device); mid-decode a reorder pass is refused by the VRAM guard with **1,547 MB free** (`fork-full-r3.log:4857`) ⇒ 252 + 414 = 666 installs × 12.75 MiB ≈ 8.3 GiB of experts on the card at decode, toward `gpu_cap=954`. Victim policy = the MFU/MRU split controller (`d11fba5b`, `miss_demand_claim`) | **fixed 277-expert tier** (budget 277, 7.81 of 7.85 GiB, evictions **0**, frag 0.00), warm-started 549 from `.coli_mfu` history, ≤16 promotions/token, **decode device share 13.1–22.5%** ("decode: 2124 of 16254 routed experts on the device (13.1%)", p1-c0; 18.6% dprof-a, 22.5% dprof-b) |
| routed experts — host RAM | **v5 CPU pool: 1,982 slots × 12.75 MiB = 24.69 GiB** (`slots=1982 arena=24.69GiB`), pageable slabs; decode demand served by 6 async MoE lanes (read+compute jobs, default `COLI_DSV4_VK_MOE_LANES=6`) + 4-lane/12-inflight pilot prefetching the next hash layer (`v5-pilot: async lanes=4 max_inflight=12`) | **store LRU 2,064 slots** (decode `hit_rate_d=71.5%`) + **host pool 272 experts / 4 GiB pinned, device-readable over PCIe** (or 517–544 / 8 GiB in the DPROF legs); non-device visits computed **on the engine thread** (tier decode CPU 821.9 ms/tok, V-g1) |
| routed experts — disk at decode | **0 bytes** (`v4_tokens … expert_requests=0 … bytes=0` in every full arm — the store/disk path is never taken at decode) | **91.85 GB** (6,870–6,872 misses × ~13.4 MB; `bytes=91874131968`) |
| decode host compute for experts | async lanes overlap reads+compute with device work (fork's own A/B: decode after_first 69.2–71.9 → 55.3–57.1 s, ~+23%, `deepseek_v4.c` `coli_v4_moe_lanes` comment) | **inline**: 821.9 ms/tok of the 1,619.5 ms/tok wall (50.7%), plus 518.8 ms/tok forward glue (32.0%), waits 235.0 (14.5%) — V-g1's block decomposition closes exactly |

### 1.3 The same-budget question: what does each side hold WHERE, and where does decode expert compute run

Both engines spend the same budgets (≈ 6–7 GiB VRAM dense, ≈ 7–8 GiB VRAM spare for experts,
≈ 25.7 GiB host expert cache, 137–183 GiB disk). The differences are **placement and tenure**, not
size:

1. **VRAM expert set**: fork holds *one whole layer* (256 experts, fp4) during prefill, then a
   *growing, popularity-ranked* set (252 → ~600+) during decode; port holds a *fixed* 277-expert
   set (fp8, 28.8 MiB effective/slot — 2.26× fatter) for both phases, plus 256 shared stream slots
   it keeps re-filling chunk by chunk. Per GiB of VRAM the fork fields ~2.3× the experts AND
   rotates them by measured demand; the port never evicts (`evictions 0`).
2. **Decode compute location**: the port's own lines say 13.1–22.5% of decode expert visits run on
   device; the rest is host compute inline on the engine thread + 1.43 GiB/token of disk misses.
   The fork's decode expert requests never touch the store/disk path (`bytes=0`), its non-resident
   visits become ~6.5 demand uploads/token (~10 ms/token of PCIe — noise), and its host-compute
   remainder runs on 6 async lanes. The fork's own ablation prices the whole decode-side stack
   (`EXPERTS=1` vs `0`): **0.62–0.64 → 1.18–1.23 tok/s, a measured ~1.95×** — and the port's
   control band (0.538–0.570) sits *at the fork's no-tier arm* (0.62–0.64), i.e. the port currently
   realizes none of that lever.
3. **Prefill MoE compute location**: fork computes every routed expert on device from the
   whole-layer bank (one take per layer switch serves every chunk of that layer — chunk loop inside
   the layer loop, fork `deepseek_v4.c:18140`); the port streams 183.25 GiB of cold-expert weights
   per (chunk, layer) step and still runs 49.2 s of host-MoE (X-ob0 S0) — the stream dedups
   nothing across chunks (reuse distance ≈ 2–3.5 GiB, R-l1).

---

## 2. The submission model census

### 2.1 Fork, prefill: the cell pipeline

- Unit = **one cell = 128 tokens × 1 layer**; 2,515 tokens ⇒ 20 chunks × 43 layers = **860 cells**
  (the fork's own telemetry rig: 344 cells for a 982-token prompt, `PLAN_submit_merge.md:205`).
- Anatomy per cell (PLAN_submit_merge §1, shipped shape): 9–13 one-submit-then-fence stages —
  hc1 → attention prologue → comp_scan → [segment+deferred train, already ONE submit via the cell
  join] → hc2 → hc2b → route gate → **MoE bank (its own submit)** → hc3. Measured on the fork's
  rig: **4,167 submits / 344 cells ≈ 12.1 submits+fences per cell** (tail-merge QA lever on;
  `PLAN_submit_merge.md:209`); the design's 9→4 fence collapse (`M1–M3`) **stayed default OFF**
  — the merged tail was not bitwise (greedy-text flip), so the shipped path keeps ~12 submits/cell.
  For our prompt that scales to **~10–11k submits+fences for the whole prefill**.
- **Queue-ahead / join deferral is ON** in the parity runs: `[qa] join deferral ENGAGED (branch
  round on device, settle at tail close)` (`fork-full-r3.log:841`) — the joined attention segment
  submits with its fence left PENDING and the mHC tail records/submits while it executes
  (`backend_vulkan_dsv4.c:2439–2460`).
- Barriers: the fork's recorded design substitutes in-command-buffer `vkCmdPipelineBarrier` for
  fences when merging stages ("barriers replace fences", PLAN_submit_merge §3); no barrier counter
  is printed in these logs. Its own 2026-10-13 utilization probe (the plan's motivation) measured
  the stall class this fights: at 8.5–250k context a 128-token cell ran 80–119 ms wall of which the
  GPU executed only 38–67 ms, host main thread asleep 87% (26/30 samples in `drmSyncobjWait`),
  GPU idling ~52 ms/cell between per-stage fences.
- Expert-side submits are irrelevant to the fence chain: the ring stream is a pthread, the take is
  an OMP-parallel copy (see §2.3).

### 2.2 Fork, decode: the decode cell

Per layer per token the fork runs the dec2 shape — `[dec2 qkv + sync train + the standalone
attention segment]` merged into **one submit** (`deepseek_v4.c:2169–2340`, GPU-FOLD pass), plus the
mHC head/post tail session and the bank/demand-install submits: **~2–4 submits+fences per layer per
token, ≈ 90–170 per token** — the same order as the port's 87. No per-decode submit/fence counter
is printed in the parity logs; the class is established by the code shape above.

### 2.3 The copy-pipeline threading model (the manager's addendum #2 — made explicit)

This is the mechanism behind S0's staging-serialization finding (105.6 s). Where each side's
disk→RAM→VRAM expert pipeline executes:

| stage | fork | port |
|---|---|---|
| disk → host RAM | **separate pthread**, launched one whole layer ahead (`v4_ram_prefetch` → `v4_ram_worker`, fork `deepseek_v4.c:18684+`); O_DIRECT ("v4_ssd_io mode=direct-aligned"), qd 16 lanes (OMP team), reads all 256 experts of the NEXT layer (3.19 GiB) while the engine computes the current one. **`take_join_ms=0` in all 8 full-arm legs** (0–10 ms range) — the disk stage is never on the critical path. Per-stream mean 1,391–1,512 ms ≈ 2.2 GB/s, fully hidden inside each ~2.4 s layer window | **inline on the engine thread**: `vkt_stream_prefetch` (`vk_tier.c:1902`) is called between A1's submit and its fence wait (`deepseek_v4_chain.h:1452/1818`) — the *intent* is overlap with A1's attention, but the body is synchronous: `st_fill_group` does the disk reads via the engine's `load_batch` hook **on this thread** ("The engine loads them on this thread", `vk_tier.c:1434+`); only the pack/convert into slots is OMP-parallel. 8 stages of 16 MiB, bypass groups of 8 parallel reads (the fill group's hard cap is 64, `st_fill_group`) |
| host RAM → VRAM | **`take=par`**: at each layer switch the 256 ring→bank copies spread across the OMP team — **mean 332–334 ms per take** (735→404 ms measured when par landed, TTFT −23.8% @1k in the fork's own A/B, `deepseek_v4.c:18546+`); 43 takes total, one per layer | the same `st_fill_group` call: pack+upload per group, inline between A1 submit and wait; 86 steps (one per chunk×layer), 183.25 GiB total |
| VRAM → compute | device fp4 batch from the bank (`qmatmul_pf4_f16` packed / `qmatmul_pf4_id` expert-indexed, 256 experts) | device fmt-7 rows for streamed experts (≥4 rows), host rows below that |
| decode demand | 6 async MoE lanes (read+compute) + 4-lane pilot prefetch of the next hash layer's selections (`prefetch_hash_body`, fork `deepseek_v4.c:16540+`; "only the byte load moves to a lane") | ≤16 promotions/token inside the tier's own queue + host-pool pairs read over PCIe; non-device compute on the engine thread |

**The fork's answer is threads + queue-depth + IO-mode, all three:** a dedicated prefetch thread
(O_DIRECT, qd-16) one layer ahead, an OMP-parallel take at the switch, and async lanes at decode.
The port's pipeline is a *function call on the engine thread* with internal parallelism only in
the pack step. The measured consequence: the port's fills move 183.25 GiB at a reported 8.16 GB/s
*while filling*, but the STAGE role's wall is 105.6 s — **1.74 GB/s effective end-to-end** —
because the engine thread serializes fills with its own orchestration (the role stamping tiles the
window exactly: A1 4.0 + MOEH 49.2 + STAGE 105.6 + tail 0.1 + other 0.1 = 159.0 s, X-ob0). The
fork moves 137.4 GiB with **zero visible cost** in the same class (join 0 ms; the 14.3 s of
take-uploads across 43 switches is OMP-parallel and the disk half never blocks).

### 2.4 Port, prefill: frames

- Unit = one 2,048-row chunk × one layer (86 steps); each step = A1 frame (attention/dense) +
  A2 frame + staging around them. Whole-prefill submit count: run line 5,898 frames total, of which
  the decode window owns 5,481 ⇒ **≈ 417 frames for the entire 2,515-token prefill ≈ 4.8 per
  (chunk, layer)** — an order of magnitude FEWER submits than the fork's ~10–11k, and the port is
  still ~48 s slower: submit count is not the prefill differentiator (see §3 rows 10–11).
- Waits: 19.6–21.9 s per run ("ms waiting for the device"); submit time 8.8 ms for the whole
  prompt window (ob-s0).

### 2.5 Port, decode: frames, waits, and what they cost

- **86.99 frames and 86.98 fence waits per decode token** (5,481 submits / 5,480 waits over 63
  one-row forwards; dprof-a-r1 chain-decode line: `1 fwd, 5481 submits, 5480 waits`), ≈ 2 frames
  (A1+A2) per layer + 1 tail — the same shape as the fork's decode cell (§2.2).
- A1 fence wait 234.0 ms/tok vs A1 device 228.6 ms/tok — **97.7% of the wait is device time**;
  the wait−device excess is 5.16–5.58 ms/tok across all four DPROF legs; `vkQueueSubmit` itself
  4.2 ms/tok. G1's verdict (ARTIFACT) stands on these numbers: there is no recoverable
  pipeline-gap pool in the port's decode submission discipline.

### 2.6 Barrier microstructure (the manager's addendum #1)

- **Port**: barriers are counted (`KC.st.barriers`, incremented at `vk_chain.c:791` frame-open /
  hazard transitions and `:2674`; field in `VkcStats`, `vk_chain.h:858`) but the engine's run
  report does not print them at the parity shape — only `vk-chain-check`'s harness does, where the
  one recorded measurement is **28,704 barriers / 10,594 frames = 2.71 barriers/frame**
  (E-baseline.md). If that ratio transferred to the parity run it would be ~230 barriers/token at
  decode (87 frames) — the "~500/token" class at the low end — but the transfer is not
  established (the check workload's op mix is different: 0.62 ops/frame there vs 31.7 ops/frame at
  parity), so the census states it as a derived estimate, not a measurement.
- **What the evidence bounds**: barriers are same-queue, in-command-buffer execution dependencies
  (they are the port's designed *replacement* for fences, `vk_chain.c:10–12` — the same trade the
  fork's submit_merge plan makes). Their total cost at decode cannot exceed the measured
  submission-discipline mass: **wait−device excess 5.5 ms/tok + vkQueueSubmit 4.2 ms/tok ≈
  9.7 ms/tok ≈ 0.6% of the 1,619 ms/tok decode wall**. At prefill the whole wait mass is
  19.6–21.9 s vs STAGE+MOEH ≈ 155 s. So even a several-hundred-barriers-per-token delta is
  arithmetically incapable of being a top-3 lever; it is a bounded-dead class, not an untested one.
- **Fork**: no barrier counter in its logs; its cell design records multi-stage groups per command
  buffer with internal barriers (cell join, tail session) and its own probe prices the *fence*
  (host round-trip) class it merged away: GPU idle ~52 ms/cell pre-fix (§2.1).

### 2.7 What overlaps what

| work | fork overlaps it with | port overlaps it with |
|---|---|---|
| expert disk reads (prefill) | next-layer compute (ring thread, 1 layer ahead; join 0 ms) | A1's device attention only, and only while the engine thread is inside the prefetch call (STAGE 105.6 s says it mostly doesn't) |
| expert RAM→VRAM (prefill) | the take is OMP-parallel at the switch; measured 332 ms/switch | same inline call; no separate thread |
| prefill MoE compute | on device from the bank, inside the cell's bank submit | host-MoE on the engine thread (49.2 s) between A1/A2 frames |
| decode expert demand | 6 async lanes + 4-lane pilot; uploads ~10 ms/token | ≤16 promotions in the tier queue (waits 0.49 ms/tok) + inline host compute 822 ms/tok |
| successive frames/cells | queue-ahead join deferral (prefill; log `:841`); dec2 merged decode cell | A2 recorded behind A1 in the same window; frames wait per frame (87 waits/token, 97.7% device) |

---

## 3. The reconciliation — every identified behavioural difference

Cost/gain column = measured where a leg measured it, otherwise derived from the engine's own
printed counters. Campaign column cites the T/U/V/X/AA/AC/S7/G1 outcomes.

| # | difference | fork | port | measured / derived cost | campaign coverage | verdict |
|---|---|---|---|---|---|---|
| 1 | **Prefill expert fill threading** (disk→RAM) | separate pthread, O_DIRECT, qd16, one layer ahead; join 0 ms | inline on engine thread; STAGE 105.6 s of 159 s TTFT (66%) | **105.6 s measured mass** (X-ob0); fork's equivalent cost invisible (join 0) | X measured it; S1 tested the bank *beside* the stream, not the threading; nobody moved the fill off-thread | **never-tested** |
| 2 | **Prefill expert VRAM residency model** | whole-layer 256-expert bank, one take/layer serves all chunks | 256 stream slots refilled per (chunk,layer); 183.25 GiB re-streamed | dedup loss ≈ the stream bytes beyond one pass (183 vs 137 GiB ≈ 46 GiB ≈ 5–6 s) + the bank's compute value | S1 K-arm (bank+stream coexistence) **+341.5 s MISS**; N-arm isolated carve cost; K−D banked-layer compute value **−12.4 s TTFT / −15.9 s MOEH ≈ 4× the 3.5 s/layer ceiling** (AA) | **partially-tested** (coexistence dead; the fork's shape — no stream, ring-fed bank — untested) |
| 3 | **Prefill MoE compute location** | on device, fp4 bank batch (qmatmul_pf4_f16/id) | 49.2 s host-MoE (MOEH) + partial device rows | **49.2 s measured** (X-ob0); fork's prefill MoE device-side inside the cell | L2-B fmt-7 rows landed (TEXT identical, no wall change, T); DMOE chunk arms declined at the driver hang boundary (T/U); S3 F-fold **+401.4 s MISS** (cold-start ordering gate: dmoe 0 steps ×4) | **partially-tested** (machinery exists; never fed by an always-ahead fill) |
| 4 | **Prefill loop order** | layer-outer (chunk inside layer) | chunk-outer (layer inside chunk) | S3 measured order alone: TTFT null (153.62 vs C3 154.84), decode +4.9% real | S3 L-order arm (AC) | **tested-dead** (TTFT) |
| 5 | **Prefill activation staging** | 128-token cells, device-resident | 2048-row chunks, h2d segment staging per step (inside STAGE) | included in the 105.6 s; S1's ROWS_MAX split held with **no device loss** (first chunk-scale dmoe without the hang); S3-F reservoir collapse 2.6 GiB → chunk fit 2048→256 | S1 (AA), S3 (AC) | **partially-tested** |
| 6 | **Decode VRAM expert set: size, format, tenure** | 252 refill + demand installs → ~600+ (guard: 1,547 MB free), fp4 12.75 MiB, MFU/MRU split victims | fixed 277, fp8 28.8 MiB effective, evictions 0, ≤16 promotes/token; share 13.1–22.5% | fork's own ablation **1.95× decode** (0.62→1.21); port's tier-CPU term 822 ms/tok | S1 D-arm single-layer inert (−0.54%); PROMOTE=0 > PROMOTE=32 cross-day side datum (0.658 vs 0.608); OB0 S5 cancelled after S3 | **partially-tested** (never at fork scale/format) |
| 7 | **Decode host expert compute threading** | 6 async read+compute lanes + 4-lane pilot (fork's own A/B +23% decode) | inline on engine thread (822 ms/tok, 50.7% of wall) | 822 ms/tok measured (V-g1); lanes priced +23% by the fork | never ported; G1's R3 promote-gate slice closed (wrong mechanism) | **never-tested** |
| 8 | **Decode expert disk traffic** | 0 bytes (pool+bank cover all) | 91.85 GB (6,870 misses) | ~1.43 GiB/token; S7 §5d bound: removing misses ≤ +19% decode | S2 bypass was prefill-side; store policy = fork parity (S7) | **partially-tested** |
| 9 | **Decode store hit-rate policy** | 1,982-slot pool, MFU/MRU split controller | store LRU + 16 pins/layer, `hit_rate_d=71.5%` vs fork 68.5% | parity (matched populations) | **S7** | **tested (parity)** — and moot: the fork's fast arm doesn't use the store at decode |
| 10 | **Decode submit/fence count & discipline** | ~2–4 submits/layer/token (dec2 cell) | 87 frames+waits/token; excess 5.5 ms/tok | 0.6% of decode wall | **G1/DPROF (V)** — ARTIFACT | **tested-dead** |
| 11 | **Prefill submit/fence count** | ~12/cell, ~10–11k total | ≈417 total | port is the *cheaper* side and still slower | G1 (V); S0 (X) waits 4.0 s | **tested-dead** (not a lever) |
| 12 | **Barrier microstructure** | in-CB barriers by design (no counter printed) | counted, not printed at parity; 2.71/frame at the check workload (derived ~230/token) | bounded ≤ 5.5 + 4.2 ms/tok decode; ≤ ~20 s waits prefill | bounded by V/X measurements; never separately instrumented at parity shape | **bounded-dead** (small residual unknown) |
| 13 | **Queue-ahead / join deferral (prefill)** | engaged (`[qa] join deferral ENGAGED`) | frames submit-then-wait; staging between | prefill waits only 4.0 s — little to recover | G1's S1/S2/S3 slices closed unfunded (V) | **never-tested, bounded small** |
| 14 | **Expert storage format (density)** | fp4-elem, 12.75 MiB/record (disk+VRAM+CPU path) | fmt-7 fp8 gs32, 15.0 MiB quoted / 28.8 MiB effective/slot | 2.26× experts per GiB; directly gates rows 2/6 | L7 tested *dense projection* formats, not expert records | **never-tested** |
| 15 | **Host RAM layout under the same 28 GiB** | 24.69 GiB slot pool + 3.19 GiB ring, dense dropped (D7) | 25.70 GiB store + 4–8 GiB pinned host pool + 0.25 GiB dense | both project 27.6–27.8 GiB; placement differs (one pool vs store+pool) | S7 (store), H (host-pool), L2-C pool-layer | **tested (parity-ish)** |
| 16 | **Dense/KV placement** | VRAM-only both sides, ~6–7 GiB | same | no measured divergence | baselines | **n/a — no gap** |

### Ranked never-tested differences by expected contribution to the measured gap

1. **Off-thread, always-ahead expert fill (the ring class)** — row 1. Owns 105.6 s of the ~48 s
   TTFT gap's neighbourhood (the bucket is 2.2× the gap; even partial overlap of the fills with
   A1/device work directly attacks it) and is the prerequisite for rows 2–3 ever working.
2. **Decode expert placement at fork scale** — rows 6+7+14 together: fp4-density slabs, a
   demand-growing VRAM set (toward gpu_cap), split-direction victims, async lanes for the host
   remainder. Priced by the fork's own ablation at ~1.95× decode ≈ 784 ms/tok of the port's
   measured 822 ms/tok tier-CPU + part of the 519 ms/tok glue.
3. **Whole-layer on-device prefill MoE fed by (1)** — rows 2+3: S1 already measured the banked
   layer's compute value at ~4× the per-layer ceiling; S3's failure was the *feed* (cold-start
   ordering gate), not the compute.

---

## 4. Adversarial pass on our own prior conclusions

- **S7 (store hit-rate parity) — verdict upheld, inference trimmed.** The parity claim survives
  re-reading against the fork's logs: port `hit_rate_d=71.5%` vs fork `68.543%` on the matched
  decode-only population (16,254 requests both sides). But the fork's 68.5% is measured in its
  **noexperts** arm — in the fast arm (`EXPERTS=1`) the decode store path records **zero** requests
  and **zero** bytes. "Store hit-rate parity" is parity of a component the fork's fast
  configuration does not use at decode. The campaign's table at the time read S7 as closing the
  *residency* question ("decode-only already at fork parity"); the fork's own full-vs-noexperts arm
  pair contradicts that reading — the decode gap is expert **placement/threading**, which S7 never
  touched. (The campaign later corrected course via DPROF/S1; the census logs the contradiction
  formally.)
- **G1 (no pipeline gap) — upheld, no contradiction.** The fork's own evidence (87%-asleep host,
  52 ms GPU idle/cell, 2026-10-13) is a *prefill, pre-fix* number that motivated its cell/join
  design; its decode cell (dec2) converges on the same ~2-submits-per-layer shape as the port's
  A1/A2. The port's measured 5.5 ms/tok wait−device excess and 4.2 ms/tok submit cost bound the
  entire submission-discipline class at decode on both sides. G1's artifact verdict stands.
- **R-l1 (byte economy 1.24×) — upheld exactly.** Fresh same-day legs: fork 199.82 GB
  (audit-fork-r1/r2 identical) vs port 250.44 GB (audit-port-r1) = **1.254×**; the 2026-10-22 set
  gives 1.24–1.25×. At 8.0–8.6 GB/s that is ~5.9–6.4 s of the ~48 s TTFT gap — real but minor; the
  fork's 12.75 MiB record vs the port's ~17.9 MiB streamed/expert is the fp4-vs-fp8 density
  difference (row 14) showing up in bytes.

One more fork-log check the census forces: the fork's prefill MoE is **not** free even for it —
43 × 332 ms ≈ 14.3 s of take uploads sit inside its 106 s TTFT — but they are OMP-parallel and
overlapped; the port's analogue (STAGE) is 7× larger and serialized. The asymmetry is threading and
residency, not bytes.

---

## 5. Top-3 never-tested candidates (with code anchors)

1. **Move the port's prefill expert fill off the engine thread** (ring-class prefetch worker, one
   layer ahead, O_DIRECT, qd-parallel). Port anchors: `c/vk_tier.c:1902` `vkt_stream_prefetch`
   (synchronous body), `c/vk_tier.c:1434` `st_fill_group` ("The engine loads them on this thread"),
   call sites `c/deepseek_v4_chain.h:1452` and `:1818` (beside A1's wait). Fork anchors:
   `c/deepseek_v4.c:18684` `v4_ram_prefetch` + `v4_ram_worker` (the pthread), take/join counters
   printed at `c/deepseek_v4.c:18847`. Target: the 105.6 s STAGE bucket (X-ob0), fills currently
   183.25 GiB at 1.74 GB/s effective vs the fork's invisible 137.4 GiB.
2. **Decode expert tier at fork scale**: fp4-density records (2.26×/GiB), demand-growing VRAM set
   with split-direction victims, async lanes for the host remainder. Port anchors: `c/vk_tier.c:1342`
   `st_alloc`, `:3198` the budget line, S1's carve/tenure (`vkt_bank*`, landed `33136aa2`), the
   promote policy (≤16/token). Fork anchors: `c/gpu_mfu_cache.c:190–258` install/demote + `:166`
   the MRU-first clamp, `c/deepseek_v4.c:15716` `v4_cache_engine_create`, `:16105–16184`
   boot/refill, `d11fba5b` `miss_demand_claim` (`c/miss_path.c`), the lanes default at
   `c/deepseek_v4.c` (`coli_v4_moe_lanes`, +23% fork-measured). Target: 822 ms/tok tier CPU +
   91.85 GB decode misses; priced ~1.95× by the fork's own `EXPERTS=1/0` pair.
3. **Whole-layer on-device prefill MoE bank fed by (1)** — S3's second driver
   (`v4c_forward_seg` layer-major, landed `f6930b1a`, default off) plus S1's ROWS_MAX frame split,
   with the fill always-ahead so the all-or-nothing dmoe gate never sees a cold bank (S3-F's
   measured failure mode: dmoe 0 steps ×4, reservoir collapse 2048→256). Port anchors:
   `c/deepseek_v4_chain.h:1224` (chunk-outer loop) vs the fork's `c/deepseek_v4.c:18140` nesting
   ("one bank upload per layer serves every chunk"). Target: the 49.2 s MOEH bucket; S1 already
   priced the banked layer's compute at −12.4 s TTFT / −15.9 s MOEH per layer ≈ 4× the 3.5 s/layer
   ceiling.

---

## 6. Stop-findings

**No stop-finding.** The census does *not* show the port holding/computing the same things the same
ways — placement and submission differ in exactly the places the walls sit:

- **Prefill (port 159.0 s window, tiles exactly, X-ob0):** staging-upload **105.6 s (66%)** +
  host-MoE **49.2 s (31%)** + A1 host 4.0 s + waits 4.0 s + tail/other 0.2 s. Both big buckets are
  expert-pipeline placement (inline fills; host MoE) — rows 1–3 of the reconciliation.
- **Decode (port 1,619.5 ms/tok, closes exactly, V-g1):** tier MoE CPU **821.9 (50.7%)** + forward
  glue **518.8 (32.0%)** + chain waits 235.0 (14.5%, 97.7% of it device time) + head 72.9 −
  overlap 29.1. The two host masses are the decode fold — rows 6/7/14.
- Submission discipline (submits, fences, barriers, queue-ahead) is measured or bounded dead on
  both sides at both phases (G1 artifact; §2.6 bounds; the port already submits ~25× less than the
  fork at prefill and the same ~87/token at decode).

The remaining time provably sits in the expert copy pipeline's threading and the expert compute's
location — the fork's own ablation legs price the decode half at ~2× and S0/S1 price the prefill
half at 105.6 s + 49.2 s per run.
