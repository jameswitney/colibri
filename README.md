# colibri-performance-pr

The **upstream-ready performance PR for [colibri](https://github.com/JustVugg/colibri)**, tracked separately from the port working repo (`pi/colibri-upstream`) so the review artifact, its evidence, and its history stay clean.

- **Base:** `main` = upstream `dev` @ `d67ebd8b` (verbatim — the PR's merge target)
- **PR branch:** `performance-pr` = the campaign's full stack (`44cd5675`+), 168 commits on the base
- **The Gitea PR:** `performance-pr` → `main` mirrors the upstream PR one-to-one
- **PR body:** [`docs/campaign/plans/pr-perf-body.md`](docs/campaign/plans/pr-perf-body.md) on the branch — the measured table, the default policy, the hardware matrix, the numerics note

## What it is

The DeepSeek-V4 Vulkan performance work from the `colibri-ds4-vulkan` fork, re-implemented on upstream and collected into one PR with the **levers ON BY DEFAULT behind capability probes**:

| lever | what | measured |
|---|---|---|
| `COLI_VK_TIER_EXPERTS` | routed-expert compute-site (decode MoE on-device) | +46% decode over standing |
| `COLI_VK_V4_DECODE_PATH=fork` | persistent slab registry tensor lifetime | imports 5040→0 ms/run, fence 306→122 ms/tok |
| `COLI_VK_V4_S1GEMV` | dedicated S=1 fmt-15 GEMV, live bit-exact parity gate | +2–7% |
| `COLI_VK_TIER_DECODE_GROW` | decode residency growth (probed, floored) | +16% (earlier waves) |
| `COLI_VK_CHAIN_ATTN_FA` | flash-attention tiles + f16 KV mirror | −18.6 s TTFT with the ring |
| `COLI_VK_LEGACY=1` | one env restoring the upstream base byte-for-byte | the escape hatch |

**Headline (same-session, RX 6900 XT, DeepSeek-V4-Flash, 2,515-token prompt):** env-free
defaults decode **0.95–0.97 tok/s** (fork: 0.95–1.01; upstream base: 0.59–0.71) at TTFT 236–248 s;
with the one-line recommended shape (`COLI_VK_PROFILE=RDNA2 COLI_VK_TIER_HOST_GB=2`):
**0.92–1.04 tok/s / 139.8–148.8 s** (fork: 108–110 s). LEGACY matches upstream's own engine to the
decimal (263.6 s) — merge-faithfulness evidence.

## Docs on the branch

- `docs/campaign/plans/pr-perf-body.md` — the PR body (send this text upstream)
- `docs/performance-pr/` — the evidence pack:
  - `gap-wave1-synthesis.md` — why the fork was faster (the diagnosis wave: the 2.07 GiB/token store re-read)
  - `gap2-bench-synthesis.md` — the uplift attribution vs upstream-on-Vulkan and the fork
  - `gap3-bench-synthesis.md` — the forked decode path's results (registry + S=1 GEMV)
  - `gap4-chunkfix.md` — the prefill chunk-budget regression: root cause (upstream's window-probe budget shadow), fix, before/after
  - `hw-risk-audit.md` — the other-hardware audit (Strix Halo/APU self-disable, NVIDIA, Lavapipe, 8 GB cards) and the default-policy spec

## Sending upstream

From the `jameswitney/colibri` fork: open the PR against `JustVugg/colibri:dev` from a branch matching
`performance-pr` (the docs-only commits at the tip may be dropped for the upstream send — everything
under `docs/` is review support). The branch is gate-clean: full VK suite green, portable build fixed,
`make check` at its 3 pre-existing failures, LEGACY byte-identical.
