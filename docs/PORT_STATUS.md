# colibri-upstream — port status

**Status:** active · recursive merge onto `upstream/dev` @ b90a369e complete · 2026-10-22
**Repo:** http://ai-container.local.lan:3000/pi/colibri-upstream
**Integration branch:** `port/up-2276` (worktree `/root/bench-worktrees/up2276-merge`)
**Base:** `upstream/dev` @ `b90a369e` (v2.0.0 + ~767; 177 commits past the previous base `a0037a3a`)

## The 2026-10-21/22 recursive merge (`port/up-2276`)

Upstream moved 177 commits (tier promote #2258, host-pool CPU compute series,
hybrid pairs, verify-row GEMV sharing, GGUF dense chains, the CUDA tier).
All four landed slices merged onto the new tip, slice by slice:

| # | slice | conflicts | notes |
|---|---|---|---|
| 1 | `pr/strict-gate` (COLI_VK_STRICT) | Makefile (union), vk_tier.c tag rewording | + `coli_vk_degrade` no-op macro for cu_tier.c's second compile; + 2 `bd_fmt` REFUSE sites upstream added; `norm` masks `N us` lines |
| 2 | `pr/tier-host-pool` (RAM-plan pool sizing) | vk_tier.h/.c, test_vk_tier.c, CHANGELOG | semantic resolution vs upstream's #2258 `ram_floor`/`ram_given`: plan = cap on the same `want`, floor subtraction skipped for planned engines (double-count guard); colibri.c hunk **dropped** (it silently disabled upstream's landed pool behaviour); `cut_host_room` mirror for the CUDA double-compile; `.spv` blobs dropped; ENVIRONMENT.md rows deduped |
| 3 | `perf/vk-dsv4-gemm-refs` (PR #2253) | CHANGELOG only | merge-tree-clean (verified); upstream's V4.1 chain adopted the same `vkc_gemm_rows()` pattern |
| 4 | `port/kv-cold-v2` (P1.1 KV cold tier) | .gitignore only | deepseek_v4.c auto-merge verified hunk-by-hunk (upstream's serve/CUDA hunks sit outside the checkpoint region) |

**Regression found and fixed during the merge:** the cold tier's store
dropped pin captures under `v4_ckpt_min_tokens()` and prompt-ends at
`V4_PREFIX_CKPT_DISK=1`, breaking the numeric channel's pin contract
(`test_deepseek_v4_brio` second-option reuse=0). Pins now also take a memory
slot (any length, upstream's contract) and restore checks slots before the
catalog. Caught by `deepseek-v4-tiny-check` on a freshly generated fixture.

**Also landed on the branch:** `make deepseek_v4` (bare) is no longer a
silent no-op (`.PHONY` alias recursing into Makefile.deepseek-v4) — the trap
behind mfethe1's build note on PR #2253.

**Gates (all green at the merge tip):** `vk-tier-check` (incl. upstream's
promote/hybrid/pool-copy/host-pairs + our host_room/host_plan), `vk-chain-check`,
`vk-strict-check`, `deepseek-v4-tiny-check` (23 PASS), `test_v4_serve_framing`,
`cu_tier.c -DCOLI_CUDA -fsyntax-only` (the CUDA double-compile).

**PR #2253 (chain GEMM):** open; positively validated by mfethe1 on M4 +
MoltenVK (default byte-identical, `-1` engages, wiring mutation-checked,
deterministic). No change requests yet.

## Benchmarks (2,515-token prompt / 64 decode tokens, 28 GiB budget, interleaved arms)

| arm | TTFT s | decode tok/s | wall s |
|---|---:|---:|---:|
| upstream tip, defaults (×2) | 266.1 / 264.3 | 0.603 / 0.613 | 370.5 / 367.0 |
| upstream tip, `COLI_VK_TIER_HOST=0` | 257.4 | 0.584 | 365.4 |
| **`port/up-2276`, defaults** | **251.9** | 0.603 | **356.4** |
| **`port/up-2276` + `COLI_VK_CHAIN_GEMM_ROWS=-1`** | **238.8** | 0.598 | **344.3** |
| upstream, `--memory-gb 18` (pool 16.0 GiB) | 258.2 | 0.625 | 358.9 |
| `port/up-2276`, `--memory-gb 18` (pool 512 MiB) | 262.0 | 0.551 | 376.3 |
| (old fork reference, same methodology) | 105–107 | 1.16–1.18 | ~160 |

Upstream's tip improved decode over the previous base (0.487 → 0.60) via the
host-pool CPU-compute series; TTFT regressed at this budget with the pool on
(266 vs 257 host-off). Our merged tree keeps upstream's decode gain, beats
both upstream arms on TTFT (−5 %), and the GEMM knob stacks to −10.3 %. The
18 GiB pair is the F13 evidence: upstream grants 16 GiB beside a 17.65 GiB
plan (survives by lazy faulting alone); ours grants the plan's 512 MiB spare
— the safety contract, with the decode trade stated in the night report.

## Portfolio re-assessment vs the 177 upstream commits (docs/research/M3-portfolio-vs-2276.md)

- **Superseded:** P2.2 (async PILOT — upstream's `vkt_join` computes host
  experts before waiting), P3.4 (idxsel v2 — upstream's indexer mode 10 is
  57× vs our 4.2×), P4.1 largely (slots/pool-copy series).
- **Still ours to port:** P1.2 (reactive prefill fit), P1.3 (KV usage
  budget), P3.2 (pf4/RDNA2 expert GEMM family — the one kernel class gfx1030
  still lacks), P3.3 (flash attention, 8k-gated), P3.5/P3.6 (conditional on
  re-baseline).
- **F14-v2** (DSV4 `chain_bytes` from the real prompt chunk) remains the only
  blocker on the 8k road; v1's flat reserve was measured +11 % TTFT and
  reverted — v2 must be context-aware.
- F12 (`COLI_NO_OMP_TUNE` value check) is **not** a bug: presence-based is
  documented as intentional family-wide behaviour ("any value, even 0,
  disables"). Left alone.

## Day-2 state (2026-10-22, later)

Three slices landed on `port/up-2276`: the MXFP4 grouped GEMM (mode 4, fmt 7's
first grouped route), promotions from a partial host pool (the MFU ladder on
upstream's #2258 machinery, `COLI_VK_TIER_PROMOTE` opt-in), and the
slot-churn finding (`COLI_VK_TIER_STREAM_SLOTS` widened = the fork's bank,
mostly). Best arms: TTFT **194.9** (slots 256 + gr4), decode **0.654**
(pool 8 + promote), balanced **201.3 / 0.583 / 309.4** (all-in, 24 GiB plan).
Upstream-default baselines: 266 / 0.603 / 370. The fork still leads ~1.9×;
the remainder is the ring/whole-stack overlap and mm8 (parity-class).

## Next gates

1. finish the overnight arm chain (GEMM_ROWS, 18 GiB pair)
2. re-pin `.golden` against b90a369e + re-record (8 h budget stands)
3. decide the PR queue: #2253 follow-up (Makefile fix) → strict-gate →
   tier-host-pool (now composed with #2258) → cold tier
4. F14-v2 design before any 8k claim


## Session 2026-10-23 (the parity campaign, manager-run)

Landed on port/up-2276 (through 9739c812): mm8 tiled fp8 GEMM (reviewed; PR branch pr/vk-mm8 staged off upstream/dev @ 05a5bca5), COLI_VK_PROFILE (RDNA2), S1+S2 stream bypass (COLI_VK_TIER_STREAM_BYPASS), the rig's VRAM guard, the L3 overlay (default-off capability). Numbers: TTFT record 187.7 (stacked) -> 148 (S1+S2, replicated), decode record 0.670. Fresh fork A/B: 103-106 s / 1.15-1.17 tok/s — remaining gaps: TTFT 1.40x (loop order + ring = Option B), decode 2.1x (engine-store hit-rate 35% vs 68.5%).

Falsified (see HANDOVER-2026-10-23.md §2): mm8-as-decode-fix, tier-side hot-set placement (L3 neutral, replicated), whole-layer dmoe (TTFT doubled), byte-economy-as-2.8x (counter mismatch; 1.24x real).

PORT_PLAN below is the 2026-10-19/22 decision record; its F-number statuses are historical. The live queue is in HANDOVER-2026-10-23.md.

## Session 2026-10-23 II (the parity campaign, manager-run — wave 2)

- **Upstream 176-commit range merged** (b90a369e..7398a85f): merge `4740f41f`, report `docs/research/N2-up176-merge-report.md` (`707cf2e3`). All gates green at tip. The vk-strict-check intermittence is **pre-existing** (base `3064378e` fails 1/12 with the identical signature; the tier exit `frag N.NN` ratio is unmasked by `norm`) — a `frag` mask is queued as a PR candidate; 1 PASS in ≤3 runs is the accepted protocol.
- **L7 (F8 decode projections) closed NO-GO at Step 0** on the pre-registered rule: the fmt-12 S=1 GEMV bucket is 57.3 ms/tok = **13.1 % of the 439 ms/tok decode device wait** (< 25 % bar); a perfect kernel buys ≤ 2.5 % of the decode wall. Decode attribution now: wall 1,770 ms/tok = device wait 439 (24.8 %) + host ≈ 1,331 (75 %); only 20.5 % of routed experts device-resident; buckets MLAW 71.1 > attn 63.8 > fmt-12 57.3 > mHC 36.1 ms/tok; new observation: ~200 ms/tok fence-vs-timestamp pipeline gap. Logs: `bench-colibri/up2276/gemv8-step0-prof-{8,24}.log` (manager's rig dir; copy into `bench/up2276/` at the next arm commit).
- **L2 Stage B landed** (`5a165efc`): `vkc_moe_rows` takes fmt 7 through the mx pipelines (`KC.mod_mx/mx/mx_tried`, `mx_pipe()`, 36-B push constants, prewarm `ex_mx`); fmt-7 rows vs chain_moe 1.16e-9 / 3.78e-10 (gate 1e-4); kind-2 router oracle added (ids exact, weights 2.24e-7, ties bit-equal). Full gate set green; CUDA double-compile green.
- Next: L2 Stage A (V4 wiring, `COLI_VK_DMOE_ROWS` opt-in, tiny-check-dmoe) then the serialized bench window with a fresh post-merge control baseline (C0/D1/D2 arms per the L2 spec §7).

- **L2 Stage A landed** (`a46908a3` → `a8c7e3dc`, ff to `port/up-2276`): the DSV4 one-layer dmoe arm (`COLI_VK_DMOE`) re-landed from `port/dmoe-s1` (vk_tier.c PIN_LAYER hunk dropped — base's `0c6ddae2` superset kept), `COLI_VK_DMOE_ROWS` opt-in for chunk rows, the arm's report line, `deepseek-v4-tiny-check-dmoe` (token-exact on every case; 16 layer steps in-frame). D1 negative control verified empirically byte-identical (armed-off run cmp-equal, counters equal; tier-off declines via prepare-fails). All gates green on run 1. Next: the serialized bench window (C0/D1/D2 ×3 interleaved, fresh post-merge baseline) per the L2 spec §7.

## Session 2026-10-24 (the L2 bench window)

- **The window ran** (C0/D1/D2 ×3 interleaved, RDNA2 + S1+S2 on every arm, `7063a502`): the arm declines safely in every D-run (0 dmoe layer steps — Stage C's `COLI_VK_TIER_POOL_LAYER` is not in this tree, so nothing can hold a layer resident), generated text byte-identical across all 9 runs, decode delta +0.17 % (inside the ±1 % band — the wiring is orchestration-cheap), prefetch 12563/10535 invariant. **K1**: route (b)'s trigger does not fire (per-pair 0.22× the grouped path's time at S=1 — it is 4.5× faster), Stage B's chunk number 47.7/99.1 ms a layer-visit at 512/2048 rows; a rig boundary found and recorded (frames of ~2–4 s GPU work hard-recover on amdgpu — microbench-only). Report: `docs/research/T-l2-arms-2026-10-24.md`; logs in `bench/up2276/l2-*` + `k1-*` (+ the L7 Step-0 `gemv8-step0-prof-*` copies). Stage C's go/no-go now hinges on landing the pool lever and its arm clearing the pre-registered bands.

- **L2 Stage C landed** (`fcea8272`, ff to `port/up-2276`): `COLI_VK_TIER_POOL_LAYER` — one layer's experts pool-placed (`set_place(v,2)`, all-or-nothing with a transparent decline, `hot_pin` + a promote guard keyed on the pool layer). The premise held: `vkt_dev_table` counts host-pool residents (no `!v->host` exclusion; BDA entry real via `pool_bda`). End-to-end proof in the tiny gate: with `TIER_GB=0.0002 HOST_GB=0.01 POOL_LAYER=1 DMOE=1`, layer 1 ran **8/16 layer steps hybrid (0 in-frame) — the gate opened with zero device residency**, token-exact. All gates green run-1. Next: bench window 2 — the P1 arm at model scale (pool ≈ 256×15 MiB ≈ 3.75 GiB host RAM; mind the cgroup trap), prefetch-collapse guard armed, fresh C0 control.

## Session 2026-10-24 II (bench window 2 — the P1 arms, manager-steered)

- **The window ran at model scale with the pool funded** (`6fe02794`, native rebuild — the checked-out binary predated Stage C by mtime): memory config `RAM_GB=28` + `COLI_VK_TIER_HOST_GB=4` on **every** arm incl. the control (the operator-sized pool sits on top of the plan; cgroup 34 GiB left ~1.6 GiB slack at the observed 29.9 GiB peak — no OOM, no plan shrink needed). **P1 (ROWS=1) engaged and the first 2048-row chunk killed the device**: the placed line, then `radv/amdgpu: The CS has been cancelled... guilty of a hard recovery` + `queue submit failed (-4)` — K1's hang boundary at arm scale (the armed layer's chunk visit is seconds of GPU work in one submission); recorded, not retried (a row cap per submission is a code slice, the manager's next decision). **P1d (decode-only, the steer's arm) engaged clean ×3**: `63 layer steps through the dmoe path (0 in-frame, 63 hybrid)` — the Stage C mechanism at model scale, deterministic. Per-rule: prefetch guard holds (C0' 12041, P1d 12275 vs 12563 — −4.2/−2.3 %); TTFT +1.7 s inside the ×3 band (the P1 improvement band untestable on this rig); decode −1.44 % median inside D2's ≤3 % band, no win — the layer's bus-bound work is shuffled (tier-hybrid → dmoe-hybrid), not removed; text diverges at char 122 mid-generation, the reassociation class, deterministic. Drift: C0' vs window-1 C0 = TTFT −1.08 s / decode +4.4 % (the pool's own fingerprints, unseparated). Report: `docs/research/U-l2-p1-arms-2026-10-24.md`; logs `bench/up2276/p1-*`. The evidence supports two follow-ups: (a) a frame-split slice for prefill dmoe, then re-run P1 for the TTFT question; (b) decode-only dmoe holds but does not pay on this evidence — it needs L3-class residency to remove the bus.

- **G1 S0 landed** (`d602436a`, ff): `COLI_VK_CHAIN_DPROF` — the decode window's wait/device split by role (A1/A2/dmoe/tail/other) + tier decode-dprof + CLI block/tok; default off byte-identical; gates green run-1. Next: the instrumented legs (a/b/c) apply the G1 spec's R1-R4 — the ~200 ms/tok pipeline-gap hypothesis gets settled.

## Session 2026-10-24 III (G1's instrumented window — the pipeline gap settled)

- **The legs ran, G1 closes NEGATIVE (ARTIFACT)** (`6d57f849`, native rebuild; exclusive rig, `vram0=541057024` on every leg, rc=0): decode set ×2, promote-off ×1, ttft set ×1, `COLI_VK_CHAIN_DPROF=1 COLI_VK_CHAIN_PROF=2` throughout. R1 fires on every leg — **(A1 wait − A1 device) ÷ 63 one-row forwards = 5.49 / 5.58 / 5.16 / 5.53 ms/tok** (bar: 25): the A1 fence wait (~229–244 ms/tok) is 97.7 % chain device time; the step-0 pair's ~196 ms/tok "gap" was method error (its leg-diff assumed equal prompt waits while the prefills diverged — the prompt's ~17 s whole-run wait mass is visible in these legs' own chain lines). R3's premise dies (no leg > 100; promote on/off moves the term 5.49→5.16; tier decode waits 0.49 ms/tok both ways — H1's 612 MiB promote traffic does not sit under the fences). R4 no escalation (−186…−202 ≪ 500). S1/S2/S3 all close unfunded. **The wall, decomposed by printed numbers for the first time** (a-r1): wall 1619.5 = chain waits 235.0 (14.5 %) + **tier decode MoE CPU 821.9 (50.7 %)** + forward glue 518.8 (32.0 %) + head 72.9 − 29.1 — the §2.4 pool is the pool lane's ~1.34 s/tok, G1's ceiling a rounding error against it. Side datum for the pool lane: `PROMOTE=0` beats `PROMOTE=32` on wall (1496 vs 1619 ms/tok, decode 0.6577 vs 0.6077) via tier placement (device-served share 22.5 % vs 18.6 %) — a residency effect, not a pipeline one. **Two hazards recorded:** (1) the profile's ttft fill + the decode 8 GiB pool do not compose at `RAM_GB=28` (first leg (a) attempt with `COLI_VK_PROFILE=RDNA2`: rc=137 oom-kill, 27.7 G peak — `dprof-a-r1-oom.log`; legs a/b ran the step-0 standing set, no profile, per the manager's call); (2) S0's chain line "N fwd" counts window *openings* (1 for a contiguous decode stretch) — divide by the CLI line's one-row forwards (63), not N. Report: `docs/research/V-g1-dprof-2026-10-24.md`; logs `bench/up2276/dprof-*`.

## Session 2026-10-24 IV (D11 — the golden re-pin at 073a03b6, the pre-Option-B baseline)

- **D11 golden re-pinned at 073a03b6, the pre-Option-B baseline** (lane D11-golden, exclusive rig, `vram0=541057024` throughout, 4.56 h of the 8 h budget): the fork's `scripts/vk_golden_parity.sh` re-rooted onto this tree (`a46dad8d`, minimal deltas — leg C arms `COLI_VULKAN=1`; real legs `+V4_PREFIX_CKPT=0 COLI_V4_PREWARM=0`), pin `--upstream-ref=073a03b6` so the banked fixtures are **this tree's own pre-surgery CPU-path outputs**. Two full gates (deploy+pinned, short 9 tok + long **2179 tok**): tiny GREEN ×3 legs both runs; **CPU channel GREEN everywhere** (token-exact, and R2's independent leg-A records byte-identical to R1's — all four fixtures sha-equal); **greedy byte-identical on every leg of both runs** (9/9, 24/24, CPU and GPU-env alike). Pinned HARD gate prints RED on the GPU-env leg's TF bar (17/18 short; 887/900 deploy, 891/900 pinned) — root cause: the port's oracle path **arms the real Vulkan stack** (dense chain + tier, 12.7 % routed experts on device), unlike the fork's CPU-bound-by-construction oracle leg (`docs/golden-parity-cost.md` §3 in the fork), so this leg is a true GPU-vs-CPU comparison the repo's own contract holds to the F8 thresholded envelope, not token-exact. Manager ruling: baseline **accepted**; the RED is the envelope, not a regression. **Baseline diff contract for Option-B stages** (diff against `.golden/cache/073a03b68452ecb6b1b3e9138838d72d5bf95817/`): PRIMARY = greedy byte-identity; SECONDARY = CPU TF token-exact; GPU-env TF = count-band vs the banked counts (and position-diff within a config — flip sets and values are run-stable: deploy 13 flips, pinned 9, identical across independent runs). Harness quirks recorded (env-override doc drift, dead A-vs-A probe, per-prompt leg-file overwrite); the fork's `.golden` (dd7df2c9 pin) untouched. Report: `docs/research/W-d11-golden-2026-10-24.md`; logs `bench/up2276/golden-*`.

## Session 2026-10-24 V (OB0 S0 — the prefill DPROF window, lane ob-s0)

- **OB0 S0 landed on `port/ob-s0`** (from 563bb643, anchors verified unshifted vs the plan's 073a03b6): the decode DPROF (`d602436a`) widened with the **prompt window** — `vkc_dwin(2)` per chunk, role-stamped host timeline (`p_host_ms` tiles the window wall exactly; `VKC_R_MOEH` = the host-MoE step at `deepseek_v4_chain.h:1419-1429`, `VKC_R_STAGE` = the staging uploads), the frame counters by role, the tier mirror for `S > VKT_UP_ROWS` (`| prompt dprof:` waited/device/host, span issue→join), `chain prompt:` beside `chain decode:` and `v4_dprof prompt:` beside the timing line. Default off, byte-identical (base-vs-S0 tiny A/B: tokens/PASS lines identical, noise-only diff; `DPROF=1` still oracle-exact). Gates green run-1 (chain incl. `test_dprof` extension, tier, strict, tiny ×2, serve-framing, cu_tier syntax); `vulkan_engines.sh deepseek` is environment-blocked on this rig (Lavapipe-scoped DSpark assertions; proven pre-existing at the stashed base). **The measurement (ttft set + `DPROF=1 PROF=2` ×2, `bench/up2276/ob-s0-r{1,2}.log`, reps ±0.7 %): TTFT 159.6/159.1 s, window wall 159.0/158.4 s = host-MoE 49.2/49.1 s (31 %) + staging-upload 105.6/104.9 s (66 %) + dense A1 4.0/4.2 s host (device 70.2 s fully overlapped, host waits 4 s) + tail 0.1 — §1.2's ~90 s host-MoE estimate is retired with its attribution inverted: the TTFT mass is the chunk-outer **staging serialization** (10,482 cold experts, 183.25 GiB at ~1.74 GB/s end-to-end through the 256 slots), not host expert compute; inside the 49 s the tier mirror reads waited 17.4 + host 26.0 + ~5.8 engine. S3/S4's levers aim at the measured dominant mass; S1's per-layer ceiling ≈ 3.5 s (2.4 staging + 1.1 MoE); the dense half is confirmed fork-class and off the critical path. Report: `docs/research/X-ob0-s0-prefill-dprof-2026-10-24.md`. No stop rule fires (no hang/device loss/ledger drift; vram0 the idle floor both legs).

## Session 2026-10-24 VI (OB1 S1 — the VRAM expert bank + the frame-split cap, lane ob-s1)

- **OB1 S1 landed on `port/ob-s1`** (from 473fd669, the charter's anchors re-verified and adapted — drift table in the report): `COLI_VK_TIER_BANK_LAYER` — one layer's experts planned whole to the device (place 0, pinned, all-or-nothing), paid for by an explicit carve of the **stream slots'** budget (256 slots ≈ 3.75 GiB → DeepSeek V4's 256 MXFP4 experts at the standing arm; one boot ledger line; four one-line declines leave the plan the history's), a per-layer validity bitmap with **at-most-once refill** at the routed step (post-router pre-issue, through the bypass group reader), and the fork's layer-switch rotation as an **explicit** `vkt_bank_switch` seam (the engine's fill never switches — the chunk-outer order would thrash a place a layer; the first cut did exactly that at tiny and was fixed to the charter's "BANK_LAYER=n never switches"); plus `COLI_VK_DMOE_ROWS_MAX=R` — the chunk's rows in ≤R-row groups with `vkc_submit+vkc_begin` between them (the amdgpu hard-recovery boundary as a knob; `vkc_moe_rows` gained float-unit `x_off`). **No `deepseek_v4_chain.h` change**: the landed dmoe arm picks the banked layer up through `vkt_dev_table` (item 7 verified — the bank-armed tiny legs ran 40 layer steps **in-frame** through the gate, token-exact, incl. the composed `BANK=1 DMOE=1 ROWS=1 ROWS_MAX=8` brio leg). Gates on the final code: tier/chain/strict ×3/tiny ×2/tiny-dmoe/serve-framing/cu_tier-syntax all **PASS** (the split-vs-unsplit unit is **bit-identical** at equal rows; the 2-layer rotation case green both ways); `vulkan_engines.sh deepseek` environment-blocked as at the base (v41 leg, identical signature at the stashed 473fd669). **Byte-identity vs the D11 pin (`--quick`, levers off, leg A cache-hit): GREEN — greedy 9/9 everywhere, CPU TF 18/18 both configs, GPU TF at the bar (18/18; an interim run sat in the documented pos-7 envelope band, identical to Y's flip)**. No bench arms (the window is the manager's). Report: `docs/research/Z-ob1-s1-vram-bank-2026-10-24.md`.

- **OB-S1 landed** (`33136aa2`, ff): the VRAM expert bank — `COLI_VK_TIER_BANK_LAYER` (all-or-nothing place-0 carve with boot ledger + declines, hot_pin + promote-skip, bitmap/at-most-once bypass-reader refill, quiesce-time marking, `vkt_bank_switch` explicit for S3) + `COLI_VK_DMOE_ROWS_MAX` frame split. Gates caught the auto-switch thrash (chunk-outer order) → rotation made explicit per the charter; 2-layer case green both ways (3.4e-7); split units bit-identical ×3; byte-identity GREEN per the D11 contract. Next: the S1 bench window (engagement guard, decode/chunk/no-bank legs vs the measured ≈3.5 s/layer ceiling).

## Session 2026-10-24 VII (the S1 bench window — the VRAM bank at model scale, lane ob-s1-bench)

- **The S1 window ran** (`030a875b`, native rebuild; exclusive rig, `vram0=541057024 B` after all 15 runs, rc=0 ×15, ×3 same-day interleaved C1/D/K/N + one DPROF rep per armed arm): **C1** med TTFT 158.459 / decode 0.5364 / wall 275.730; **D-bank** (`BANK=26 DMOE=26`) 512.380 / 0.5335 / 630.499; **K-bank** (+`ROWS=1 ROWS_MAX=512`) 499.945 / 0.5357 / 616.681; **N-bank** (`DMOE=26 ROWS_MAX=512`, no bank) 159.121 / 0.5432 / 275.505. **Engagement, deterministic ×3**: the carve ledger `bank=layer 26, 256 experts (3.75 GiB), the stream slots' budget 256 -> 0` (slot-for-slot exact — the charter's "~2" predates r3's arithmetic), run line `256 of 256 valid, 0 refilled` (warm start filled them; at-most-once held, no thrash), D's dmoe line **63 layer steps (63 in-frame, 0 hybrid)** — P1d's falsified hybrid class answered: the compute reads VRAM — K's **73 in-frame** (63 decode + all 10 chunk windows), **no device loss** (the `ROWS_MAX=512` split holds at model scale; U's P1 hard-recovery class is gone), N's gate never opens (0 steps, decline line, 97.0 % share). **The guard trips on the banked arms**: device-served share 36.2 % (D) / 37.5 % (K) vs 97.0 % (C1/N ≥ ~87.3 % bar) — 0 stream slots ⇒ the `stream:` clause vanishes, disk loads 6.9 k → 58–59 k. **DPROF (S0's line, how the carve moved it)**: STAGE 105.6 → **0.2 s** (banked arms) but MOEH 49.2 → **448.1/432.2 s** (the 42 non-banked layers fell out of the slots onto disk-bound CPU loads) and A1 4.0 → **72.5 s** (the 70 s dense GEMM de-overlapped across 10 windows — the chunk fit drops 2048→256 rows under the bank); N reproduces X's line exactly (49.5/105.1/2 windows). **Decisions per the charter, verbatim**: (1) decode leg **MISS** (−0.54 % median vs the ≥ +1 % bar; the ~19 ms/tok one-layer ceiling is inside the window's 2.1 % noise — the inert N arm read +1.27 %) → records "single-layer decode tenure is not worth arming", no cancel; (2) chunk leg **VERDICT MISS** (TTFT +341.5 s, guard tripped, no device loss) → **records "persistent bank cannot coexist with chunk-outer streaming — 98fcee51's answer at bank scale"**, nothing cancelled — S3/S4 proceed; (3) vs the ≈ 3.5 s/layer ceiling: confirmed at the uncarved shape (N's buckets), and the banked layer's isolated chunk value is **K−D = −12.4 s TTFT / −15.9 s MOEH** (~4× the ceiling at the disk-bound carved shape) — compute pays, the carve (≈ 28× the value) is the miss, S3's layer-outer reorder is the only regime where they meet; (4) N separates cleanly: N ≡ C1, so the whole regression is carve, zero of it bank-compute. **Text (D11 contract)**: C1 3/3 byte-identical + identical to window-2 C0′; N byte-identical to C1 (armed-but-inert exact); D and K each deterministic ×3, first divergence vs C1 at char 0/token 1 (the carve moved the device-served set → near-tie flip, coherent text), K vs D at char 180/31 words (chunk frame-path numerics) — all inside the count-band. **Machinery clean** (no hang/device loss/ledger-VRAM drift/off-arm non-identity) → **no cascade-cancel; S3's gate stands**. Report: `docs/research/AA-ob1-s1-arms-2026-10-24.md`; logs `bench/up2276/s1-*` + `summary.txt` (15 lines). Operator note: one guard refusal inside a scope-teardown race (2,703 MiB transient) — settle-to-floor between back-to-back arms.

## Session 2026-10-25 III (PW-C2 — the V4 chain's flash-attention tile, lane pw-c2)

- **PW-C2 landed on `port/pw-c2`** (from `0c847722`, the worktree `/root/bench-worktrees/pw-c2`): `COLI_VK_CHAIN_ATTN_FA` — the fork's `sparse_attn_fa` family (the census' rank-2 untested kernel deficit, never ported) on `vkc_dsv4_attn`'s own contract (`chain_dsv4_fa.comp`: mode 0's bindings and push constants, so the call dispatches either): the llama.cpp tile (Br 8 prefill / Br 2 decode twin, Bc 16, LDS-staged K/V with K == V, online softmax, the sink end block) against mode 0's per-(head,row) two-pass scalar kernel at fp32 — the census' ~32x the KV bytes per attended row. The f16-KV half ships as the fork's numerics class on a port-shaped carrier: the fork stored its ring/pool fp16 (its standing arm, retired ON); this port's stores are device copies, so `chain_dsv4_fa_gather.comp` rebuilds a **read-side f16 mirror** one dispatch ahead (round-to-nearest, the fork's storage conversion) into a grown scratch — same class, half the read bytes, nothing permanent, zero writer surface, and every refusal (hd != 512, heads % 8, unaligned q/o/w/c offsets or strides, missing pipeline) falls back to mode 0 (never a misread; the KV-split path untouched). **Route decision**: wiring V4 to the existing `chain_attn_flash` was falsified on its contract (hd ≤ 256 vs 512; a contiguous causal cache vs the per-token selection list over ring+pool; no sink path; GQA-per-kv-head dispatch vs MQA) — the fork's shader was written for this op and ports with a `kv_load` swap. **Unit oracle** (test_vk_chain, the scalar reference, bit-stable double runs): 4.06e-3 f16 / 2.28e-4 V4.1-class / 3.97e-3 prefill tile / 6.53e-3 worst small-list fp32, against the 8e-3/2e-3 mode-0 bars (the fork's own gate 2e-3) — **thresholded class pre-registered per D11 wherever it engages** (the `KQ_MAX_OFFSET` moves the bf16 probability rounding's scale); **token-exact at tiny holds** — the fixture is head-dim 32, the tile's gate is 512, the armed lever is shape-inert (proven: tiny CPU / `COLI_VULKAN=1` / `COLI_VULKAN=1`+lever all PASS). **Unit-scale engagement** (this box's RX 6900 XT, the model's decode geometry): 1,920 -> 228 µs a layer-dispatch (**8.4x**, ×43 ≈ 9.8 ms/tok — the fork's own ~10, inside the −40…−55 expectation off V-g1's 63.8 bucket); a 256-row chunk 304 -> 6.0 ms (**51x**, the f16 halving the byte floor); the FA records under `PK_ATTN` so the DPROF bucket is the window's counter, `VkcStats.attn_fa` the engagement line — **no model-scale legs run** (the window's read). Gates all **PASS**: vk-chain (12,039 frames, four FA cases + engagement + the armed-fallback case), vk-tier ×2, vk-strict ×2 (one earlier fail was the script's unmasked tier-stat jitter — the base tree passes the same gate, pre-existing), tiny ×3 legs, serve-framing, cu_tier syntax. Report: `docs/research/AG-pw-c2-fa-flash-attention-2026-10-25.md`.

## Session 2026-10-25 I (OB-S3 — the layer-outer prompt reorder, lane ob-s3)

- **OB-S3 landed on `port/ob-s3`** (from 9a138417; the charter's anchors re-verified — drift table in the report, all seams moved by S1's own insertions only): `COLI_VK_CHAIN_ORDER=layer` — the prompt loop reordered **layer-outer** (the fork's own prefill order: every chunk of the prompt crosses a layer before the next begins) behind a default-off env whose unset value runs today's chunk loop **untouched** (byte-identical by construction; proven GREEN vs the D11 pin). The reorder keeps the prompt's streams resident across a layer's pass (`xall`; the units copy rows in/out of the chunk's scratch), lowers each layer's attention mirrors at **its own head** against a pre-pass snapshot of the window rings (the KV-contract crux — the live `slot_pos` follows the earlier layers' chunks), lays the chunks' lists/RoPE tables **side by side** on the device (each unit reads the chunk it visits), and drives **the bank's rotation** (`vkt_bank_switch` at each layer head over the quiescent tail; one at-most-once fill a tenure; each layer's first chunk pays the host step while the fill publishes) — the regime where the bank stops coexisting with the streaming and becomes it. `COLI_VK_DMOE=all` is the minimal lo..L arm (per-visit gate lookup, hash/gate-less layers masked; declines with one line without the reorder). **The gates caught two real bugs** in the first cut (the later layers read the last-built chunk's lists — the numerics law's exact symptom, the ECHO logits moving with the cut while the tiny oracle stayed token-exact; then a host-buffer overflow) — fixed by the per-chunk regions; the landed path is **bit-equal to the chunk order** (streams compared at rows 2/3/4) and token-exact on every oracle incl. the composed fold (`ORDER=layer BANK=1 DMOE=all ROWS_MAX=8/2`: `bank: layer 2, 4 of 4 valid, 4 refilled`, `2/4 in-frame`, hash layer masked). Gates all **PASS** (tier/chain 11,966 frames/strict ×3/tiny ×2/tiny-dmoe 63 lines incl. three new legs/serve-framing/cu_tier syntax); `vulkan_engines.sh deepseek` env-blocked pre-existing (v41 leg, identical signature **proven at the stashed base 9a138417**); **golden parity `--quick` ALL HARD GATES GREEN** (levers off, leg A cache-hit, vram0 the idle floor before/after). No bench arms (the window is the manager's; the r3 bars — STAGE <53 s, MOEH <25 s, or TTFT ≤134 s — are read against S0's line). Recorded for the manager: the DMOE=1+ROWS=1 brio pin check can flip standalone against a run-mutated `.coli_usage` (pre-existing at base, proven; the gate target regenerates the fixture and is deterministic-green) — a gate-policy decision. Report: `docs/research/AB-ob1-s3-layer-order-2026-10-25.md`.

- **OB-S3 landed** (`f6930b1a`, ff): the layer-outer prompt reorder behind `COLI_VK_CHAIN_ORDER=layer` (default chunk untouched) — a second driver whose unit is the chunk path's layer body; the per-chunk `lbase` regions and snapshot-based per-layer-head lowering (the KV contract); the bank rotation at each layer head; the minimal `COLI_VK_DMOE=all` lo..L arm. Gates caught 2 real bugs (list-region read, host-buffer overflow) — both fixed; bit-equal to chunk order at GEMM_ROWS=0; token-exact everywhere; 63 PASS on tiny-check-dmoe at tip; golden `--quick` ALL HARD GATES GREEN. Next: the S3 window vs the r3 bars (STAGE <53 s AND MOEH <25 s, or TTFT ≤134 s).

## Session 2026-10-25 II (the S3 bench window — the layer-outer reorder and the composed fold vs the r3 bars, lane ob-s3-bench)

- **The S3 window ran** (`54405ce0`, native binary fresh at the landing; exclusive rig, `vram0=541057024 B` before every launch, settle-to-floor between arms, rc=0 ×11, ×3 same-day interleaved C3/L/F + one DPROF rep of L and F): **C3** med TTFT 154.840 / decode 0.5546 / wall 268.141; **L-order** (`CHAIN_ORDER=layer`) 153.618 / 0.5816 / 261.949; **F-fold** (AB's unit-leg composed form at model scale: `+TIER_BANK_LAYER=1 DMOE=all DMOE_ROWS=1 DMOE_ROWS_MAX=512` — the spec's `auto-if-exists-or-per-layer` parse does not exist; the rotation is code-driven, the env takes the integer boot layer) 556.222 / 0.5770 / 665.075. **DPROF (the r3 bars)**: L **STAGE 101.8 / MOEH 47.0** (X's 105.6/49.2 essentially unmoved — at the 2-chunk shape a layer's chunks route to mostly disjoint experts, so reuse distance 43→0 has nothing to reuse; stream counters ±1 %); F **STAGE 0.5 / MOEH 484.2 / A1 72.4 exposed** (the carve again: 2048→256-row chunks, slots 256→0, disk loads 6.9 k→13.3 k, tier prompt host 397.8 s). **The fold's key machinery finding**: the dmoe arm took **0 layer steps ×4** — the in-frame half never opened at model scale (the all-or-nothing prepare needs a layer whole at the forward's head; the history tier never holds one, AA's N-arm; the bank fills only during the loop — a cold-start ordering gap; the prefill's decline took a silent path, two candidates bounded in the report, not instrumented), while the rotation itself ran to design: **43 tenures (boot 1→0→…→42), 7,757 at-most-once fills = 113.63 GiB exactly 15 MiB a fill, no thrash, ledger exact ×4**. Share guard: C3/L 97.0–97.1 % (holds), F 50.0 % (trips, the banked class). **Text (D11)**: all nine arms byte-identical to the control **and to window-2/3 C1/C0′** — first-divergence counts 0 everywhere; the reassociation class never engaged (per-row GEMV is location/order-neutral; the grouped path that flipped AA's D/K took zero steps). **Decisions, verbatim**: both bar branches MISS on both arms (STAGE<53 AND MOEH<25 fails; TTFT ≤134 fails) and the falsifier fires (L −1.2 s ≈ null inside the control's 6.2 s spread; F +401.4 s) → **S3 verdict MISS: "keep S1/S2, cancel S4, S5 shrinks; the fold's TTFT claim closes as measured negative"** — recorded; the window prices the fold's cost side at model scale and leaves its compute side unmeasured (the gate gap, recorded for the manager). Machinery CLEAN (no hang/device loss/ledger drift; no cascade-cancel). Decode: no regression — L +4.9 %, F +4.0 % medians (every armed rep ≥ every control rep; a post-prefill tier-state effect, noted for S2). Report: `docs/research/AC-ob1-s3-arms-2026-10-25.md`; logs `bench/up2276/s3-*` (11) + `summary.txt` + the settle-to-floor driver `s3-arm.sh`.

## Session 2026-10-25 III (PW-C1 — the parity wave's kernel slice 1, premise-falsified, lane pw-c1)

- **PW-C1 closed PREMISE-FALSIFIED, no code change** (`port/pw-c1` @ `0c847722` + docs; GPU gate-class runs only, no benchmark arms): the pre-registered slice "move the LM head matmul host→device, −60…−70 ms/tok" attacked a placement the port already has — the head matmul has run on the Vulkan device at the standing config since **`9f4eb917` (2026-10-02)**, the prompt tail and every decode token, through `head_scores_impl`'s per-matrix branch (`coli_v4_vk_matmul(11, …)` → the generic bf16 S=1 GEMV) with logits/argmax on the host exactly as the fork's `dsv4_cuda_head_argmax` (the fork's fused `final_argmax` is an unwired stub on the fork too; the router gate matvec is likewise already device-side at standing — the audits' "kept on the host" lines are the DHO host-RAM-copy placement print and the chain header's in-frame-ownership comments, not compute placement). **Evidence**: a gdb breakpoint census at tiny/standing (every `head_argmax` call hits `v4_vk_matmul_impl`, decode included; 32→64 GPU matmuls at 8→16 tokens, 0 with `COLI_VK_DENSE=0`); exact model-scale count decompositions at two chunkings (2945 = 43×63 gates + 64 heads + 4×43; 2859 = same + 2×43); the close-line arithmetic (941 matrices = 897 chain + head 1010.0 MiB + 43 gates 86.0 MiB). **The residual, recorded**: the 72.9–88.1 ms/tok head term is the per-op wall of the device call — submit + fence wait absorbing queued chain-A2/tier/promote work + the 1.06 GB GEMV + readback; unmeasured on the fork (no head-term print), so the port-vs-fork delta inside the term is unknown and the −60…−70 was never there. Follow-up ledger (PORT-NOVEL, needs fresh pre-registration): in-frame head/tail fusion riding the chain's existing tail frame. Corrections to `audits/shader-census.md` rows 13/14 and `audits/cpu-parity-census.md` §2/§5-item-2 ride in the AF doc (the audits stay as-committed, historical); the kernel track re-ranks — the FA attention tile (+f16 KV) is now the top kernel candidate. **Gates** (standing behaviour certified, no code to gate): chain (11,966 frames) + tier PASS, strict 2/3 PASS on the documented pre-existing intermittence, tiny oracle `COLI_VULKAN=1` all-PASS token-exact — the D11 greedy channel on the standing device-head path. Report: `docs/research/AF-pw-c1-head-2026-10-25.md`.

## Session 2026-10-25 III (PW-D — the UE8M0 u8-scale packing, the parity wave's first slice, lane pw-d)

- **PW-D landed on `port/pw-d`** (from `0c847722`): the tier's MXFP4 experts (`VKT_SRC_MXFP4_E8M0` — DeepSeek V4/V4.1, Kimi K3, MiMo) keep their group scales on the device **as the packed ue8m0 bytes** (new **fmt 15**: e2m1 nibbles + 1 byte a 32-input group, 4 to a word) instead of the f32 expansion fmt 7 held — the audits' slab mechanism, reconciled first: **15.0 MiB** was the per-expert device payload (12 MiB codes + 3 MiB f32 scales), the placement census's **28.8 MiB "effective"** divided the whole tier pool (7.81 GiB = 277 residents + 256 stream slots × 15.0 MiB) by the resident count — a tenure ratio, not a format property (and "fmt 7 fp8" there a mislabel; the codes were already 4-bit). The on-disk form is ue8m0 and the old expansion wrote the byte into the float's exponent field — so the packed decode (`floatBitsToUint(word)` → byte extract → `e<<23`) is the **identity round trip**: lossless, landed **unconditionally, no env**. One DeepSeek V4 expert **15.0 → 12.75 MiB (−17.6 %, the fork's own class)** — every stream/promote/upload byte for MXFP4 experts drops with it and the same budget holds 1.1765× the experts (residents and slots both shrink: 277→~374 beside 256 slots at the census rig's 7.85 GiB; the pre-registered ~326 scaled the residents alone). Consumers taught the byte read: `qmatmul_grp_mx`(+gate_up, the format per expert from the table's [10]), `chain_moe_gv` (cgv slot 5), `chain_moe` (block_15), `qmatmul`/`qmatmul_gate_up` (per-expert GEMV), `qmatmul_gemm`, `qmatmul_coop`, `qmatmul_grp_gemv`, and the CPU host-rows path (`host_rows`/`dev_dequant`); the generic dense APIs (float* scales) refuse the form. **CUDA keeps fmt 7** (no packed form in cu_xb.cu, no CUDA rig to prove one; `#ifdef COLI_CUDA` pins it — behaviour unchanged there). Proof: `run_xbatch_mx_pack` (new, VK_TEST harness) — **fmt 15's rows bit-identical to fmt 7's** over the same codes/scales across the GEMV/cgv/GEMM routes (worst 1.77e-05 vs the double reference); `packed_scales` (new unit in test_vk_tier) — the ue8m0⇄f32 identity over all 256 bytes + the byte arithmetic ("ue8m0-packed 12.75 MiB, f32 scales 15.00 MiB (x 1.1765)"); tiny oracles token-exact with the tier booting `fmt 15 gs 32` (23 + 63 PASS lines, dmoe legs driving the chain's rows path on packed scales). Gates all green run 1: tier (both modes, incl. a new MXFP4-ue8m0 mode-4 stream case), chain (11,966 frames), strict ×3, tiny ×2 variants, serve-framing, cu_tier syntax, the VK_TEST harness staged==mapped digests (`e71dff75c0df60cb`/`34df89280461294a`); `vulkan_engines.sh shader` env-blocked (no Lavapipe ICD — pre-existing). Two harness fixes folded in: the bank scenario's whole-table expectation was rand-stream luck (reseed + the queued trio forced routed — deterministic now), and a byte-count precedence bug in the harness's fmt-15 fill (`O*(I+gs-1)/gs` → `O*⌈I/gs⌉`, found by the equivalence case itself). The audits committed as `docs/research/AD-audit-series-2026-10-25/`. **No bench arms** (the window is the manager's; the −15…−16 s TTFT expectation reads at W1). Report: `docs/research/AE-pw-d-ue8m0-u8-scale-packing-2026-10-25.md`.

## Session 2026-10-25 IV (PW-fix1 — the review's P2 fix list + the FA timing harness in-tree, lane pw-fix1)

- **PW-fix1 landed on `port/pw-fix1`** (from `2c57868e`, the PW-C2+PW-D merge head; the review's fix list — all P2, none blocking — closed and its 8.4×/51× reproducibility gap filled): (1) `coli_vk_tensor_import` **refuses fmt 15** beside `upload_tensor_pool`'s refusal — the import's `gs` ternary never stamped 15, so an imported tier tensor would have carried `gs 0` with the ue8m0 bytes read as float scales; AE §3's stated invariant now matches the code, and a new VK_TEST gate block in `run_late_cases` proves **both** refusals (upload + import) on a device whose host import is live. (2) The `scales_wide`/`coop_fmt` fmt-15 wide-gap closed by **dropping 15 from `coop_fmt`** (and the now-dead 15 token in `xb_coop_slot`'s rung check): tier tensors never carry `scales_wide`'s f16-range flag, so a packed scale past fp16's range would have reached the coop GEMM unguarded — the smaller/safer side of the review's either/or (decode-in-`scales_wide` would be dead code: both call sites are inside the upload that already refuses 15), fp32 GEMM takes the form until a cooperative-matrix rig proves the packed decode (this rig has none; the branch stays compile-checked). (3) ENVIRONMENT's `COLI_VK_XB_GROUPED_MX` and `COLI_VK_DMOE_ROWS` rows say **fmt 7/15** per the gates; the FA row and AG §2 gained the review's nuance — arm 1's mirror failing degrades one rung to the **fp32 tile**, mode 0 stays the tile's own refusals. (4) AG §4's throwaway timing harness is **in-tree** (`c/tests/bench_chain_attn_fa.c` + its on-demand `make tests/bench_chain_attn_fa VK=1` rule, the `bench_attn_f32` pattern): §4's methodology verbatim (one arm a lever, a warm-up frame that grows arm 1's mirror scratch, best-of-3 frames timed at the submit, `attn_fa` engagement checked per arm). One rig fact surfaced: the first S 256 run (10 mode-0 dispatches ≈ 3 s one submission) hit this box's amdgpu hard recovery — the K1/P1 boundary class `COLI_VK_DMOE_ROWS_MAX` documents — so the chunk arms default to **3 dispatches a frame** (~0.9 s of GPU work, clear of the ~2–4 s boundary; `COLI_VK_BENCH_N` overrides). **Re-measured through the in-tree copy** (RX 6900 XT): decode 1,811 → 191 µs arm 1 (**9.5×**, §4 said 8.4×) / 199 µs arm 2; S 256 chunk 305.4 ms → 6.17 ms (**49.5×**, §4 said 51×) — all inside the ±20% band, nothing to flag loudly (AG §8 has the table). Gates: vk-chain **PASS** (12,039 frames, the four FA cases at their bars), vk-tier **PASS ×2**, vk-strict **PASS ×3** (no flake), VK_TEST matmul-only **PASS** with the f16/import digest **`34df89280461294a`** == PW-D's (the new refusal gate is bits-neutral), tiny ×5 legs (CPU/VK/VK+FA/prefix/brio) all PASS token-exact, serve-framing ok, cu_tier CUDA syntax clean; fixture weights borrowed from up2276-merge's banked copy (config/ref/tokenizer diff-equal, no torch here). Report: `docs/research/AG-pw-c2-fa-flash-attention-2026-10-25.md` §8.
## Session 2026-10-25 IV (PW-A1 — demand-growing decode residency, lane pw-a1, resumed)

- **PW-A1 landed on `port/pw-a1`** (from `2c57868e`, the PW-D merge; the lane was resumed after a
  usage-limit kill at the tier-check run, its uncommitted cut inherited and finished):
  `COLI_VK_TIER_DECODE_GROW` — the census's decode-residency asymmetry answered as a default-off
  policy lever. The tier's resident set stops being the warm start's fixed one: at the **first
  decode-class step** the tier probes what the device really has free (`VK_EXT_memory_budget` less
  `COLI_VK_TIER_DECODE_GROW_RESERVE_GB`, 0.5 default — the boot budget could only guess at what the
  chain/KV/head take) and grows its budget into that first, then retires **stream slots one place at
  a time** beyond it (floor of two, the bytes moved to the residents' budget), `COLI_VK_TIER_DECODE_GROW_GB`
  bounding both. Installs rank by the engine's **decode-only** counts (S7's `.coli_mfu`, handed over
  as `VktConfig.decode_heat` via `coli_v4_expert_store_mfu_history`, geometry-gated to the fork
  table's own): cutoff = K-th largest over the experts the device does not hold (the fork's
  `cache_reorder` rule); at-or-above installs into a grown place **never a victim's** (the warm set
  stands, `evictions 0` stays 0), below installs not at all at a decode step — and the same gate in
  `vkt_wants` and `promote` so the merged-history warm cannot spend the growth. **The resume fixed
  three defects in the inherited cut**: a slot-tensor double free in the retire (the `ColiVkExpert`
  owns the slot's tensors), the rank gate covering only the dg branch (below-cutoff ordinary
  free-room installs were taking the grown places), and `MFU_*` macros referenced outside the store
  unit that owns `mfu_table.h` (every `COLI_V4_UNIT_*` + Vulkan compile broke; the geometry check
  was already inside the store's export). **Unit proof** (`test_vk_tier` `decode_grow`, RX 6900 XT):
  free-VRAM leg 6 -> 8 residents by decode-only rank, curve 6 6 8 8, below-cutoff routed experts
  never installed, evictions 0 (cutoff 40); slots-beyond leg 6 -> 9 with slots 6 -> 3 and the cap
  refusing the fourth (cutoff 30); default leg grows nothing, no clause. **Default-off/armed-inert**:
  tiny ×2 token-exact at defaults; `COLI_VK_TIER_DECODE_GROW=1` at tiny declines on geometry (4
  experts, not the fork's 256) with the recorded line and stays token-exact — the armed path cannot
  touch a non-fork-geometry model; the D11 count-band class stands for the armed path at fork
  geometry. **Gates all green run-1**: tier (both modes), chain (12,039 frames), strict, tiny ×2
  (torch absent on the box — the shared banked fixture, byte-identical config/ref/tokenizer, used
  in place of the regeneration step), tiny-dmoe (all 8 legs), serve-framing, cu_tier syntax;
  `vulkan_engines.sh deepseek` env-blocked pre-existing. No bench arms — the model-scale probe (the
  arm line's own `decode grow armed: <free> -> <K> places` print at fork geometry) and the
  `promo_cap`-vs-fork-install-rate question are left to the manager's W1/W2 windows. Report:
  `docs/research/AH-pw-a1-decode-grow-2026-10-25.md`.
## Session 2026-10-25 V (bench-W1 — the manager window: the fmt-15 P0, the hotfix, and the first model-scale parity verdicts)

- **The W1 window ran to completion on `port/up-2276`** (the manager-run parity wave's first window; this
  worktree, sole writer; every leg logged under `/root/bench-colibri/up2276/w1-*`): C0/G/F/GF ×3
  interleaved + one GF DPROF rep at the standing TTFT shape, **and found a P0 before its first verdict** —
  **PW-D's fmt 15 (ue8m0-packed scales) corrupts resident-path expert compute at model scale** (mid-decode
  MoE router failure `first index -1`, varying layer; bisected clean→broken exactly at the PW-D merge,
  PW-C2's tip and the pre-PW-D tip clean beside it, stream-off still failing ⇒ the resident path; every
  unit/tiny gate had stayed green — their geometries cannot reach the model's). **Hotfix `d73b82e1`**
  (`COLI_VK_TIER_FMT15`, opt-in; fmt 7 the standing default again, byte-identical to pre-PW-D), smoke-
  confirmed at model scale; **D's reads DEFERRED** and the institutional debt recorded (a ~2-min
  model-scale smoke gate owed for tier/chain-default slices). Two window false starts kept as evidence:
  the 2304-row auto-fit drift (post-event free-VRAM shift; one amdgpu hard-recover) and the wrong
  `COLI_VK_CHAIN_ROWS` pin (the CPU's ≤128-row class, its 800.7-s TTFT leg) — take 3 ran
  `COLI_VK_CHAIN_ROWS_MAX=2048`, the baselines' exact shape, 13/13 legs clean, the card back at the
  592 031 744 B baseline (+4.5 MiB) at close. **Verdicts (medians, ±20 % bands): G PASS** — decode device
  share 13.1 % → 24.9 % (1.90×; 0 free VRAM probed, all 154 installs from retired stream slots, 273 → 427
  residents, evictions 0, decode +16.0 %; whole-run disk bytes *not* down, 93.08 vs 91.95 GB — the installs
  are one-time cold uploads); **F PASS over the band (favorable)** — attention bucket 46 337.0 → 1779.1 ms
  whole-run (−96.2 %, dispatches exactly 2×: 5590 vs 2795), decode A1 −55.6 ms/tok (the band's top),
  decode rate +8.8 % vs the +3–5 % pre-registration, TTFT −5.1 %; **GF additive PASS** — 86.6 % of the
  G+F decode-wall sum; **D DEFERRED** (no D arm; C0 155.317 s sits in the pre-D reference class — the
  138–142 s expectation was D-contingent and is withdrawn). D11 text counts: C0 3/3 stable, 9/9 armed reps
  diverge (G mid-text — the residency class; F/GF from token 1 — the FA numerics class; GF ≠ F: the
  levers are additive in time, not in tokens). Full record: `docs/research/AI-pw-w1-2026-10-25.md`.
## Session 2026-10-25 VI (PW-A2 — zero-disk decode: closed premise-falsified, lane pw-a2)

- **PW-A2 closed on `port/pw-a2` without a lever** (from `d30df627`, the W1 harvest; docs-only —
  the manager confirmed the close on the Step-0 evidence). The lane's pre-registered frame was the
  census's decode-disk asymmetry (fork `expert_requests=0 bytes=0` at decode vs the port's ~92 GB
  run bytes): *cover the decode hot set in the store's RAM at prompt-end, ranked by `.coli_mfu`*.
  **Step 0 split the ~92 GB first**: the decode window owns **4,030–4,534 loads / 53.9–60.6 GB
  (59–63 % of run bytes, ~64 misses/token sustained)**; boot-warm + prefill-window owns the other
  ~2,800–3,100 / 37–41 GB — the magnitude premise held (the <5 GB stop rule did not fire). **But
  the asymmetry premise is false**: the fork's `bytes=0` counts its store lease path only; beside
  it the same log reads `v4_direct reads=15880 payload_bytes=199.82 GB`, and net of the 11,008-record
  prefill ring pass the fork reads **52.7 GB at decode** (its noexperts arm: 5,113 store misses =
  exactly 5,113 direct reads, 55.7 GB) — **parity** with the port. Census §1.2 row 8 stands
  corrected (the same counter-population error §4 caught in the hit-rate row). **And the mechanism
  is dead on the tree's own measurements**: the decode working set is ~4,000–4,440 distinct experts
  (~102/layer) against the store's 48 slots/layer (25.70 GiB exactly spent) — 2.1× over capacity,
  so even a perfect-oracle preload saves ≤ 2,064 of the ~4,400 loads; the S7 arms already measured
  the mandated rank (full-store `.coli_mfu` prewarm: decode misses 4,435 → 4,534 *worse*;
  F32/F48 pin tenure worse still, `hit_rate_d` 68.1 → 62.9), and the prewarm's kept win — TTFT
  −5.4 s via page-cache warming of prefill's stream — is exactly what a prompt-end preload cannot
  get. **The redirect the close hands the campaign**: the fork hides the same ~53 GB behind its six
  async MoE read+compute lanes (census row 7, never-tested on the port, fork-priced +23 % decode;
  the port computes non-device experts inline — 821.9 ms/tok of its 1,619.5 ms/tok decode wall,
  V-g1) — re-briefed as PW-E, "the lanes design against the measured 54–59 GB decode-window read
  mass". **The gate run found and repaired the W1 hotfix's own debt, test-only**: `d73b82e1`
  made fmt 15 opt-in without updating PW-D's `packed_scales` case, so `vk-tier-check` (and
  `vk-strict-check`'s unset leg, which re-runs that binary) were red at the branch point — the
  repair keeps the env-independent identity/scale-word checks in the default leg, moves the
  byte-shrink half to a new armed `fmt15` leg (`COLI_VK_TIER_FMT15=1 … fmt15`, the host-pairs
  pattern; asserts 12.75 vs 15.00 MiB ×1.1765 verbatim, and holds whichever way the default
  later lands). Gates green at the close head: tier ×3 legs, chain 12,039 frames, strict (one
  timing-jitter flake between its comparison legs, green on re-run and byte-identical by hand),
  tiny ×2 (torch absent — the banked fixture, weights borrowed read-only), tiny-dmoe 8 legs,
  serve-framing, cu_tier syntax; no ENVIRONMENT row (no knob landed).
  Report: `docs/research/AK-pw-a2-zero-disk-decode-2026-10-25.md`.
## Session 2026-10-25 VII (PW-C3 — the S=1 mHC fusion slice, manager-run parity wave 2)

- **PW-C3 landed on `port/pw-c3`** (from `d30df627`, sole writer): `COLI_VK_CHAIN_MHC_S1`
  (default off, byte-identical unset) — the fork's single-dispatch decode mHC pair
  (`mhc_dec_{pre,post}.comp`, its Level-1 fusion) as `chain_mhc_dec.comp` on `chain_mhc`'s
  buffers, offsets and hp layout. A one-row mHC site drops 8 dispatches → 3 (the fn matmul +
  one 256-thread workgroup for the whole pre tail + one thread-an-output post, the bf16
  rounds folded); any refusal (streams > 8, hidden > 4096, a missing pipeline) records the
  standing chain. The premise held (the port's S=1 path was 6+2 dispatches a site, not
  single-dispatch — no C1 recurrence); the fork's own record for the pair is an op-tick wash
  (0.317–0.321 vs 0.306–0.311 ms/call) with its +19 % decode win in the serialized host
  path the port's in-frame chain never had — this is the in-frame consolidation slice.
  Unit oracle vs the standing path at S=1: hp 5.8e-11 (fma class) and **bit-identical bf16
  outputs at the model geometry** (one flip in 16384 at H=8); the tiny oracle **token-exact
  with the lever on** (it engages there — tiny hc_mult 2/128/3); model-scale smoke rc=0,
  coherent, engagement exact (mhc −5418, norm −5418, rounds −16254 = 63 fwd × 43 layers × 2
  sites; GEMV/dsa/mm8 +0), the three buckets' device time −422 ms whole-run ≈ −6.7 ms/tok —
  the wash-to-small class the dossier's L5 pre-registered, not the census' −20…−30 (which
  priced the host-loop class). Gates: chain/tier/strict/tiny ×3 arms all PASS — after the
  lane re-armed `test_vk_tier`'s `packed_scales` around `COLI_VK_TIER_FMT15` (**the gates
  were red at the branch point** through the W1 hotfix's missed test update, proven on a
  clean `git archive d30df627` tree; PW-D's debt, test-only, two lines). No bench arms (one
  confounded first smoke kept as evidence of the boot-time VRAM co-tenancy hazard; the clean
  pair is `pw-c3-mhc-smoke-{off,on2}`). Report: `docs/research/AL-pw-c3-mhc-s1-fusion-2026-10-25.md`.

## Session 2026-10-26 (PW-Dfix — the fmt-15 P0's root cause, fix, default restored, and the model-smoke gate, lane pw-dfix)

- **Landed on `port/pw-dfix`** (from `d30df627`; this worktree, sole writer; every GPU launch settled to
  the W1 592 031 744 B baseline, no `/dev/dri` holders): **the W1 P0's root cause found and fixed** — it
  was never the packed form. `host_pairs` (vk_tier.c), the tier's hybrid CPU path that computes host-pool
  experts in place, advanced each output row's scale pointer in **float** units while fmt 15's scales are
  packed **ue8m0 bytes** — every output row past the first read its bytes 4× too deep, past the 262 144-B
  scale range into the host pool's other bytes: garbage exponents → 2^127-scale weights → non-finite
  expert rows → one layer below, the router fails exactly as W1 saw; a 1-expert host pool reads past the
  mapping (SIGSEGV, the crash leg). **Reproduced at model scale deterministically** (the smoke shape:
  fmt-15 legs rc=1 ×4, `HOST=0` legs rc=0 ×2 — the discriminator), at unit scale (model geometry + forced
  hybrid: 24 576 non-finite values, fmt 7 clean), and even at H=192 — **the gates had stayed green because
  `rel()`'s NaN comparison is false** (a non-finite row never raises `worst`; the old hybrid case passed
  with 27 wrong rows and `worst 0.00e+00`). Fix: **`host_scale_row`** (the byte stride for fmt 15, the f32
  stride verbatim for the rest — fmt 7 bit-identical by construction), plus the same class closed in
  `qmatmul_grp_gemv.comp`'s writer tail (`fmt != 15` on the per-row scale multiply — latent: the grouped
  GEMV needs cooperative matrices this rig lacks), plus `COLI_VK_TIER_FMT15` re-read as asked (the hotfix's
  process-lifetime cache hid it from a second `vkt_init`).
- **fmt 15 is the default again** (+17.6 % tier capacity; `COLI_VK_TIER_FMT15=0` the fmt-7 escape hatch).
  Model-scale evidence: the new smoke gate PASS at defaults, at `=1`, at `=0` (the pre-fix tree fails the
  same fmt-15 legs deterministically). **The regression test is the minimized repro** (`model_hybrid_case`
  in test_vk_tier.c — fmt 15 at hidden 4096/inter 2048 with the hybrid forced: 18 rows, 32 768 non-finite
  pre-fix → 0 post-fix; every row checked finite element-wise, NaN-blindness closed).
- **The institutional debt paid: `deepseek-v4-smoke`** (make target + `tests/deepseek_v4_smoke.sh`) — the
  real checkpoint (MODEL env, default the rig's path), ~100-token prompt, 16 tokens; rc=0 + coherent
  generated_text + no failure lines; **skips cleanly** without model/device/build, **fails** on `/dev/dri`
  co-tenants; the frozen usage/mfu snapshots copied in where they exist. Wired into the standard set below
  and the model's Validation section (docs/deepseek-v4.md).
- **Gates all green on the final tree**: vk-tier (both modes, incl. the new model-geometry case), vk-chain
  (12 039 frames), strict ×3, tiny CPU+VK token-exact, prefix, brio, dmoe legs (plain/ROWS=1/BANK/BANK+
  ROWS_MAX=8), serve-framing, cu_tier + vk_tier CUDA syntax, VK_TEST mapped (digest `34df89280461294a`,
  bit-equal PW-D's) and staged. Closed in passing: the hotfix had flipped the fmt default without re-running
  the tier gate — `packed_scales` failed at every default run since (it now arms the lever explicitly).
  **The standard gate set for tier/chain-default slices is now: vk-tier-check, vk-chain-check,
  vk-strict-check, the tiny oracles (CPU + `COLI_VULKAN=1`), serve-framing, cu_tier syntax, and
  `deepseek-v4-smoke` at defaults plus any lever the slice arms.** Owed: D's reads re-armed (the −15…−16 s
  TTFT expectation, still unmeasured); a coop-matrix rig's dispatch check for the grouped GEMV's fmt-15
  tail; the union prefill router failure should fill `moe_reason()` like the decode path's does. Report:
  `docs/research/AJ-pw-dfix-2026-10-26.md`.

## Session 2026-10-26 II (PW-B — the stream ring, parity wave 3, lane pw-b)

- **PW-B landed on `port/pw-b`** (from `a8f45741`; this worktree, sole writer; GPU for gates + the
  smoke only, no benchmark arms): **`COLI_VK_TIER_STREAM_RING`** (default off) — the port's stream
  fills moved off the engine thread onto a ring worker, the fork's `v4_ram` class mapped onto the
  tier's own machinery (the placement census's rank-1 never-tested row, the mechanism behind X-ob0's
  measured **STAGE 105.6 s of the 159.0 s prefill window** at 1.74 GB/s effective against the fork's
  join-0 invisible 137.4 GiB). The design: the prefetch call for layer L is the fork's switch point
  — it **takes** the running job (join; the books merge) and hands the worker **layer L+1's
  predicted set** (`T.pred`, the same plan the inline path uses, now also excluding the engine's
  in-RAM experts), read through **a bypass stage pool of the ring's own** (the engine's stays the
  engine's — that is what keeps both lock-free) and uploaded into **the half of the streaming slots
  the running step is not reading** (the halves alternate; join_big frees the step's half before the
  next job takes it). The engine's step joins only what it needs: a big step runs *beside* the job
  (issue_big's three slot scans skip the job's half; an inline fill short of room outside it joins
  rather than races), decode-class steps and `vkt_report` join, **`COLI_VK_TIER_SYNC=1`'s
  deterministic drain includes the ring** (quiesce joins it — the documented contract extended, not
  broken), and the teardown cancels between reads (the fork's issue #4: never wait out a discarded
  stream). Every miss — a cold next layer (**the prompt's first chunk keeps the inline fill**, the
  charter's cold-start fallback), an unpredicted expert, a refused read, a worker that could not be
  made — takes the inline fill at the step; the CUDA tier does not arm (its fills stay
  engine-threaded). The fill body was extracted into `st_fill_load` (hooks/stop/books parametrised;
  the engine path's behaviour identical, `left >= 2 || !one` keeping the lone fallback's shape).
- **Unit evidence** (`test_vk_tier`'s new `ring` case, in all three gate legs): the fills-ahead
  **prediction order** (the consuming step loads zero experts inline, the order equals the plan's),
  **the join waits only for what's needed** (a step of another layer completes beside a parked read,
  4 ms against a 700 ms bound; the next prefetch takes it), **SYNC determinism** (the quiescent
  point waits out the parked read, outputs exact), **the inline fallback** (a fail-all reader; every
  step byte-equal the inline leg's), **the teardown cancel** (bounded to the read in flight), and
  **default-off** (the hook wired with the env unset is never called).
- **Gates all green on the final tree**: vk-tier ×3 legs, vk-chain (12,114 frames), strict ×4 (one
  intermittent `frag` jitter **reproduced on the clean base archive** — the pre-existing unmasked
  tier-stat class; two earlier flake-protocol catches were mine and fixed — timing values in the
  case's stdout), tiny/prefix/brio token-exact, the dmoe ×8 legs, the ring tiny legs (the new
  `deepseek-v4-tiny-check-ring` target; shape-inert at tiny, the PW-C2 precedent), serve-framing,
  cu_tier + vk_tier CUDA syntax, **`deepseek-v4-smoke` PASS at defaults AND with the ring on**
  (vram0 the 600,981,504 B floor, back at floor, no holders), plus a **2-chunk engagement leg**
  (`COLI_VK_CHAIN_ROWS=32`): `the ring 10 jobs (8 experts)`, `prefetched 8 (4 used)` — the reads,
  the off-thread fills and the prefilled-slot consumption all engage at model scale.
  **Default-off byte-identity**: a clean `git archive a8f45741` base vs this tree, the tiny harness
  — every PASS line and token identical, the diff host-state noise only (the X-ob0 discipline).
- **Not claimed**: no benchmark arm ran (the window's rule), so the campaign's STAGE 105.6 → <10 s
  is unmeasured — and the pred-gated design's honest ceiling is recorded: **chunk 0's 43 units keep
  the inline fill** (no next-layer prediction exists on a layer's first visit), so the fork-literal
  cold shape (a whole-layer fill with no prediction — a one-rule arm on this machinery:
  `st_ring_submit`'s cold branch filling the plan's whole non-resident set instead of nothing) is
  the follow-up the bench lane should pre-register beside the arm. Owed to the arm: the chunk-1 join
  tail, the prediction overlap at S=2048, the in-RAM exclusion's inline remainder.
  Report: `docs/research/AN-pw-b-stream-ring-2026-10-26.md`.

## Session 2026-10-26 III (bench-W2 — the full landed stack against the fork, lane bench-W2)

- **The window** (`port/up-2276` @ `d5991060`, the binary rebuilt at open): C0/GF/FULL/RING ×3
  same-day strict round-robin + DPROF reps of FULL and RING + two window-tail reference DPROF legs
  (C0, GF — the bucket attribution needs same-window baselines at the fmt-15 flip); the W1 settle
  discipline held (baseline 592 031 744 B ±16 MiB, no holders; 12 legs at floor +2.0 MiB, then the
  idle floor **dropped to 538 959 872 B** — below the historical floor — and the window closed there;
  nothing leaked across 18 legs). **C0** the ttft-set defaults (fmt 15 default again);
  **GF** +DECODE_GROW+ATTN_FA; **FULL** +MHC_S1+STREAM_RING; **RING** +STREAM_RING alone;
  RINGCOLD skipped (no env exists; AN §5 pre-registered it as a one-rule *code* change — recorded
  verbatim, none improvised).
- **Medians**: C0 **153.171 s / 0.5751 tok/s** (W1: 155.317/0.5492) · GF **154.208/0.6608**
  (143.424/0.6779) · FULL **165.038/0.6768** · RING **203.808/0.5687**. Versus the fork
  (107.8/1.135): the port's best decode is 0.60× the fork's, best TTFT 1.43× — no arm holds both.
- **C0 (D's read)**: capacity **PASS** — fmt 15 lifts the ttft-shape tier 273×15.0 → **367×12.8 MiB**
  (+34 %; the 559 class is the no-bypass smoke shape), decode share 13.1→18.4 %, C0 decode +4.7 %;
  the **−15…−16 s TTFT byte-economy: MISS** (−2.1 s; the staging span is unchanged at ~108 s —
  the fills' count, not their bytes, owns the wall).
- **GF**: same-day continuity PASS in band, adverse both ways (decode −2.5 %, TTFT +7.5 % — fmt 15
  cost GF its W1 TTFT edge; the levers overlap on the same 367-resident tier). GROW at fmt 15 is
  slots-only (`budget 367 -> 367`, 0 free places; 150/154 installs from the retired slots; 517/521
  grown). FA engagement exact (+2 795 ops, the dispatch doubling).
- **RING — the window's finding**: the STAGE bucket target **PASS 100× over** (staging-upload
  106.3 → **1.1 s**) but **TTFT MISS adverse (+50.6 s)**: the ring's jobs engaged (42 = chunk 1's
  predicted transitions) with **empty plans — 8 experts filled, 0 used** (the pred-scaled estimate at
  S=467 and the in-RAM exclusion both gate the plan; the books cannot split them), so the fills fell
  to the step's inline path inside the MoE block (host-MoE 44.9 → 131.0 s) and the engine idled at
  A1's fence (2.1 → 70.6 s exposed). Off-thread placement without plan coverage is a strict
  pessimization at this shape; the fork's ring wins by *unconditional* whole-layer coverage. RING ≡
  C0 in decode/share/ops/loads/text (timing never bytes, held at model scale).
- **FULL**: the stack ≥ GF's decode **PASS** (+2.4 %; MHC_S1 engagement exact: −27 090 ops, the
  PW-C3 signature); the absolute targets **MISS** (decode 0.6768 < 0.70; TTFT 165.0 > 120 — the
  ring's +10.8 s tax over GF).
- Report: `docs/research/AO-pw-w2-2026-10-26.md` (the DPROF 4-leg bucket table, the verbatim
  engagement clauses, the D11 counts, the owed list: the ring's plan-coverage split, RINGCOLD's one
  rule + the coverage question, the GROW headroom note, the fmt-7 GF isolation pair).

## Session 2026-10-26 IV (PW-B2 — the ring's cold branch filled + the stage-pool leak it exposed, parity wave, lane pw-b2)

- **Landed on `port/pw-b2`** (from `6ba3b4d1`; this worktree, sole writer; GPU for gates + the smoke
  only, no benchmark arms — the campaign pauses after this slice): **`COLI_VK_TIER_STREAM_RING_COLD`**
  (default off, needs the ring) — W2 §7's one-rule gap closed, AN §5's pre-registered follow-up: the
  ring's **cold branch fills instead of declining**. A next layer with no prediction behind it (the
  prompt's first chunk, the layer's first visit) is planned **whole** instead of handed to the inline
  fill — the fork's literal whole-layer cold shape — and the worker covers it ahead. **The below-rule
  filter drops in that branch**: with no prediction to scale at the coming step's S there is nothing to
  hold against `R`, and the measurement is why — at the smoke's shape (S 72, R 16, E 256) the
  heat-scaled estimate is ~3 rows for a layer's hottest expert, so the filtered plan is *empty again*
  and the cold jobs arm nothing (an instrumented leg showed exactly that). The resident exclusion, the
  in-RAM skip, the `st_per` cap, the half-alternating slots, the take/join, the inline fallback for
  every miss, the SYNC drain and the teardown cancel all stand; where a prediction exists the plan is
  the prediction's, unchanged. Default off gates one branch and one boot clause.
- **The bug the cold arm exposed, fixed** (PW-B's own; scope extended by the manager on this evidence):
  `v4_vkt_unhold`'s hand-back was keyed on the hold's stage index alone, which indexes whichever pool
  handed it out — a **ring** fill's release cleared an **engine** stage's flag and left the ring's
  8 × 16 MiB pool busy forever, capping the ring's fills at the pool's whole capacity **per run** and
  falsely freeing an engine stage a concurrent engine fill could be reading into. `V4VkHold` now
  carries its pool (`ring`) and the release frees the one it came from. **W2's `the ring 42 jobs
  (8 experts)` line is re-attributed: two defects compounding** — the empty plans (W2 §4's diagnosis,
  standing) *and* this leak capping whatever a job did fill; with the cold rule alone the smoke still
  read `42 jobs (8 experts)` (job 1 filled, the rest nothing).
- **Unit**: the `ring` case's three new legs — `cold default` (nothing handed over, 4 inline loads),
  `cold on` (4 experts one layer ahead, **4 and 5 of them below the rule** — the filter-drop's proof —
  1 inline load, the miss 9 the fallback's own), `cold with a prediction` (the plan is the
  prediction's, **9,2,3,4** against the heat's **2,3,4,5**, 0 inline loads) — both cold legs' rows
  `memcmp`-equal the default's. Plus `tests/test_v4_vk_ring_pool_source.py` (4 tests, the
  `test_v4_moe_batch_lifecycle_source` pattern: the pools are file-static and the leak is silent on
  output, visible only as fill counts at a 43-layer model's scale), verified both ways — 4/4 fixed,
  the pre-fix shape fails exactly the hand-back test.
- **Gates all green on the final tree, run 1**: vk-tier ×3 legs (the 10-leg ring case), vk-chain
  (12,114 frames), vk-strict, tiny/prefix/brio/serve (23 lines, token-exact), dmoe ×8 (63), the ring
  tiny target (30; it gained a `RING_COLD` leg, the PW-C2 shape-inert precedent), serve-framing ok,
  cu_tier/vk_tier CUDA-path syntax clean.
- **`deepseek-v4-smoke` PASS at defaults, RING, and RING+COLD — the texts byte-identical** (the same
  `generated_text` md5 on all three legs). The engagement line, verbatim, RING+COLD:
  **`prefetched 1344 (60 used)`, `the ring 42 jobs (1344 experts)`** — the smoke's single ~100-token
  chunk is *exactly* the cold case (every layer a first visit; the RING-alone leg arms nothing), and
  every job fills its whole plan (42 × `st_per` 32). The 2-chunk legs (`COLI_VK_CHAIN_ROWS=32`): RING
  `10 jobs (11 experts)` (PW-B's own line, unchanged), **RING+COLD `51 jobs (1354 experts)`**.
- **Not claimed**: no benchmark arm ran (the window's rule) — the cold coverage's *worth* at the
  campaign shape is W3's to measure. **W3 pre-registered** (AP §6): RINGCOLD / RING / C0 ×3
  same-day round-robin + one DPROF rep each of RINGCOLD and C0; expectations — host-MoE **back to the
  ~45 s class**, **STAGE ≤ 10 s held**, **TTFT ≤ C0's** (the falsifiers named: host-MoE not moving
  means the inline remainder is the in-RAM exclusion's — §4's open coverage question, now the ring's
  rank-1 unknown — and a TTFT past W2's RING means the chunk-1 join tail is exposed).
  Report: `docs/research/AP-pw-b2-2026-10-26.md`.
