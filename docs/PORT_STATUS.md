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
