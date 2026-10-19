# colibri-upstream

A fresh fork of [JustVugg/colibri](https://github.com/JustVugg/colibri)
(`upstream/dev`, v2.0.0+) intended to receive the measured capabilities of
[`colibri-ds4-vulkan`](../colibri-ds4-vulkan) — the DeepSeek-V4-Flash Vulkan
fork — through upstream's own chain/tier architecture.

**Status:** planning · 2026-10-19. No source tree yet; the repo is cut from
`upstream/dev` after the owner decisions in the plan.

## Read first

- [`docs/PORT_PLAN.md`](docs/PORT_PLAN.md) — the port plan, portfolio,
  phase gates, risk register, and the decisions required.
- [`docs/research/`](docs/research/) — the four evidence lanes the plan is
  built on:
  - `A-upstream-architecture.md` — what upstream/dev's DSV4 Vulkan path is
  - `B-fork-inventory.md` — every fork capability, classified for porting
  - `C-perf-evidence.md` — measured effect sizes, top-10, and the skip list
  - `D-risk-validation.md` — divergence, ABI/numerics risk, validation matrix

## The short version

Upstream now has its own DSV4 Vulkan stack (dense chain + shared expert tier),
so the fork's trigger for re-evaluation has fired. The plan keeps upstream's
architecture and ports the fork's *measured* wins in slices:

1. engine/storage: KV cold tier v2, reactive prefill fit, KV admission
2. decode I/O: demand lanes, async pilot, tier admission fixes
3. RDNA2 kernels: mm8, pf4, flash attention, idxscore/idxsel
4. prefill pipeline: only if the Phase 0 baseline says upstream is behind

The fork's `backend_vulkan_dsv4.c`, GPU-FOLD hardwiring, neutral cadence folds,
and 175-knob env surface are explicitly not ported.

## Next gate

Phase 0: build `upstream/dev VK=1`, measure the real DeepSeek-V4-Flash
checkpoint on this host, and compare with the fork's recorded baseline. The
result decides whether this is a delta port or a pipeline port.
