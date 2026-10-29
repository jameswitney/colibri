# PR: Vulkan performance levers — default-on, probe-gated (DeepSeek V4 decode +40%, forked tensor lifetime, S=1 GEMV, FA)

Branch: `port/pr-perf` @ `c416ec40` (base: `upstream/dev` `d67ebd8b`; 168 campaign commits + merge + fixes).
Evidence: `/root/bench-colibri/up2276/{gap2,gap3,gap4}-*` (same rig, RX 6900 XT/RADV, DeepSeek-V4-Flash, 2,515-token prompt, ×3 interleaved).

## What this PR contains

1. **The performance levers, ON BY DEFAULT behind their own capability probes** (explicit `=0` or one `COLI_VK_LEGACY=1` hatch restores the upstream base byte-for-byte; one boot line per lever: engaged / refused:<reason> / legacy):
   - `COLI_VK_TIER_EXPERTS=1` — routed-expert compute-site (decode MoE on-device; the CS lever, +46% decode over standing in gap2)
   - `COLI_VK_V4_DECODE_PATH=fork` — the persistent slab registry tensor lifetime (imports 5040→0 ms/run, fence 306→122 ms/tok, release 636→7 ms; the alias = 3 callocs, 0 driver objects; auto-refuses on unified-memory devices via the memory-type probe — Strix Halo/iGPU/Lavapipe fall back to the standing path before allocating anything)
   - `COLI_VK_V4_S1GEMV=1` — the dedicated S=1 fmt-15 GEMV (live bit-exact parity gate per device; refuses to the generic GEMV on any mismatch)
   - `COLI_VK_TIER_DECODE_GROW=1 (+_HEADROOM)` — decode residency growth (probed free-VRAM, floors, never sheds below reserve; APU budget semantics correct)
   - `COLI_VK_CHAIN_ATTN_FA=1` — flash-attention tiles + f16 KV mirror (shape/pipeline-gated with mode-0 fallback + a named stderr line on refusal; **deterministic numerics-class change wherever it engages** — see the numerics note)
   - fmt-15 ue8m0 packing (already default upstream of this PR's base, unchanged)
2. **The stage preset extended to the measured shape** (`COLI_VK_PROFILE=RDNA2`: now also `CHAIN_ROWS_MAX=2048`, `STREAM_BYPASS=1` beside the existing MM8/GEMM_ROWS/SLOTS) — opt-in, one line, completes the measured configuration (the full default-on of the preset is deferred: its knobs reshape every tier test case's geometry and need the fmt-15-class expectations sweep — recorded in the commit log with the measured motivation).
3. **Stayed opt-in** (measured non-wins or trade-offs): ring/ring-cold (decode-for-TTFT), alias-cache (−39% thrash), attn-cell (neutral), stream rows/depth/group/pred, queue0.
4. Gates: the full VK suite green on the merged tree (vk-tier 8 legs incl. the forkdec/s1gemv legs, vk-chain, vk-strict with the new LEGACY-equivalence case, oracles, serve-framing, syntax); the portable build fixed (`view_slab` guard + `$(VK_OBJ)` wiring); `make check` at its 3 pre-existing failures; `COLI_VK_LEGACY=1` == upstream base byte-identical (tiny-fixture md5 `4b5a583d…`).

## Measured (same-session quartet + isolation legs, gap4)

| arm | decode tok/s | TTFT s |
|---|---:|---:|
| LEGACY (= upstream base) | 0.49 | 454–464 |
| **defaults (levers on)** | **0.68 (+39%)** | ~461 |
| defaults + PROFILE (recommended line) | — | **see the open item** |
| reference: fork colibri-ds4-vulkan | 0.95–1.01 | 108–110 |
| reference: the same stack pre-merge (gap3, PROFILE-class env) | 0.91–0.96 | 146–156 |

Decode-only summary across sessions: upstream-on-Vulkan 0.587 → this stack's full shape 0.91–0.96 (+55–64%), fork parity at matched memory.

## ⚠️ Open item (the honest blocker for the prefill half)

The 276-commit rebase onto current dev introduced a **prefill chunk-budget regression**: `vkc_chunk_rows`'s
free-memory computation reads ~0.27 GiB where the pre-merge tree read 4.0 GiB → 128-row prompt windows
(860 sub-batches) → TTFT 460–550 s vs the pre-merge 146–156 s. **Reproduced with every new lever disabled**
(`gap4-legacyprof` leg: 515 s) — this is a merge/upstream-plan interaction (upstream's kv-oom-era memory-plan
work meeting our tier accounting), NOT the levers. The planner function itself merged intact; the exact
collapsing term (device-budget read vs host-available clamp vs the stage-room subtraction) is the next
diagnosis step. Interim operator workaround does not exist yet (bounding the registry arena and the host
pool did not restore the read). Until fixed: decode benefits ship as-is; for TTFT-sensitive use, upstream
base ≈ the same TTFT (the regression affects it equally — legacy 454–464 s), so no user is worse off than
base, and pre-merge parity returns with the fix.

## Hardware notes (from the wave-4 audit, `gap-wave4/hw-risk.md`)

- **Unified memory (Strix Halo-class APU, iGPUs, Lavapipe)**: the registry refuses by memory-type probe
  before allocating; growth uses summed-heap budget semantics; host pool off on UMA; every lever degrades
  to the standing path with a named stderr line.
- **8 GB discrete / ReBAR off**: staged import ladder → residents-only degradation, `cs_refuse` counted.
- **NVIDIA**: registry arms (BDA + host-import verified in the wave-3 probe); S1GEMV per-device parity gate;
  FA compiles or degrades by LDS budget (48 KB devices: decode tile only) with the named line.
- **Low-RAM hosts**: the RAM plan clamps to MemAvailable with floors (the gap2 lesson: thread-creation
  failures were host-RAM exhaustion; the plan now hard-clamps).
- **Numerics**: FA and CS change the output class (deterministic, stable, thresholded — the W-CS S9 record);
  `COLI_VK_LEGACY=1` restores upstream outputs byte-for-byte.

## Reviewer structure

The branch preserves the one-commit-per-lever chain (merges documented per-conflict); suggested review
order: the registry (forkdec) → s1gemv → CS/grow/FA defaults → the gate flips → the merge. The campaign's
evidence trail (audits, session reports, per-leg logs) is preserved under `docs/campaign/` on the campaign
branches and summarized in the PR table above.
