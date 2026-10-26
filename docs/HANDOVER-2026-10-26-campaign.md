# HANDOVER — the fork→upstream performance parity campaign (2026-10-23 → 2026-10-26)

**Written for a fresh agent picking this up with no prior context.** Read this file, then
`docs/campaign/CAMPAIGN.md` (the full lane registry and decision log), then the research series
(`docs/research/T…AP`). Everything below is evidence-backed; nothing is aspirational.

**Branch of record:** `port/up-2276` @ `4dad446e` on Gitea (`pi/colibri-upstream`). Everything pushed.

---

## 1. The mission, as given by the owner

Take the performance wins from the owner's fork (`colibri-ds4-vulkan`, Vulkan support + optimizations
for DeepSeek-V4-Flash on an RX 6900 XT) and land them **upstream** as reviewable PRs. The owner's
precondition was "get a full performance match first, then organise the PRs". Mid-campaign the owner
sharpened it: *"if we haven't matched performance from the fork FOR THE SAME PROMPT, IN THE SAME
SITUATION then we missed some important optimisation"* — which led to the audit wave, which found the
real gaps and redirected the whole effort. **No PRs have been sent yet**; the queue is prepared (§7).

## 2. Where it stands — the numbers

Same rig, same 2,515-token prompt, 64 decode tokens, ×3 interleaved arms, VRAM-guarded:

| | fork @ d11fba5b | port at campaign start | port now (best arm) | remaining gap |
|---|---|---|---|---|
| TTFT | 107.8 s | 154.3 s | **143.4 s** (W1-GF) | 1.33× |
| decode | 1.135 tok/s | 0.549 | **0.678** (W2-FULL/GF) | 1.67× |
| decode at *defaults* | — | 0.549 | **0.575** (fmt 15 alone) | — |
| output text | — | — | **no degradation** (audit-race) | — |

The port **wins** TTFT below ~535-token prompts (the fork's is prompt-independent ~102 s; its
layer-outer prefill pays a fixed floor). Above that the fork wins on both axes.

## 3. What landed (all reviewed, gated, model-smoked)

Each is a small, independently mergeable slice with a research doc:

| lever | knob | measured | doc |
|---|---|---|---|
| ue8m0-packed expert scales (device fmt 15) | default on | +17.6% tier density; 273→367 residents at the arm shape; decode **+4.7%** at defaults | `AE`, `AJ` |
| demand-growing decode residency | `COLI_VK_TIER_DECODE_GROW` | decode **+16.0%**; device share 13.1→24.9% | `AH`, `AI` |
| flash attention + f16 KV mirror | `COLI_VK_CHAIN_ATTN_FA` | decode **+8.8%**, TTFT −5.1%; attention bucket −96% | `AG` |
| single-dispatch mHC at S=1 | `COLI_VK_CHAIN_MHC_S1` | −6.7 ms/tok (honest: wash-to-small, *not* the census' −20..30) | `AL` |
| ring copy-worker for stream fills | `COLI_VK_TIER_STREAM_RING` | staging **106→1.1 s** (the 105 s serialization killed) | `AN` |
| ring cold branch (fork-literal) | `COLI_VK_TIER_STREAM_RING_COLD` | smoke: 42 jobs / **1,344 experts** filled vs 8 | `AP` |

Plus from earlier sessions (all in): mm8 tiled GEMM, `COLI_VK_PROFILE`, stream bypass, the 243-commit
upstream merge (`N2`, `Y`), the D11 golden baseline (`W`), and the instrumentation stack
(`COLI_VK_CHAIN_DPROF` decode+prompt windows, `X`).

## 4. What was falsified — with mechanism (do not re-try)

- **"2.8× byte economy"** → 1.24×; the fork's 68 GiB was a store-view counter, not disk (`R-l1`).
- **"Zero-disk decode"** → the fork reads **52.7 GB** at decode too (`v4_direct` beside its
  zeroed store counter) — the port was already at parity. Second counter-class artifact (`AK`).
- **A2 (RAM coverage of the decode set)** → working set 4,000–4,440 distinct experts = 2.1× the
  store's 2,064 slots; the tree's own S7 arms measured the mandated `.coli_mfu` ranking *worse*
  (misses 4,435→4,534). Closed on three independent grounds (`AK`).
- **The LM head / router "on host"** → already device-computed since `9f4eb917`; the audit read a
  host-RAM-*copy* placement line as compute placement. Proven with a gdb census + exact GPU-matmul
  count decompositions (`AF`). The residual 73–88 ms/tok "head term" is per-op wall, not placement —
  a *port-novel* idea to fuse it (the fork doesn't either).
- **The ~196 ms/tok "pipeline gap"** → artifact of divergent prefill chunking between profile legs;
  direct DPROF measurement shows no gap in either config world (`V-g1`).
- **Barriers / GPU sync** → ≤0.6% of the decode wall on both engines; the fork itself measured the
  class dead (`docs/campaign/audits/barrier-census.md`).
- **Kernels as a class** → 9/16 op classes identical or better; mm8 *is* the fork's kernel. Ceiling
  ~155–205 ms/tok of the gap (`audits/shader-census.md`).
- **MTP / speculative decode** → 0 accepted drafts in the one engaged arm; no hidden multiplier
  (`audits/cpu-parity-census.md`).
- **Option B (the fork's cell-pipeline transplant)** → 3 stages landed (bank, layer-outer reorder,
  frame-split), then S3's verdict MISS per its pre-registered stop rule; retired because the audits
  proved parity is reachable *without* the fold. Charter and results: `docs/campaign/plans/`,
  `Z`, `AB`, `AC`.

## 5. The two P0s found — and the institutional lesson

1. **fmt 15 corrupted model-scale expert compute.** Every unit gate passed (256-byte identity,
   xbatch rows bit-identical, tiny token-exact) and the model still produced non-finite router
   inputs at layer 9. Root cause: `host_pairs` advanced scale pointers in **float** units while
   fmt-15 scales are **ue8m0 bytes** (rows past the first read 4× deep, off the scale range).
   Root cause of the *blindness*: `rel()`'s `r > worst` is false for NaN, so a non-finite row never
   raised the metric — the old hybrid case passed with 27 wrong rows at `worst 0.00e+00`.
   Fixed (`AJ`), NaN-aware, default restored.
2. **The ring's stage-pool leak.** `v4_vkt_unhold` freed the *engine* pool's busy flag for holds
   issued by the *ring* reader, capping the ring at 8 experts per run and corrupting the engine
   pool's accounting. Fixed in `AP` (holds carry their pool).

**The gate that came out of it:** `make deepseek-v4-smoke` — a ~2-minute real-model generation with
rc/coherence/failure-line checks, skip-clean when the model or device is absent, history-restoring.
**Any slice touching a tier/chain default surface must run it.** Unit fixtures and unit oracles
provably cannot catch this class. It is wired into `docs/deepseek-v4.md`'s Validation section.

## 6. The remaining ledger (what an incoming agent should consider)

Ranked by expected value per cost, with the evidence behind each:

1. **PW-E: the fork's 6 async MoE compute lanes** — spec'd and reviewed at
   `docs/campaign/specs/AM-pw-e-lanes.md`. ~540–700 LOC, bar ≥ +10% decode, md5-identical
   requirement. The spec answers both stop-findings in favour: it is **not** cell-pipeline-bound, and
   the prefetch-only shape is provably a subset of things already measured dead. This is the largest
   remaining priced decode lever. Its rationale: the port reads 54–59 GB in the decode window **at
   parity with the fork** — the fork is faster because it *hides* those reads behind lanes.
2. **W3 window** — pre-registered in `AP`: RINGCOLD vs RING vs C0 ×3. Expectation: host-MoE back to
   ~45 s, staging ≤10 s held, TTFT ≤ C0. W2 measured the ring's inversion (empty plans + the leak,
   both now fixed) — this arm tests the repair at model scale.
3. **Lever overlap** — W2 showed G and F now *overlap* rather than stack (+14.9% over C0 vs W1's
   +23.4%) because they compete for the same tier budget. A rebalance probe (slots/heat split,
   boot resident count) may recover additivity. Cheap to test; no code.
4. **The PR queue (the original goal)** — see §7.
5. Minor/deferred: `v4_act`'s NaN-blind compare (`test_vk_tier.c:869`), CUDA kept at fmt 7 (no nvcc
   on this box to prove a port), the head-term fusion idea (port-novel), C3 priced at wash-to-small.

## 7. The PR queue — prepared, not sent

Upstream is `github.com/JustVugg/colibri`; the PR-source fork is `github.com/jameswitney/colibri`.
**No GitHub credentials on this box** — the owner sends. Narrow, single-topic, evidence-bearing PRs
are what this maintainer accepts (`#2253` merged; an "all-encompassing performance PR" was advised
against).

| candidate | state | base to cut from |
|---|---|---|
| **mm8 tiled fp8 GEMM** `pr/vk-mm8` @ `d8abda6c` | ready, authored as jameswitney | **needs a rebase onto current `upstream/dev`** |
| #2253 follow-up (Makefile `deepseek_v4` alias trap, ~4 lines) | ready, unsent | — |
| **fmt-15 ue8m0 packing** (self-contained tier/kernel slice, all gates + smoke) | ready on the integration line | `upstream/dev` |
| **flash attention + f16 mirror** (`COLI_VK_CHAIN_ATTN_FA`) | ready | `upstream/dev` |
| **DECODE_GROW** residency growth | ready | `upstream/dev` |
| **STREAM_RING + RING_COLD** (threading change; carries the leak fix) | ready | `upstream/dev` |
| **MHC_S1** (small; honest wash-to-small number — consider shipping as a clean capability) | ready | `upstream/dev` |
| **DPROF instrumentation** (engine-agnostic value) | ready | `upstream/dev` |
| **deepseek-v4-smoke gate** (generic dev-tooling win) | ready | `upstream/dev` |
| `pr/strict-gate`, `pr/tier-host-pool` | **staged but stale** — need re-cuts; upstream's 240+ commits may supersede parts | re-cut |
| frag-mask (strict gate's `norm` doesn't mask the tier exit `frag` ratio) | one-liner, queued | — |
| KV cold tier v2 (~1.6k) | prepared earlier, "send last" | — |
| **`pi/colibri-ds4-vulkan-pr`** | **has 14 unique commits** (rebased Vulkan branch + PR meta) — do not delete | — |

**Suggested send order:** #2253 follow-up → fmt-15 → FA → DPROF/smoke (tooling first builds trust)
→ DECODE_GROW → RING → MHC_S1 → stale re-cuts → KV cold last.

## 8. Rig facts an incoming agent must know

- **Model:** `/root/Projects/colibri-v4-docker/models/DeepSeek-V4-Flash` (167 GB; streaming MoE).
- **Bench rig:** `/root/bench-colibri/run-arm2276.sh` + per-window scripts; logs under
  `/root/bench-colibri/up2276/`. Methodology law: **×3 interleaved reps or it didn't happen**;
  `VRAM_MAX_USED_MB=2600` prefix; restore the frozen `.coli_usage`/`.coli_mfu` snapshots
  (`/root/Projects/colibri-upstream/bench/*.fixed`) between arms.
- **The amdgpu hard-recovery boundary:** one submission carrying ~2–4 s of GPU work loses the
  device. Bites at chunk sizes >2048 rows and at dmoe chunk frames. `COLI_VK_DMOE_ROWS_MAX` and
  `COLI_VK_CHAIN_ROWS_MAX=2048` exist for this. **Pin `COLI_VK_CHAIN_ROWS_MAX=2048`** — the
  auto-fit drifts to 2304 on a freer card and dies.
- **`COLI_VK_CHAIN_ROWS` is the wrong knob** (it clamps chunks to ≤128 — the CPU prefill class).
- **The driver residue:** since 2026-10-25 ~17:56 the card has carried ~1.2–2 GiB of kernel-held
  VRAM with no process holders, not TTM-reclaimable; sysfs reset is read-only in this container.
  A host-level driver reset/reboot restores the clean 541 MB floor. Absolute capacity reads are
  confounded until then; cross-arm deltas are fine.
- **Gates:** `vk-tier-check`, `vk-chain-check`, `vk-strict-check` (known pre-existing `frag`
  intermittence ~1/12 — 1 PASS in ≤3 runs), `deepseek-v4-tiny-check` (+`-dmoe`), `test_v4_serve_framing`,
  `cu_tier.c -DCOLI_CUDA -fsyntax-only`, and **`deepseek-v4-smoke`** for default-surface slices.
  Tiny-check needs the venv: `PATH=/root/bench-worktrees/port-baseline/.venv/bin:$PATH`.
- **D11 goldens:** `.golden/cache/073a03b6…/` in the worktree (gitignored, on disk). Diff contract:
  PRIMARY greedy byte-identity → SECONDARY CPU TF token-exact → GPU-env TF count-band
  (positions stable within a config). The fork's `.golden` at `dd7df2c9` is untouched.
- **Worktrees:** `/root/bench-worktrees/up2276-merge` owns `port/up-2276`. **Always verify
  `git branch --show-current` before a manager merge** — a lane leaving HEAD on a side branch has
  bitten twice. Use ff-or-true-merge, check `git status` for `UU`, and never bracket a merge with
  `| tail` (it masks failures — that bit twice too, once leaving a stray byte in a test file).

## 9. How this campaign worked (the method that produced the results)

1. **Charter before code.** Every slice has a spec or plan with file:line anchors in *both* trees,
   LOC estimate, gate additions, and a **falsifiable arm with a pre-registered bar**.
2. **Adversarial review before merge.** A fresh-context reviewer breaks the spec (anchors, arithmetic,
   do-not-retry list) or the diff. It has caught: a self-contradictory stop rule, a re-counted
   already-landed feature, and a head-compute premise that was false.
3. **Measure, never assume.** The window is the judge. Falsifications are published with mechanism —
   they are results, not failures.
4. **Honest pricing.** C3 landed at −6.7 ms/tok and was reported as wash-to-small, not the census'
   −30. D's TTFT expectation MISSed and was reported as a MISS.
5. **Every gate failure teaches a gate.** The NaN blindness, the counter artifacts, the stale-knob
   traps, the amdgpu boundary, the smoke gate itself.

## 10. Files to read, in order

1. `docs/campaign/CAMPAIGN.md` — the lane registry, every decision, in order.
2. `docs/research/T` → `AP` — the evidence series (T: L2 arms · U: P1 arms · V: pipeline-gap
   artifact · W: D11 goldens · X: the S0 prefill decomposition · Z: the bank · AA–AC: S1/S3 arms ·
   AE–AP: the parity wave).
3. `docs/campaign/audits/` — the four comparative censuses (shader, placement, cpu, barrier).
4. `docs/campaign/specs/` — L2 (vk_dmoe), L7 (F8 GEMV), G1 (pipeline gaps), **AM (the lanes — the
   live one)**.
5. `docs/campaign/plans/OB0` — the Option-B charter (largely retired; the S1/S3 machinery in it is
   still reused by the tier's bank/rotation).

**Nothing is unpushed. The rig is idle and clean. The shared model's frozen history is restored.**
