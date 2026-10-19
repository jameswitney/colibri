# colibri-upstream — port status

**Status:** active · Phase 0 baseline running · 2026-10-19
**Repo:** http://ai-container.local.lan:3000/pi/colibri-upstream
**Base:** `upstream/dev` @ `a0037a3a` (v2.0.0 + ~590)
**Source fork:** `pi/colibri-ds4-vulkan` @ `d11fba5b` (tag `port-source-2026-10-19` pending F1)

## Decisions taken (2026-10-19)

| # | Decision |
|---|---|
| D1 | Target `upstream/dev` |
| D2 | Repo `colibri-upstream` at `/root/Projects/colibri-upstream`, Gitea `pi/colibri-upstream` |
| D3 | **Option A** — upstream chain/tier survives; port capabilities, not the fork's per-op stack |
| D4 | **Both** serving models — `--kv-slots` for live concurrency + content-addressed cold KV |
| D5 | Upstream silent degradation by default; **opt-in strict mode, enabled by our tests/deploy** |
| D6 | Decode first, then long-context prefill |
| D7 | DSV4 engine surgery; generic fixes in shared code |
| D8 | Upstream PRs for generic slices |
| D9 | Freeze the old fork after tagging `port-source-2026-10-19` |
| D10 | **GO** — real-checkpoint baseline approved |
| D11 | **Approved** — 8 h golden re-record budget |
| D12 | Add `NOTICE`; never commit weights, `.golden`, or stage-oracle bundles |

## Phase 0 — where it stands

- Build at `a0037a3a`: clean (6.8 s, `VK=1 ARCH=native`).
- `vk-tier-check`: **PASS**; DSV4 activation 271/306 bit-identical to CPU, worst row 0.00e+00.
- `vk-chain-check`: **PASS**; KV split bit-consistent with `COLI_VK_KV_COLD=device`.
- Tiny oracle: **PASS** (torch/transformers venv installed in the baseline worktree).
- Real checkpoint: 2k/1-token chain arm running under a 24 GiB cgroup.

**Finding F13:** upstream's `COLI_VK_TIER_HOST` host pool defaults on and sizes
itself from `MemAvailable − 4 GiB`, ignoring `--memory-gb`; it allocated
**25.75 GiB** beside a 15.5 GiB engine cache and OOM-killed the first runs.
Baseline runs set `COLI_VK_TIER_HOST=0`. The knob is also missing from
`docs/ENVIRONMENT.md`. Fix design in progress.

## Next gates

1. Finish the 2k/8k chain and chain-off baselines (`docs/research/E-baseline.md`).
2. Land F13 (host-pool bound), P1.5 (strict gate), then P1.1 (KV cold v2).
3. Re-pin and record `.golden` (8 h approved).

The plan and all evidence lanes are under [`docs/PORT_PLAN.md`](PORT_PLAN.md)
and [`docs/research/`](research/).
