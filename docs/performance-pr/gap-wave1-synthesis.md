# gap-wave1 synthesis — why the fork is still ~345 ms/tok faster at decode (and 36–44 s at TTFT)

Date: 2026-10-27+. Manager-run investigation wave, 5 read-only lanes, no code changed, no GPU runs.
Lane artifacts: `subagent-artifacts/outputs/4f22348a-*/gap-wave1/{joinwait-anatomy,residency-mix,overlap-map,ttft-prefill,inventory-anomalies}.md`
(session store; copy on request). Inputs: W-CS logs (`/root/bench-colibri/up2276/wcs-*`), fork @ `d11fba5b` (frozen),
port `port/cs-experts` @ `53e26ea6`, `port/up-2276` @ `ac3e0067`, `diag/cs-timing` @ `29c4966e`.

Anchor numbers (re-verified from raw logs by two lanes independently): fork 899.8 ms/tok (1.1113 tok/s),
PGCS 1,243.8 ms/tok (0.8040) → gap **343.9 ms/tok**. TTFT: fork 109.5 s, PGCS 153.8, PRC 145.9.
PGCS decode: fence wait 302.7, device 138.0, deferred window 683.6 ms/tok; 16,254 routed visits =
3,103 resident (19.1%) + 13,151 aliased (80.9%); 0 CPU experts. Two independent accountings close to ≤0.5%.

## 1. Two corrections that reframe the campaign record

**P1 — the fork's shipped arms did NOT run the zero-copy GPU-slab expert fold.**
`COLI_DSV4_VK_GPU_EXPERTS` defaults 0; its boot line is absent from every campaign fork log; runners set only
`COLI_DSV4_VK_EXPERTS=1`. The fork's 1.1113 tok/s decode is a **hybrid**: one fused GPU group for the VRAM-resident
share + **6 CPU compute lanes for the rest** + pilot read-ahead (one layer early, no route compute needed).
`why-fork-faster-synthesis.md` §2's "no host MoE at decode / lanes are read feeders" describes a config that never
ran. Consequence: **CS and lanes compose** (the fork is the existence proof) — re-ranks the port roadmap.

**P2 — the port is a re-implementation, not a lagging port.** 0 of the fork's 356 post-upstream commits exist in the
port (0 shared SHAs, 0 patch-ids, disjoint shader suites: 106 fork-only vs 126 port-only `.comp`). "Unported fork
win X" can only be argued mechanism-by-mechanism. Mechanism shortlist with fork-side claims: demand lanes +23%
(port got +3.3% at its operating point), MHC decfuse +19% (ported, honest −6.7 ms/tok), **deep qd16 prefill ring
take — genuinely absent** (this is TTFT F1/F3's mechanism), GPU prefill bank, decode attention cell (+4.1%),
prefill submit structure. Also: the "1.135 headline" is a 17-leg corpus median (1.1317); same-session is 1.1113.

**Report defect:** `session-wcs-report.md` §2 "window A (ms/tok)" mixes units (F "56.7" is actually 899.8 ms/tok;
P0 "1123.4" is 1,783.6; PGCS "783.6" is 1,243.8). Fix before anyone quotes it.

## 2. Decode gap — current honest attribution

Agreed by all lanes (add to ruled-out): chain/A1 at parity (A1 wait residual 4.5 ms/tok — G1's 196 ms/tok gap did
NOT survive into the CS world), generic fence/submit overhead, glue (~18.5 ms/tok), kernel quality (device = PCIe
read of aliased slabs at **20.2 GB/s sustained = link saturation**, ~0% kernel headroom at this mix), submit-count
discipline (both sides one group per layer-token, serial — parity), "43 serial round-trips" as leading cost,
`cs-deferjoin` as wired (degenerate: joins the group submitted microseconds earlier; salvage its instrumentation,
keep the park).

| term (PGCS, ms/tok) | best current split | confidence |
|---|---|---|
| device 138.0 | aliased-expert PCIe reads at saturation; **40–57 vs fork** from residency mix (19.1% hit vs fork ~45–55% at 666 residents) | high (20.2 GB/s reconciliation) |
| window 683.6 | **UNRESOLVED — the wave's central conflict**, see below | needs 1 DPROF leg |
| wait residual 164.7 (302.7−138) | destroy-side alias churn 135–155 (joinwait lane) vs fence/queue/TLB fixed cost (residency/overlap lanes) | needs same leg |
| merge/tail host (S3) | ~35–48 (fork fuses tail into the group submit; `xb_step_sum` S=1 arm prices it) | medium |
| settle/read-exposure (S1) | reads issue at MoE entry; fork issues one layer early (pilot) | structure proven, size unknown |

**The central conflict.** Joinwait lane: window ≈ alias/import **churn** 535–655 + destroy 135–155 (per-aliased-expert
2.6–3.2 ms of driver object create/destroy: import pins ~3,200 pages, 6 VkBuffers, 4 desc sets, 786 KB scale scan —
fork pays 3 callocs over a persistent slab). Inventory + overlap lanes: window ≈ the **store re-read itself** —
the loader reads every aliased expert's 12.8 MiB into the store slot each token (2.67 GiB/token); 683.6 ÷ 208.7
aliased = 3.28 ms/expert = 12.8 MiB at 3.91 GB/s, i.e. the whole window is one read pass at a plausible mixed rate;
plus the natural experiment: standing arm window 880.6 with 9,858 CPU experts → CS window 683.6 with 0 — only ~197
went away (the overlapped compute), so whatever owns the window, **CS didn't touch it**. Per-op cost estimates
differ by ~10× between lanes (µs-scale vs ms-scale RADV import cost) — exactly what the instrumentation decides.

**Single discriminator (all lanes agree):** one `diag/cs-timing` DPROF leg (PGCS + PGRT control). Its buckets split
settle / alias-build / issue / fence / qread / device / release and count `slab import create vs hit`. Instrumentation
is verified ready EXCEPT two ~15-line gaps that should land first: (1) isolated `coli_vk_slab_import` span (build
bucket currently merges import+alias+desc — the leading sub-hypothesis is not separable), (2) a settle **byte**
counter (to convert 683.6 ms into GB/s and settle the 2.67 GiB/token vs 0.78 GB/tok read-parity bookkeeping —
likely disk-class vs RAM-class counter classes; the most consequential open item).

**Residency cause (why 80.9% aliased):** three stacked config/structure facts — `STREAM_SLOTS=256` carves places
to idle-at-decode staging; the CS group path skips `vkt_note` (only decode-growth install site) so TARGET=800
installs 0; and the growth guard reads device-wide free VRAM (0.0 KiB, the tier pool pre-allocated it) so even a
note would refuse. Fix shapes pre-assessed: slots sweep (pre-registered predictions: slots 64 → decode ~1,195–1,232
ms/tok, residents ~563; slots 2 diagnostic-only), note-wiring + pool-netted guard, two-tier slab keepalive/alias
cache (content-agnostic import keepalive = the 90% win; **mandatory** `coli_vk_slab_forget(ptr)` hook against
VA-reuse stale mappings; deeper pool-promotion variant needs `VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT` at buffer
creation and unlocks the grouped GEMV single-dispatch path the fork uses).

## 3. TTFT — parity is reachable with levers that already exist

Timer placement verified identical both sides (not an artifact). Decomposition (PGCS +44.3 s vs fork): port
device chain is actually **faster** (−20..−23 s); the gap is fills/orchestration: engine-thread staging 105.2 s
(the fork hides 147 GB of reads in a qd16 ring pthread, exposing only a 14.3 s take) + MoE orchestration +31.7 −
device −92.6. PRC moved staging off-thread (1.1 s) but exposed A1 waits and grew MoE window +27.7 (ring joins/
contention). Two un-run, already-landed levers dominate the residual:

1. **PRC ran without flash attention** (env list has no ATTN_FA). FA arm measured prefill device 69.8→28.6 s.
   Predicted PRC+FA ≈ **104–115 s** — at/near fork parity. Never run. Highest-value single TTFT leg.
2. **R=4 kept-rows rule leaves 5,408 rows on CPU (23.7 s)** while the run's own break-even measurement (upload
   1.69 ms vs CPU 4.391 ms/row ⇒ break-even ≈ 0.4 rows) says the rule should keep nothing. `STREAM_ROWS=1`
   predicted −15..−19 s.

Combined prediction: **PRC + FA + STREAM_ROWS=1 ≈ ~97 s** vs fork 109.5 — TTFT parity before any new code.

Also corrected: fork TTFT is not "flat ~102 s" — it is max(ring-floor, compute) with an **84–90 s plateau for
~0.5k≲N≲1.9k** (whole-model 147 GB read regardless of routing), then linear. Crossover re-estimated **1.2–1.8k
tokens**; HANDOVER's "~535" is unsourced (no committed log derives it). Fork prefill-only structures with no port
counterpart: single-segment layer-major prefill, persistent 256-expert VRAM bank, QUEUE_AHEAD/CELL_TAIL submit
structure, no-row-threshold bank dispatch.

## 4. Anomalies closed

- **4.4 ms vs 1–2 ms per-expert CPU**: accounting artifact (window ÷ count, includes reads/packing); true compute
  P50 3.2–3.5 ms; **zero contribution under CS** (0 CPU experts). Dead as a gap term.
- **rows16-hit n=793 while packed_slots=0** (same-run contradiction): open, cheap code-read, matters only if a
  future arm re-arms CPU experts (8.5 ms outlier class).
- **Env deltas beyond the documented CS set** (from log heads): port pins 16 slots/layer from autopin history (fork
  ignores autopin entirely — real placement delta); fork ring depth 3.19 GiB/qd16 vs port 8×16 MiB stages (24×);
  `COLI_VK_PROFILE=RDNA2` implies 4 effective port-only envs; GROW×4 inert under CS (0 installed).

## 5. Decision package (owner-gated; campaign paused, rig exclusivity)

- **D1 (code, ~15 lines, DPROF-only, diag branch)**: isolated slab-import span + settle byte counter + printed
  residual on `diag/cs-timing`. Unblocks clean falsification of the window conflict.
- **D2 (one gated bench session, W-CS-class)**: PGCS-DPROF + PGRT-DPROF (decode attribution — the discriminator);
  PRC+FA; PRC+FA+STREAM_ROWS=1 (TTFT parity test); STREAM_SLOTS=64 (residency falsifier; predictions pre-registered
  in residency lane §3). Optional: one fork leg with fork-side counters (fork 900 ms decomposition is unmeasured —
  prices the CPU-lane share and re-ranks lanes-vs-device-share).
- **D3 (no rig)**: fix the session-wcs-report unit defect; record P1/P2 corrections into campaign docs; reconcile
  read-volume counter classes (disk vs RAM).
- **D4 (after D2)**: pick the decode lever — keepalive/alias-cache vs pilot read-ahead vs slots/growth — against
  the measured buckets; pre-registered predictions already written for each.

Working target: fork 899.8 ms/tok. If the window is churn → keepalive predicts wall ~570–700 ms/tok (1.4–1.75 tok/s,
i.e. **past the fork**); if the window is the read → read-ahead/pilot + residency growth predict recovering most of
~300–550 ms. Either way the fork's hybrid (P1) means the port should stack CS + lanes, not choose.
