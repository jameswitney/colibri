# Parity Campaign — manager workspace

**Objective (owner, 2026-10-23):** drive `port/up-2276` to full performance parity with the fork
(`colibri-ds4-vulkan` @ `d11fba5b`) by merging features, PRs sent later by the owner. Subagents do the
heavy lifting; the parent manages lanes, merges, bench windows, and status docs.

## Current position (2026-10-23)

| | port (best stacked) | fork | gap |
|---|---:|---:|---:|
| TTFT | ~148 s (S1+S2 bypass) | 103–106 s | 1.40× |
| decode | 0.670 (pool8+promote) / 0.555 (bypass arm) | 1.15–1.17 | ~2× |
| wall | ~262 | ~158–161 | 1.65× |

## Gap decomposition (measured, per research docs)

- **TTFT ~44 s**: NOT bytes (fork 203 GB vs port 251 GB disk = 1.24× ≈ 5 s — R-l1 falsified the 2.8×
  reading). The lever is the **host-MoE wall (134.2 s "routed experts on the host")** → device MoE
  (wire V4 to upstream's `vk_dmoe.h`, dossier L2), plus loop order/overlap (S5/Option-B proper) only if
  L2 + streaming slices don't close it.
- **Decode 2×**: expert fold attribution 1.84× (`DSV4_VK_EXPERTS=0` arm). Store hit-rate theory falsified
  by S7 (decode-only already at fork parity). Remaining levers: **L7 mm8/F8-class decode projections**
  (est. 0.65 → 0.9–1.0; "1.6 s/token device wait over ~760 f32-GEMV matmuls") and **L2's decode half**
  (1-row device MoE). L3 residency deprioritized (S7 verdict: ship 0).
- Small defensible tier slice on the way: **S1 `.load_batch` + S2 cache-bypassing stream reads**
  (R-l1 §3; protects decode, 8–25 s est.) with **D0 instrumentation first** (falsification discipline).

## Ladder (dossier §5, amended by R-l1/S7)

1. L2 chain-MoE (V4 → `vk_dmoe`, fmt 7) — TTFT's main lever + decode's device half. Q-l2 map says the
   fmt-7 route may be 60–90 LOC; dossier says 300–800. Spec first.
2. L7 F8 decode projections — decode's main non-fold lever. Needs "F8 envelope language" first.
3. D0+S1+S2 tier streaming slice (~400–600 LOC) — cheap, upstreamable, protects decode.
4. S5 loop-order / ring / full Option-B fold — only if 1–3 leave >1.15× TTFT gap. Consciously relaxes D3.
5. Contingent: flash-attn (8k road, gated on F14-v2), golden re-pin (D11) before strong parity claims.

## Rules of engagement

- **Bench exclusivity**: only one lane runs `run-arm2276.sh` arms at a time (VRAM guard; ×3 interleaved
  reps or it didn't happen). Lanes request a bench window from the manager.
- **Repo ownership**: one writer per clone/worktree. Spec lanes read port code via
  `git -C /root/Projects/colibri-upstream show 3064378e:<path>` (immutable ref).
- **No GitHub pushes** (owner-only). Gitea pushes are fine.
- Manager owns `docs/PORT_STATUS.md` + HANDOVER updates on the integration branch.
- Gates every merge: `vk-tier-check`, `vk-chain-check`, `vk-strict-check`, `deepseek-v4-tiny-check`,
  `test_v4_serve_framing`, `cu_tier.c -fsyntax-only`.

## Wave plan

- **Wave 1 (running)**: `sync` (upstream refresh + gates + worktree prune; owns port repo),
  `cleanup` (disk tidy; owns everything except port repo), `spec-L2` + `spec-L7` (read-only design).
- **Wave 2**: implementation lanes in isolated worktrees off the refreshed tip; gates only; then
  serialized bench windows; manager merges accepted slices into `port/up-2276` + updates status docs.
- **Wave 3**: D11 golden re-pin (4–8 h background) after the merge settle; Option-B go/no-go review
  against measured residual gap.

## Lane registry

| lane | agent | owns | status |
|---|---|---|---|
| sync | worker | /root/Projects/colibri-upstream + /root/bench-worktrees | DONE 2026-10-23: fetched upstream/dev 05a5bca5→7398a85f (+56); merge STOPPED per rules (176-commit pending range, semantic conflicts deepseek_v4.c + Makefile, watch file backend_vulkan.c bf0a3cd2); branch untouched/pushed-clean; stash from 10-21 left intact |
| merge176 | worker | same as sync | launched 2026-10-23: side-branch `merge/up176` merge of b90a369e..7398a85f per documented method; gates; then ff port/up-2276 + push + main-clone refresh + worktree prune |
| cleanup | worker | fork clone, v4-docker, OpenCode, preQDQ, bench-colibri, this dir (README only) | DONE 2026-10-23: removed preQDQ worktree (push-verified) + /root/OpenCode + 4 stale /tmp worktree regs; docker README pins fixed (ea8336c, pushed); fork stashes backed up as backup/* branches (manager); Gitea -pr repo has 14 unique commits — KEEP, do not archive |
| spec-L2 | worker | specs/L2-chain-moe-vkdmoe.md | DONE 2026-10-23: Q5 answered (fmt7 fits vkc_moe_rows, ~55–70 LOC kernel arm; whole-L2 ≈ 230–255 LOC); staged A/B/C route avoiding falsified device-pin; 2 stale OPENs resolved |
| spec-L7 | worker | specs/L7-f8-decode-projections.md | DONE 2026-10-23: premise corrected (fork 4.73× was prefill S=128; port decode already fp8-weights; real gap = chain_gemv.comp excludes fmt 12/13 → generic qmatmul fallback); vehicle COLI_VK_CHAIN_GEMV8 ~200–290 LOC Phase A; Step 0 = profile attribution |
| spec-review | reviewer | none (chat report) | DONE 2026-10-23: L2 SHIP-WITH-FIXES, L7 SHIP-WITH-FIXES (P2 errata only — passed to impl lanes); collision map: L2/L7 disjoint regions in vk_chain.c, 3 shared one-liners; order = up176 → L2-B → L7-A(Step0 first) → L2-A → L2-C conditional |
| merge176 | worker | same as sync | TIMED OUT @30min 2026-10-23: merge fully resolved+staged on merge/up176; flake root-caused (tier exit `frag 0.37` vs `0.05` — unmasked metric); base control built at /tmp/base-check |
| merge176-finish | worker | same as merge176 | DONE 2026-10-23: flake classified PRE-EXISTING (base 1/12 identical signature; isolation 8/8+12/12 stable); all gates PASS; merge commit 4740f41f + report 707cf2e3; port/up-2276 fast-forwarded 3064378e→707cf2e3, pushed; main clone refreshed; farm 0 pruned/8 kept (all worktrees dirty — safety law blocked); frag-mask follow-up documented in N2 report |

## Wave 2 (launched 2026-10-23, post-merge @ 707cf2e3)

| lane | agent | worktree/branch | scope | status |
|---|---|---|---|---|
| impl-L2B | worker | dmoe-l2b / port/dmoe-l2b | DONE 2026-10-23: 5a165efc (+117/−16; fmt-7 rows 1.16e-9/3.78e-10, router oracle green; all gates PASS; worktree+branch cleaned after merge) |
| manager-merge | parent | port/up-2276 | DONE 2026-10-23: ff to 5a165efc, vk-chain-check certified at tip, PORT_STATUS session-II note (130aa73d), pushed; worktree topology fixed (up2276-merge owns port/up-2276; main clone on main — not ff-able, left) |
| impl-L2A | worker | dmoe-l2a / port/dmoe-l2a | DONE 2026-10-23: a46908a3→a8c7e3dc (4 commits, +268/−12; cherry-pick resolved — vk_tier.c PIN_LAYER dropped as superset, tests/ENVIRONMENT unioned; D1 control byte-identical empirically; tiny-check-dmoe token-exact; all gates green run-1). Merged ff → port/up-2276 @ 7063a502 w/ PORT_STATUS note, pushed; worktree+branch cleaned. Note: reviewer's 679-line erratum was wrong — vk_dmoe.h is 678 (implementer verified at every ref) |
| bench-L2 | worker | up2276-merge / port/up-2276 | DONE 2026-10-24: 9 arms ×3 interleaved — all dmoe arms declined as designed, TEXT byte-identical ×9, D1/D2 noise-class vs C0 (C0 median 154.95/0.5305/273.12). Decision per rules: **ship A+B as alignment** (orchestration-cheap, no regression); D2/P1 untestable until Stage C. K1: per-pair 0.22× grouped at S=1 → route (b) no-new-kernel. Prefetch guard invariant. Evidence: bench/up2276/l2-*, T-l2-arms-2026-10-24.md; L7 log debt paid. Pushed 1ae48c07. WATCH: +6.6-7.1 s TTFT drift vs pre-merge S1+S2 record (148.4→~155) — up176 merge in tree, unseparated; re-check in window 2 |
| impl-L2C | worker | pool-layer / port/pool-layer | DONE 2026-10-24: fcea8272 (+165/−6 in vk_tier.c/tests/docs); premise HELD (no !v->host exclusion; BDA real via pool_bda); tiny-gate proof: 8/16 layer steps hybrid, gate opened with ZERO device residency, token-exact; all gates green run-1. Merged ff → 6fe02794 w/ PORT_STATUS note, pushed, cleaned |
| bench-P1 | worker | up2276-merge / port/up-2276 | DONE 2026-10-24 (see assessment below) |
| gap-spec | worker | specs/G1-pipeline-gaps.md | DONE 2026-10-24: 333 lines — per-token 81.6 frames/submits, wait accrues in 43 per-layer vkc_finish drains; host MoE only 30.3 ms/tok; **the 196.5 ms gap is a HYPOTHESIS not a measurement** (legs diverged 512/768-row chunks; ttft-set arms bound that world ≈ no gap); fork's queue-ahead = prefill-only + wall-NEUTRAL in the fork's own record; ranked slices S0→S3/S1/S2 with falsification bars |
| impl-G1S0 | worker | dprof / port/dprof | DONE 2026-10-24: d602436a (+167/−4; 3 deviations justified — submit-time role stamping, seg-top window, one-row block accumulator); byte-identity A/B verified; gates green run-1. Merged ff → 6d57f849 w/ PORT_STATUS note, pushed, cleaned |
| bench-DPROF | worker | up2276-merge / port/up-2276 | DONE 2026-10-24: **G1 = ARTIFACT** — R1 fires every leg (ΔA1 5.16–5.58 ms/tok ≪ 25; A1 fence wait = 97.7% device time); H1 (promote-under-fences) falsified; R4 no escalation; S1/S2/S3 close unfunded. Decode wall now fully attributed: chain device 235.0 (14.5%) + tier MoE CPU 821.9 (50.7%) + forward glue 518.8 (32.0%). Side datum: PROMOTE=0 > PROMOTE=32 at the standing decode set (0.658 vs 0.608 — residency not pipeline; cross-day vs the 0.670 record — needs a proper A/B if chased). Evidence V-g1-dprof doc + 5 logs; pushed 073a03b6. Also recorded: profile-ttft-fill × decode-pool OOM hazard |

## Campaign close-out 2026-10-24 (manager) — the in-doctrine phase is COMPLETE

Every rung of the ladder (L1 retention / L2 vk_dmoe A+B+C / L7 F8 / G1 pipeline-gap / S7 store / K1 kernels) is now landed or falsified **with model-scale evidence**. Decode fully attributed: 822 ms/tok host expert compute + 519 ms/tok glue + 235 ms/tok device — both host masses are fold-shaped (Option B). TTFT likewise (loop order + ring; prefill dmoe driver-bound). **Remaining open items:** (1) Option B go/no-go — OWNER decision, the only full-parity path (4.5–7k lines, 5–8 wk, LOW-MED confidence); (2) PR consolidation — mm8 push + strict/host-pool re-cuts + fmt-7 rows + dmoe/pool-layer capability PRs + DPROF + frag-mask; (3) D11 golden re-pin (8 h GPU, owed before strong parity/numerics claims); (4) decode-config PROMOTE A/B (minor). No further in-doctrine implementation lanes are justified by the evidence.

## Campaign assessment 2026-10-24 (manager)

**The staged ladder is measured to its conclusions.** Landed on port/up-2276: up176 merge, fmt-7 vkc_moe_rows (Stage B), COLI_VK_DMOE wiring + tiny gate (A), COLI_VK_TIER_POOL_LAYER (C), + prior session's mm8/profile/S1+S2. Falsified with evidence: L7 (13.1% share), prefill-chunk dmoe (driver hang boundary — needs frame-split to even test; payoff −2.5–5 s), decode dmoe-hybrid (−1.4%/layer, bus-bound shuffle), pool scaling (3.84 GiB/layer — ~1 layer ceiling on 34 GiB cgroup). **Remaining gap to fork (TTFT ~1.4×, decode ~2×) is architecture-bound**: the fork's fold = VRAM-resident majorities + one-submit cells + loop order (Option B: 4.5–7k lines, 5–8 wk, LOW-MED confidence). Not yet explored: **~200 ms/tok pipeline gaps** (fence 439 vs device-time 242 — queue/submit discipline, the fork's queue-ahead class; in-doctrine, moderate). Also owed: D11 golden re-pin before strong parity claims.

**Strategic options for the owner:** (A) consolidate + PR queue — mm8 push, strict-gate/host-pool re-cuts, fmt-7 rows, pool-layer/dmoe capability PRs, frag-mask; (B) pipeline-gap investigation then decide; (C) Option B transplant (the only full-parity path; consciously relaxes D3).
| impl-L7A | worker | gemv8 / port/gemv8 | DONE 2026-10-23 — **NO-GO per pre-registered rule, nothing built** (worktree removed, branch deleted, 0 commits). Criterion (b) passed (fmt-12 GEMV 2.5–9.8× off the 315–325 GB/s floor) but (a) failed: fmt-12 bucket = 57.3 ms/tok = **13.1% of decode device wait** (<25% bar); perfect kernel buys ≤2.5% of decode wall. Corrections: "1.6 s/tok device wait" was prefill-inclusive (real: 439 ms/tok fence / 242 device time). Spec updated with results + pivot; logs in bench-colibri/up2276/gemv8-step0-prof-{8,24}.log |

### L7 Step-0 decode attribution (the new map, 2,515-tok prompt, MM8=1 HOST_GB=8 PROMOTE=32)

- decode wall **1,770 ms/tok** (0.565 tok/s): device wait 439 (24.8%) + **host ≈1,331 ms/tok (75%)**
- **only 20.5% of routed experts on device at decode** → expert-side host compute dominates → L2 decode half (vk_dmoe wiring) + Stage C residency are THE decode levers
- chain buckets: MLAW 71.1 > attn 63.8 > fmt12 57.3 > mHC 36.1 ms/tok; MLAW pre-judged wash by fork s1g record
- NEW observation for later: **~200 ms/tok pipeline gaps** (fence wait 439 vs device time 242) — queue/submit discipline class (fork's queue-ahead); Option-B-adjacent, investigate after L2 lands

Merge policy: manager merges accepted lanes into port/up-2276 after review; three shared one-liners (chain-report fprintf, ENVIRONMENT rows, test main call site) serialize at merge time. Bench window (VRAM-guarded, ×3 interleaved, incl. fresh post-merge control re-baseline) runs AFTER both lanes land, serialized.

## Follow-up queue (not yet scheduled)

- **frag-mask gate fix** (PR candidate): strict gate's `norm` doesn't mask the tier exit-summary `frag X.XX` ratio → intermittent unset/0 comparison failures. One-line mask + justification; fold into an existing small PR or standalone.
- **Spec errata to apply at implementation time**: L2 — P1 chunk-visits 2→4 (@rows=768), disk-load 19.7k→34.5k figures are commit-message-only (corroborate via HANDOVER §2.3), re-pin 2 shader anchors by symbol, vk_dmoe.h 678→679 lines. L7 — re-attribute "no per-op table" quote to Option-B dossier open-q4 (:519-521), int4/int8 labels on 146→190/314→370, hedge "RADV" in qdq gloss.
- **Anchors to re-verify post-merge**: deepseek_v4.c VktConfig/.stage (+26), backend_vulkan.c mx block (+26), vk_chain.h VkcPrewarm/VkcStats (+3), deepseek_v4_chain.h report line (±1), ENVIRONMENT.md by knob name; re-confirm zero-drift files at committed head.

## OPTION B APPROVED (owner, 2026-10-24) — the fold transplant campaign

The owner committed to Option B. Manager structure: OB0 plan → review → staged implementation lanes (manager-merged, per-stage gates + falsifiable arms + stop-loss), DPROF as the per-stage instrument, D11 goldens as the pre-surgery baseline.

| lane | agent | owns | status |
|---|---|---|---|
| OB0-plan | worker | plans/OB0-fold-transplant-plan.md | launched 2026-10-24 (CPU-only): slice the 4.5–7k into 4–8 mergeable stages w/ anchors both trees, VRAM budget, reuse inventory, do-not-retry constraints, numerics strategy, stop-loss |
| D11-golden | worker | up2276-merge + .golden/ (EXCLUSIVE GPU, 12h budget) | launched 2026-10-24: re-record goldens at 073a03b6 per the repo's own procedure — the pre-surgery numerics baseline |

Next after OB0: reviewer lane cross-examines the plan (dossier + falsified-list + VRAM arithmetic), then stage-1 implementation.
| OB0-plan | worker | plans/OB0-fold-transplant-plan.md | DONE 2026-10-24: 469-line charter — 6 stages (S0 prefill-DPROF → S1 VRAM bank + ROWS_MAX frame-split → S2 decode heat/repurpose → S3 layer-outer → S4 ring → S5 decode cell), anchors both trees (9 self-corrected), ~2.2–3.5k LOC / 6–10 wk, risks register incl. upstream check (7 commits since 7398a85f, tier-adjacent, none in our files → merge pre-stage-1, AFTER D11 finishes — D11 owns the worktree/tip a46dad8d) |
| OB0-review | reviewer | none (chat report) | launched 2026-10-24: adversarial pass — anchors, do-not-retry completeness, VRAM arithmetic, stage independence/stop-loss, S2's differentiator, S0 premise, merge advisement |
| OB0-review | reviewer | none (chat report) | DONE 2026-10-24: 42 anchors checked (40 exact), every measured number reproduced; 2 tree-contradictions caught (F1 S1 chunk-leg self-contradictory stop rule + guard-trips-by-construction; F2 S2 re-counts the landed mfu_table lift); verdicts S0/S4/S5 GO, S1/S2/S3 GO-WITH-FIXES; stage-1 NO-GO as-written → GO after charter edits |
| OB0-fixes | worker | plans/OB0-…md (r2) | launched 2026-10-24: apply F1–F8 surgically; preserve verified numbers/structure |
| OB0-fixes | worker | plans/OB0-…md | DONE 2026-10-24 (r2): all F1–F8 applied — engagement guard (device-served share ≥~90% of 97.0% control) replaces the auto-firing prefetch guard; S1 stop rule re-scoped (chunk-miss records, only machinery failure cancels); S2 rescoped to ~250–500 LOC (tier ranking → .coli_mfu, authority rule: mfu wins decode, usage wins prefill, never merged); S3 owns per-layer banking + 2-layer test case; F7 operational freeze + pin re-validation rules; totals 1.8–3.3k LOC. **Charter EXECUTABLE — all gates now on D11 completion** |
| D11-golden | worker | up2276-merge + .golden/ | DONE 2026-10-24 (4.56h of 8h budget, 2 full runs): baseline BANKED at .golden/cache/073a03b6…/ — CPU channel token-exact + A==A′ sha-equal (deterministic); greedy byte-identical everywhere; GPU TF = F8 envelope, run-stable per config (deploy 13 / pinned 9 flips, positions valid within-config); diff contract recorded (PRIMARY greedy, SECONDARY CPU TF, GPU TF count-band). Harness ported (a46dad8d); fork .golden untouched. 3 commits pushed → 563bb643. **RIG UNFROZEN** |
| OB-S0 | worker | ob-s0 / port/ob-s0 | launched 2026-10-24: Stage S0 prefill-DPROF per charter r2 §3 — settle the ~90s host-MoE subtraction estimate; instrument-only, byte-identity A/B, gates + plan-specified measurement legs |
| OB-S0 | worker | ob-s0 / port/ob-s0 | DONE 2026-10-24: 78bec86c+092d39ca (144 ins/7 files; MOEH/STAGE wall-roles justified; gates green run-1; byte-identity A/B clean; vulkan_engines.sh deepseek env-blocked = pre-existing, proven at base). **VERDICT: §1.2 attribution INVERTED — host-MoE 49.2 s (31%, over-attributed 2×), staging-upload 105.6 s (66%, under-attributed 3.5×, the dominant mass), dense A1 4 s host w/ 70 s device GEMM fully overlapped.** Merged ff → 092d39ca, pushed, cleaned; charter r3 (S3 bars re-expressed vs staging bucket: 105.6→<53 AND 49.2→<25, or TTFT 159→≤134) |
| sync-ob1 | worker | up2276-merge / port/up-2276 | launched 2026-10-24: upstream sync-merge (verify 7398a85f..upstream/dev claim from fetched diff) + full gates + **F7 post-merge D11 pin revalidation control** (greedy/CPU-TF primary; GPU-TF count-band) → ff + push |
| sync-ob1 | worker | up2276-merge / port/up-2276 | DONE 2026-10-24: range GREW to 67 commits/81 files (KV16/kv-oom batch #2330; vk_chain.c +26/−8 now touched, vk_dmoe.h clean); merge 6506a18c w/ 3 N2-method resolutions; 1 self-caught segfault (format-string mis-resolution, fixed+amended); gates 7/7 green (strict run-2 flake protocol); **F7 REVALIDATION PASS** (greedy 9/9 ×4, CPU TF 18/18, GPU TF 1 flip pos-7 = D11's near-tie class); report Y-ob1; ff → 473fd669, pushed |
| OB-S1 | worker | ob-s1 / port/ob-s1 | launched 2026-10-24: the VRAM expert bank per charter r3 §3 S1 — carve/tenure/refill + ROWS_MAX frame-split, 2-layer gate case, engagement guard arms deferred to the bench window |
| OB-S1 | worker | ob-s1 / port/ob-s1 | DONE 2026-10-24: 33136aa2 (+782/−12, 17 files) — anchors drifted +10..+130 through the 67-commit merge (full table in Z §1); gates CAUGHT the auto-switch thrash → rotation explicit (vkt_bank_switch, S3 owns it); 2-layer case green both ways (3.4e-7); split units bit-identical ×3; strict 3/3; byte-identity GREEN (D11 contract). Merged → 030a875b w/ PORT_STATUS, pushed. **LESSON (2nd time): sync lanes leave worktree HEAD on the side branch — manager must verify `git branch --show-current` before merging; standing rule added** |
| bench-S1 | worker | up2276-merge / port/up-2276 | launched 2026-10-24: S1 arms per charter r3 — C0 ×3, decode leg (BANK=26+DMOE=26), chunk leg (+ROWS_MAX split), no-bank sub-leg (ROWS_MAX=512); engagement guard ≥~90% of 97.0%; ceiling ≈3.5 s/layer measured; stop rules per r2/r3 |
| bench-S1 | worker | up2276-merge / port/up-2276 | DONE 2026-10-24: 15/15 rc=0. **D-bank decode MISS (−0.54%, single-layer inert — records, no cancel); K-bank chunk MISS (+341.5 s — coexistence falsified as pre-registered, no cancel); N≡C1 (all regression = carve-cost, zero compute-cost); banked-layer COMPUTE VALUE = K−D −12.4 s TTFT / −15.9 s MOEH ≈ 4× the per-layer ceiling; ROWS_MAX held at chunk scale — NO device loss (first chunk-scale dmoe without the hang). Machinery clean → S3's gate stands.** DPROF: STAGE 105.6→0.2 (banked layer), MOEH→448 disk-bound carve cost, A1 72.5 de-overlapped (chunk fit 2048→256). D11 text: C1 3/3 + md5-equal to window-2 C0′; D/K deterministic, divergences in-band. Evidence AA doc; 9a138417 pushed. Settle-to-floor discipline added after a teardown race |
| OB-S3 | worker | ob-s3 / port/ob-s3 | launched 2026-10-24: the layer-outer prefill reorder — v4c_forward_seg layer-major + per-layer bank rotation (S1's vkt_bank_switch + fork switch discipline); S3 bars: STAGE <53 s AND MOEH <25 s, or TTFT 159→≤134; gates incl. 3072-decline re-test + S0 line as engagement gate |
| OB-S3 | worker | ob-s3 / port/ob-s3 | DONE 2026-10-25: f6930b1a (+759/−12, 8 files) — the reorder as a SECOND DRIVER (~370 lines, default chunk untouched); gates caught 2 real bugs (lbase list-region read = the numerics symptom, host-buffer overflow) both fixed; bit-equal at GEMM_ROWS=0, token-exact everywhere, 63 PASS tiny-dmoe at tip, golden --quick ALL GREEN. Gate-policy note: DMOE=1 ROWS=1 brio pin leg flips standalone vs run-mutated .coli_usage (pre-existing; regen = deterministic-green). Merged ff → 54405ce0 w/ PORT_STATUS, pushed, cleaned |
| bench-S3 | worker | up2276-merge / port/up-2276 | launched 2026-10-25 (3h, EXCLUSIVE GPU): C3 control / L-order (reorder alone) / F-fold (composed) ×3 + DPROF reps; **r3 bars: STAGE <53 AND MOEH <25, or TTFT ≤134; falsifier <10 s** |
| bench-S3 | worker | up2276-merge / port/up-2276 | DONE 2026-10-25: **VERDICT MISS per r3 — stop rule applied** (keep S1/S2, S4 cancelled, S5 shrinks; the fold's TTFT claim closes as measured negative). C3 154.84/0.5546; **L-order 153.62 (TTFT null in band) but decode +4.9% (0.5816 — real, replicated)**; F-fold 556.2 (+401.4) — STAGE→0.5 s (the bank DID kill all staging) but dmoe 0 steps ×4 (**cold-start ordering gate**: the all-or-nothing gate reads at the forward's HEAD, the bank fills only DURING the loop; the fork's answer = ring-prefetched fill always ahead) + reservoir 2.6 GiB collapsed chunk fit 2048→256; silent prefill-decline path (observability gap, bounded 2 candidates in AC §4). Rotation itself perfect: 43 tenures, 7,757 at-most-once fills = 113.63 GiB exactly, ledger exact ×4. Text: 0 divergence everywhere (the reassociation path never ran). AC doc; 0c847722 pushed |

## Comparative audit wave (owner-directed, 2026-10-25): "same prompt, same situation — find the missed optimisation"

| lane | covers | status |
|---|---|---|
| audit-race (GPU) | fork vs port head-to-head, same prompts, text quality, both engines' own accounting | running |
| audit-shaders (CPU) | per-op-class kernel census, 12.8-vs-15.0 MiB slab, fork-only kernels | running |
| audit-placement (CPU) | memory map + submission census; steered to add barrier counts + copy-pipeline threading (inline 8-stage vs ring thread qd16 O_DIRECT) | running |
| audit-cpu (CPU) | CPU parity: matched-compute-location ~10% decode gap (fork fold-free 0.61-0.63 vs port 0.55-0.58), OMP/binding on 8P+8E, CPU expert kernel census, build flags, **MTP/spec-decode engagement in the fork's 1.16** | running |
| audit-clocks (GPU micro) | sclk residency during both engines' decode windows (fork's own record blames sclk residency) | QUEUED behind audit-race |
| audit-barriers (CPU) | dedicated barrier census — GPU sync objects/forward (chain ~500/decode-token class, tier's own-queue cross-queue sync, fork's cell CB) classified by RADV cost class + host-side sync points (mutex-under-IO, fence settles, OMP, inline fills vs ring thread) + reducible-synchronization ranking + microbench designs | running (owner-directed) |
| audit-placement | worker | audits/placement-submission-census.md | DONE 2026-10-25 (312 lines): **NO stop-finding — the gaps tile EXACTLY onto placement differences that are NOT the cell-pipeline architecture.** (1) expert packing: fork 12.75 MiB fp4 vs port 28.8 MiB effective (2.26×/GiB) → tier holds 277 fixed vs fork's demand-growing 8.3 GiB/gpu_cap=954 at decode; (2) fork decode disk traffic 0 bytes vs port 91.85 GB; (3) the fork's own EXPERTS=1/0 A/B prices its decode placement stack at ~1.95× ≈ our 2× gap; (4) prefill STAGE 105.6 s = inline sync fills (1.74 GB/s effective) vs fork ring thread qd-16 O_DIRECT take_join=0; barriers bounded-dead (0.6%); S7's residency inference flagged (fork fast arm = 0 store requests at decode). 16-difference reconciliation + ranked never-tested list in the audit |
| audit-shaders | worker | audits/shader-census.md | DONE 2026-10-25 (189 lines): **STOP-FINDING: the gap is NOT kernels** — 9/16 op classes same-class/measured-equivalent (mm8 = the fork's kernel ported; s1 fp4 matched; prefill expert GEMM same-class with FEWER dispatches). Kernel ceiling ≈155–205 ms/tok of the ~750 decode gap, ~0 of TTFT. **4 named never-tested kernel wins: head-on-host (−60..70 ms/tok, V-g1 anchor 72.9), V4 FA tile + f16 KV (−40..55; port runs chain_dsv4 mode-0 scalar at ~32× KV bytes — sparse_attn never ported), UE8M0 u8 scale pack (−15..16 s TTFT + 17.6% residency — the slab mechanism), mHC fuse (−20..30 ms/tok).** The fold marked tested-falsified-at-this-budget |
| audit-cpu | worker | audits/cpu-parity-census.md | DONE 2026-10-25 (225 lines): config parity byte-equal (same rig/env); **CPU expert kernels BYTE-IDENTICAL** (diff-verified rows16/swiglu family; port has extras); build flags identical; **MTP DECISIVELY NO** (0 accepted drafts in the one engaged arm, fork's own replay catastrophe — no hidden multiplier); never-tested: fork's decode MoE LANES=6 (in headline arms, never ported; +23%/−32% at fork operating points, UNPROVEN on port stack — our 'demand lanes' falsification was a different design), host router/head placement (10–40 ms/tok), hybrid-core OMP placement (inflates BOTH ~15–25%, zero parity delta) |
| audit-race | worker | bench-colibri/up2276/audit-* + report | DONE 2026-10-25: same-day ground truth — fork 107.5/1.143 + 108.2/1.126 vs port 154.6/0.537 + 154.0/0.546 (gap ×1.43 TTFT / ×2.10 decode / ×1.66 wall; ×8 rc=0 at the exact floor). **TEXT: NO degradation** (coherent, same semantics both prompts, no repetition/truncation — the gap is purely performance). Reconciliation: fork decode = glue-only (53.2 s/63 tok = 844 ms/tok, 0 expert requests — the ring fed everything); port = 86.9% host-served decode. **Port wins TTFT < ~535 tokens** (fork TTFT prompt-independent ~102 s). Fork gpu-mfu reorder-guard + port counter-tick anomalies: benign, recorded |
| audit-barriers | worker | audits/barrier-census.md | DONE 2026-10-25 (288 lines): **STOP-FINDING (loud): sync is dead on both sides** — port ≤10 ms/tok of 1,620 (0.6%); the fork itself measured the class dead. Asymmetry INVERTED vs expectation (port submits FEWER CBs/token at decode: 87 vs fork ~250-430). 3 corrections recorded (R-l1 mutex-read superseded at tip; d_submit 3.8-4.5 not 1.4; barrier figure corrected). 6 microbenches designed not run |

## AUDIT SYNTHESIS (manager, 2026-10-25) — "the missed optimisations, ranked"

Ground truth (race): fork 107.8/1.135 vs port 154.3/0.542. Gaps: TTFT 46.5 s, decode 965 ms/tok. Text: NO degradation.
Ruled OUT: kernels-as-class (shader census; ceiling 155-205 ms/tok), CPU kernels (byte-identical), MTP (0 accepted), barriers/sync (0.6%), config/build (parity), glue (port 519 < fork 844).
The gap decomposes onto: **(A) decode expert placement stack ~822 ms/tok** — packing 2.26× (12.75 MiB fp4/u8-scales vs 28.8 effective), fixed-277 vs demand-growing-954 residency, 91.85 GB decode disk traffic vs 0; **(B) prefill staging serialization 105.6 s** — inline sync fills vs ring thread qd-16 O_DIRECT; **(C) kernel wins ~120-155 ms/tok** — head-on-host 60-70, FA tile+f16 KV 40-55, mHC fuse 20-30; **(D) UE8M0 pack −15-16 s TTFT** (feeds A too); **(E) lanes unpriced** (fork +23% at its points; Step-0 probe first).
**CONCLUSION: fork parity is achievable WITHOUT the cell-pipeline transplant** — via tier/store placement+packing policy, copy-pipeline threading, and 3 kernels. The S1-bank/S3-reorder machinery landed is reusable (esp. for A's residency work). Option-B fold stages: retire.

## PARITY WAVE (owner-approved, 2026-10-25): implement the audit findings, D→A→B→C→E

Pre-registered expectations (from the audits; windows compare against THESE):
- PW-D UE8M0 u8-scale pack: TTFT −15…−16 s; tier capacity +17.6% (277→~326); lossless⇒token-exact (verify; if lossy anywhere → env-gated + D11 contract)
- PW-A decode placement: A1 demand-growing residency (fixed 277 → MFU-ranked growth; device share 13-22% → fork-class) + A2 zero-disk decode (91.85 GB → ~0); decode recovery bounded by the 822 ms/tok host-MoE mass
- PW-B ring copy-worker: STAGE 105.6 s → <10 s; TTFT toward ≤110 with D
- PW-C kernels: C1 head→device (−60…−70 ms/tok; V-g1 head term 72.9-88.1), C2 FA tile+f16 KV (−40…−55), C3 mHC fuse (−20…−30)
- PW-E lanes probe (instrument only)
Targets: decode ≥1.0 tok/s, TTFT ≤110 s. Serialized on vk_tier.c: D→A→B. C-series parallel (disjoint files). Reviewer pass per merged slice; bench windows W1 (D+A1), W2 (A2+B), W3 (C).

| lane | owns | scope | status |
|---|---|---|---|
| PW-D | pw-d / port/pw-d | commit audits→docs/research/AD; reconcile 15.0-vs-28.8 slab figures; UE8M0 u8-scale packing (lossless⇒unconditional+token-exact, else env-gated); capacity 277→~326 | launched |
| PW-C1 | pw-c1 / port/pw-c1 | head→device (−60..70 ms/tok expected; V-g1 head term 72.9-88.1); DPROF head term = engagement counter | launched |
| PW-A1/A2, PW-B | queued | after D lands (vk_tier.c serialization) | — |
| PW-C2/C3 | queued | after C1 (chain/shader files serialize) | — |
| reviewer | queued | per merged slice | — |
| bench W1/W2/W3 | queued | after D+A1 / A2+B / C | — |
| PW-C1 | worker | pw-c1 / port/pw-c1 | CLOSING as **PREMISE-FALSIFIED** (gdb census + exact count decompositions + 1096.0=1010+86 MiB close-line arithmetic): the head AND router are ALREADY device-computed at standing (audit misread the DHO host-copy line + chain-header comment). No code change; AF doc = the published correction (shader-census rows 13/14, cpu-census placement claim). Residual head-term wall (72.9-88.1 ms/tok = per-op wall absorbing queued work) → follow-up ledger as PORT-NOVEL (fork doesn't fuse it either). **Ledger re-rank: phantom −60..70 removed; C2 (FA) now top kernel slice** |
| PW-C2 | worker | pw-c2 / port/pw-c2 | launched 2026-10-25: FA tile + f16 KV for the V4 chain (COLI_VK_CHAIN_ATTN_FA, default off); expectation −40..−55 ms/tok vs the 63.8 attention bucket; route: existing chain_attn_flash vs port the fork's sparse_attn_fa |
| PW-C1 | worker | (closed) | **CLOSED 2026-10-25, merged 4b23513c** — premise-falsified with 4 evidence classes; AF doc = the published audit correction; worktree/branch cleaned. Kernel track re-ranked: C2 (FA) top |
| PW-C2 | worker | (merged) | **LANDED 2026-10-25 (51d94ac8 merge)**: route (ii) — fork sparse_attn_fa ported on mode-0's contract (chain_attn_flash falsified on 4 contract points); f16 KV as read-side mirror (same numerics class, half read bytes, zero writer surface); COLI_VK_CHAIN_ATTN_FA 0/1/2, refusals fall back to mode 0; unit oracle 8.4× decode (228 µs/layer ≈ 9.8 ms/tok — the fork's own class), 51× chunk; gates green; AG doc |
| PW-D | worker | (merged) | **LANDED 2026-10-25 (2c57868e merge)**: slab reconciled (15.0 = payload; 28.8 = tenure-ratio mislabel; true asymmetry +17.6%); **LOSSLESS proven 3 ways → unconditional, no env**; device fmt 15 (ue8m0-packed scales, 12.75 MiB), 9 consumers taught, CUDA keeps fmt 7 (follow-up); capacity 277→~374 residents; gates green run-1 incl. new packed_scales units; AE doc + AD audit series committed |
| review-PW1 | reviewer | none (chat) | DONE 2026-10-25: **C2 SHIP / D SHIP-WITH-FIXES (all P2) / cross-interaction OK / manager's union-merges OK**. Findings: import path doesn't refuse fmt 15 (contradicts AE §3 — unreachable today, fix anyway); scales_wide/coop_fmt fmt-15 gap (needs coop HW + pathological scales); 2 stale ENVIRONMENT wordings; C2's timing harness not in tree (8.4×/51× not repo-reproducible); minor doc nits. Lossless identity verified bit-for-bit; refusal ladder, mirror lifetime, byte-identity, KV-split independence all verified |
| PW-fix1 | worker | pw-fix1 / port/pw-fix1 | launched 2026-10-25: apply the P2 list incl. committing the FA timing harness (re-measure; report if >±20% off the published numbers) |
| PW-fix1 | worker | (merged) | **LANDED 2026-10-25 (ff → 27a3cd63)**: all P2s applied (import refuses fmt 15 + a latent double-free found+fixed in the VK_TEST block; coop drops 15 — smaller/safer, digest bits-neutral; ENVIRONMENT 7/15 wordings); harness landed (bench_chain_attn_fa, amdgpu-safe N=3 ≈ 0.9 s/submission); re-measured within ±20% of published (9.5× decode, 49.5× chunk — AG §8); gates green incl. strict ×3 |
| PW-A1 | worker | (merged) | **LANDED 2026-10-25 (2426c87d merge)**: COLI_VK_TIER_DECODE_GROW — one-time probe of actual free VRAM (memory_budget − reserve), MFU-ranked installs (S7 decode-only counts via VktConfig.decode_heat, the fork's cutoff rule), slots retired beyond free (floor 2), warm set never a victim; resume lane fixed a double-free + a rank-gate leak + a compile-break the prior lane never saw; unit curve green both legs; gates green; default-off token-exact. AH doc |
| bench-W1 | worker | up2276-merge / port/up-2276 | launched 2026-10-25: C0/G/F/GF ×3 + DPROF — vs pre-registered: C0≈138-142 (D's −15-16), G device-share↑, F attention −40-55 ms/tok, GF additive |
| bench-W1 | worker | up2276-merge / port/up-2276 | RUNNING, P0 FOUND + RECOVERY: **PW-D's fmt 15 corrupts resident-path expert compute at model scale** (bisect: 54405ce0 clean / 51d94ac8 C2 clean / 2c57868e D BROKEN / tip broken; STREAM=0 fails mid-decode after correct tokens ⇒ resident path, geometry/timing-dependent; unit proofs + tiny + review all missed it — a P0 under the review's P2 list). Recovery: default flip (fmt 15 → COLI_VK_TIER_FMT15=1 opt-in) + model smoke confirm + W1 proceeds with D-reads DEFERRED. Institutional: **model-scale smoke gate (~2 min) owed for tier/chain-default slices**. 9 diagnostic legs logged |
| bench-W1 | worker | (closed) | **CLOSED 2026-10-25 — W1 VERDICTS: G PASS (+16.0% decode, share 13.1→24.9%, 273→427 residents, 0 free VRAM → all from slot retirement, disk NOT reduced — installs are one-time); F PASS ABOVE BAND favorable (attention bucket −96.2%, −55.6 ms/tok, decode +8.8%, TTFT −5.1%); GF PASS additive (86.6%); D DEFERRED (P0 → fmt-15 opt-in d73b82e1).** Final: C0 155.317/0.5492 → GF 143.424/0.6779 (decode +23.4%, TTFT −7.7%). D11: 9/9 armed reps diverge (G mid-text residency class; F/GF token-1 FA numerics), all internally 3/3 stable. Full record AI-pw-w1 (P0 bisect + false starts + smoke-gate lesson); pushed 2426c87d..d30df627. **Cumulative standing: decode 0.549→0.678 (+23%) — fork 1.135 remains ~1.7×; TTFT 155→143 — fork 107.8 remains ~1.33×** |

## PARITY WAVE 2 (launched 2026-10-25/26, owner: keep going, extensive subagent use)
| lane | owns | scope | status |
|---|---|---|---|
| PW-Dfix | pw-dfix / port/pw-dfix | fmt-15 P0 root cause + fix at model shapes + **the model-smoke gate institutionalized** (make target, rig-gated); re-enable fmt 15 default only after model-proven | launching |
| PW-A2 | pw-a2 / port/pw-a2 | zero-disk decode: Step-0 quantify decode-window disk traffic from logs, then decode-set host coverage (mfu-ranked preload/pin at prompt-end; the fork's arena answer) | launching |
| PW-C3 | pw-c3 / port/pw-c3 | mHC S=1 single-dispatch pair (fork's mhc_dec_pre/post class; −20..30 ms/tok vs the 36.1 bucket) | launching |
| then: PW-B (ring worker, after Dfix — both vk_tier.c) · reviewer pass on the batch · W2 window (D-fixed + A2 + G/F stacked) | | | queued |
| PW-A2 | worker | pw-a2 / port/pw-a2 | **CLOSING as PREMISE-FALSIFIED (3 independent grounds)**: decode-disk mass IS material (54-59 GB decode-window = 59-63% of run bytes) BUT (1) the fork-parity claim was a **counter artifact** (fork store counter 0 beside v4_direct 52.7 GB decode — the port is AT PARITY; audit row 8 corrected — second counter-class error); (2) capacity bound: decode working set 4,000-4,440 distinct vs 2,064 slots = 2.1× — arithmetically unreachable; (3) the tree's own S7 arms measured mfu-ranked prewarm WORSE (misses 4,435→4,534). **Redirect: the real lever = the fork's 6 async MoE lanes hiding the ~53 GB decode reads (census row 7, never-tested, fork-priced +23%) — PW-E upgraded from probe to design slice** |
| PW-A2 | worker | (merged 066e852a) | **CLOSED + MERGED**: falsification recorded (AK doc, ±0.3% arithmetic on 7 legs); hotfix gate-debt repaired test-only (packed_scales armed-leg + third tier-check invocation, robust to either default); all standard gates green; ff-merged, pushed |
| PW-C3 | worker | (merged aebc09e0) | **LANDED**: premise HELD (port was 8 dispatches/site at S=1, not single-dispatch); chain_mhc_dec.comp behind COLI_VK_CHAIN_MHC_S1, refusal-safe; unit oracle 5.8e-11 + bf16 bit-identical at model geometry; smoke rc=0, engagement exact (−16254 rounds etc.); **honest verdict: ≈ −6.7 ms/tok device time — the dossier's wash-to-small class, NOT the census' −20..30** (the fork's +19% was its host-path fusion the port never had). Merge resolved a benign double-repair collision (both C3 and A2 had fixed the hotfix's packed_scales debt; A2's mode-arg design kept). Both gates certified at merged tip |
| PW-Dfix | worker | (merged ad42a3cf + repair) | **LANDED — the P0 root-caused and fixed**: host_pairs advanced scale pointers in FLOAT units while fmt-15 scales are ue8m0 BYTES → rows past the first read 4× deep off the scale range (row 0 always correct; model shapes decode garbage exponents → non-finite → the W1 router signature; 1-expert pools SIGSEGV'd). AND the gate blindness root-caused: rel() arithmetic with NaN never raises worst (the old hybrid case passed with 27 wrong rows at worst 0.00e+00) → NaN-aware regression case added. deepseek-v4-smoke gate institutionalized (make target, skip-clean, history-restore); **fmt 15 DEFAULT RESTORED** (all 3 smoke modes + model-geometry unit + gates green); d8a13df4 4 commits; merged w/ the same benign packed_scales double-repair collision + my own off-by-one stray byte (repair commit) |

## PARITY WAVE 3 (launched 2026-10-26)
| lane | owns | scope | status |
|---|---|---|---|
| PW-B | pw-b / port/pw-b | the ring copy-worker: stream fills off the engine thread (fork's pthread ring, qd-16, O_DIRECT class) — the 105.6 s STAGE mechanism; expectation: STAGE → <10 s, TTFT toward ≤120 with the stack | launching |
| PW-E-design | specs/AM-pw-e-lanes.md | the fork's 6 async MoE compute lanes vs our measured 54-59 GB decode-window reads (fork-priced +23%); implementation-ready spec, do-not-retry list respected (the port's 'demand lanes' falsification was a different design) | launching |
| review-PW2 | reviewer | adversarial pass over wave-2 merges (Dfix d8a13df4 + C3 4fc5d4d1 + the A2 repair) | launching |
| then: PW-E impl (post-review) · W2 window (the full stack: G+F+C3+fmt15+smoke-gated) | | | queued |
| review-PW2 | reviewer | none (chat) | DONE 2026-10-26: **Dfix SHIP-WITH-FIXES (P2s only) / C3 SHIP / manager merges OK (artifact-free)**. The stride fix verified end-to-end (every host_pairs site, the full fmt-15 consumer census — NO remaining f32-stride assumption); the NaN regression case proven it-would-have-failed-pre-fix (18 rows/8 off/32768 non-finite reproduced); C3 refusals/counters/KV-split-clean verified. Fix list: NaN-awareness is SPOT not general (2 one-liners owed); smoke coherence bar (degenerate 3-word pass); off-rig mutation hygiene; 3 stale comments; duplicate ordinal |
| PW-fix2 | worker | pw-fix2 / port/pw-fix2 | launched: the five P2s incl. a deliberate coherence-fail demonstration |
| PW-E-design | worker | specs/AM-pw-e-lanes.md | DONE 2026-10-26 (386 lines): the fork's PilotPool mechanism pinned exactly (3 job kinds, fail-closed joins, 6=topk, the +23%/−32% operating points + what the logs do/don't prove); mapped to the port's MOEH slot (V4VkToken + the proven rows[c*d] slice pattern); **both stop-findings answered LOUDLY in favor: NOT cell-pipeline-bound (no fold needed); prefetch-only is provably a subset — only the direct port (a) counts (~540-700 LOC, bar ≥+10% decode, md5-identical)**; pre-registered C0/E1/E2 arms + DPROF reads; the K-lesson encoded (slice restructure byte-identical BEFORE threading) |
| PW-fix2 | worker | (merged 5b5fdc78) | **LANDED (clean ff)**: all 5 P2s — NaN-awareness general (2 sites; v4_act:869 flagged out-of-scope for a future wave), coherence bar w/ FAIL-demonstration ('the the the' now fails), off-rig hygiene (own-file hold/restore proven under a private mount ns), comments/ordinal. Gates + smoke green; hygiene md5-verified |
| PW-B | worker | (merged d5991060) | **LANDED**: the stream ring (COLI_VK_TIER_STREAM_RING) — VktConfig.ring_batch hook, next-layer predicted fills on a worker into half-alternating slots, take/join at the fork's switch point, SYNC contract extended+held, teardown bounded, inline fallback everywhere; 2 real bugs caught by its own engagement legs (uninit ok[] counts; left>=2 dropping singles); unit ring cases + tiny-check-ring legs token-exact; default-off proven vs a clean archive A/B; honest ceiling recorded (chunk-0's 43 units stay inline under pred-gating — the fork-literal cold-shape arm pre-registered for the window) |
| bench-W2 | worker | up2276-merge / port/up-2276 | launched 2026-10-26 (4h, EXCLUSIVE GPU): C0 (fmt-15 default — D finally measurable) / GF (continuity) / FULL (+MHC+RING) / RING (isolated) / RINGCOLD (fork-literal shape, AN's arm) + DPROF reps; **targets: decode ≥0.70, TTFT ≤120; fork gap statement vs 107.8/1.135** |
| bench-W2 | worker | (closed 6ba3b4d1) | **CLOSED 2026-10-26 — the full-stack window**: 18/18 rc=0. C0 153.171/0.5751 (D capacity PASS +34% residents/decode +4.7%; D's TTFT −15..16 MISS — fill COUNT owns the wall, not bytes; STAGE unchanged 108.4); GF 154.208/0.6608 (continuity PASS in band; levers now OVERLAP — +14.9% over C0 vs W1's +23.4%); **RING: STAGE 1.1 s PASS (100× under bar) but TTFT +50.6 MISS — the ring engaged 42 jobs with EMPTY PLANS (8 filled/0 used): off-thread placement without plan coverage is a strict pessimization; fills fell inline-inside-MoE (host-MoE 44.9→131.0) + A1 fences idled (2.1→70.6). The fork's ring wins by UNCONDITIONAL whole-layer coverage — the RINGCOLD one-rule cold-branch change, gap recorded verbatim, no code improvised**; FULL 165.0/0.6768 (stack ≥GF PASS +2.4%; targets MISS both). RING ≡ C0 BYTE-IDENTICAL at model scale. Fork gap: best 0.677/154.2 = 0.60×/1.43×. My slot-starvation hypothesis FALSIFIED by the dprof legs (C0's slots unchanged; the MOEH balloon is ring-fallback serialization) |
| PW-B2 | worker | (merged 4dad446e) | **LANDED — the campaign's final slice before pause**: COLI_VK_TIER_STREAM_RING_COLD (the fork-literal cold branch + the necessarily-dropped below-rule filter — at smoke shapes the heat estimate admits nothing) + the stage-pool leak fix (W2's 8-expert cap re-attributed: empty plans + leak, compounding); smoke: RING+COLD 42 jobs / **1344 experts** (vs 8); texts byte-identical; W3 pre-registered in AP. **CAMPAIGN PAUSED HERE at owner request** |
