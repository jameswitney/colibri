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
