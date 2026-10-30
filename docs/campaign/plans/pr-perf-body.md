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

## Measured (same-session quartet + isolation legs, gap4 — post chunk-fix 739727c8)

| arm | decode tok/s | TTFT s |
|---|---:|---:|
| LEGACY (= upstream base) | 0.65–0.71 | 264–270 |
| upstream's own engine, same session | ~0.59 | 263.6 |
| **defaults (levers on, zero env)** | **0.95–0.97 (+41–46% decode)** | 236–248 |
| **defaults + PROFILE=RDNA2 + TIER_HOST_GB=2 (the one-line recommended shape)** | **0.92–1.04** | **139.8–148.8 (−45% TTFT)** |
| reference: fork colibri-ds4-vulkan | 0.95–1.01 | 108–110 |
| reference: the same stack pre-merge (gap3, PROFILE-class env) | 0.91–0.96 | 146–156 |

**Decode parity with the fork from env-free defaults** (0.95–0.97 vs the fork's 0.95–1.01); TTFT within ~13% with
the one-line shape. The LEGACY arm now matches upstream's own engine exactly (263.6 s both) — merge-faithfulness
evidence. Pre-fix shadow-era numbers preserved in the gap4 logs; the cross-session story (upstream-on-Vulkan
0.587 → this stack 0.91–1.04, +56–77%) is in the campaign record.

## ✅ Resolved: the prefill chunk-budget regression (was the open item)

**Root cause (measured, `gap4-diag-r1/r2`): not the cgroup walk.** Instrumentation of the merged tree's boot
showed `compat_mem_available_gb` healthy at every read (28.0–32.2 GiB; the walk's room 28–30 GiB with the
file cache correctly credited) while the **device** budget read at the dense chain's fit collapsed to
0.67 GiB. The 276-commit rebase brought upstream's mapped-weights window probe (`ed196461`, "stage uploads
when the mapped window is under 9/10 of the heap" — the gap4 "upstream healthy" reference binary `c1c06ac6`
predates it, which is why upstream's own engine looked clean): the probe asks the host-visible device-local
heap for 13 GiB one GiB at a time and frees them all, and RADV's `VK_EXT_memory_budget` still counts the
freed blocks for ~0.2 s after. The chain fit lands inside that window → "the chain stays off (free 641 MiB)"
→ the dense part falls back to host RAM → the CPU prefill walks fixed 128-row windows (860 sub-batches) →
TTFT 460–550 s. Reproduced with every lever off because the probe is upstream's, not a lever; the planner
`vkc_chunk_rows` itself was never at fault. Counterfactual: the same tree with the probe's allocations
skipped (`COLI_VK_WINDOW_PROBE_MB`) read 14.67 GiB at the fit, chained 43/43 layers, sized 1,792-row chunks,
and ran 150.5 s TTFT — with no code change.

**Fix (`c/backend_vulkan.c`, `vk_window_decide`):** the probe now waits for the driver to read its freed
blocks back before anything sizes itself from the budget — poll `VK_EXT_memory_budget` until the heap's
free returns to its pre-probe reading (64 MiB slack), bounded at 2 s (a co-tenant may have honestly taken
the bytes; then it proceeds and says so). Measured: **201 ms**, one stderr line
(`[VK] memory: the window probe freed 13 GiB; the driver's budget read them back in 201 ms`), skipped when
the probe made no allocations (`COLI_VK_WINDOW_PROBE_MB`) or the extension is absent. No change to
`compat.h`'s walk, the fit, or any sizing semantic; boot-timing only, so LEGACY/unset outputs stay
byte-identical (tiny oracle PASS on defaults, LEGACY=1, and the all-off base).

**After (`gap4-full2-r{1,2,3}`, same rig/harness as gap4):** the engagement line at boot, 43/43 chain layers
on the device, **"prompt chunks of up to 2048 rows"** (4.15 GiB free at the chunk read), tier 6.40 GiB —
and TTFT **139.8 / 148.8 / 147.5 s** (decode 0.92–1.04 tok/s): pre-merge parity restored (gap3 measured
146–156 s) and the recommended line now beats upstream's own current engine in the same session (263.6 s,
768-row chunks). The interim note is retired: no user was ever worse than base, and now none is worse than
pre-merge.

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
