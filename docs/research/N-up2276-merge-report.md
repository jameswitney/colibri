# N: the recursive merge onto upstream #2276 — night report (2026-10-21/22)

**Branch:** `port/up-2276` @ upstream/dev `b90a369e` — worktree
`/root/bench-worktrees/up2276-merge`. Everything below is local (nothing
pushed, per instruction).

## What was asked and what was done

> "Pull the latest colibri and start recursively merging our improvements
> into the upstream code. Don't send to git yet, but build and assemble the
> code and documentation to a high quality. Use benchmarks to back your
> choices."

1. **Pulled upstream** — 177 commits past our previous base (`a0037a3a`):
   tier promote (#2258), the host-pool CPU-compute series, hybrid pairs,
   verify-row GEMV sharing, GGUF dense chains, and the CUDA tier (which
   compiles `vk_tier.c` a second time — a structural trap for two of our
   branches, defused below).
2. **Merged all four landed slices** onto the tip, in PR order, each built
   and gated before the next (see PORT_STATUS for the conflict table):
   strict gate → tier host pool → chain GEMM (#2253) → KV cold tier v2.
3. **Found and fixed one real regression** the merge introduced (the pin
   contract, below), plus three upstreamability traps the recon pass caught
   before they bit (CUDA double-compile, colibri pool regression, stale
   `.spv` blobs).
4. **Benchmarks** — 2,515-token prompt / 64 decode tokens, 28 GiB budget,
   interleaved arms, same methodology as `scripts/ab-forks.sh`.
5. **Documentation** — PORT_STATUS rewritten for the new base; the three PR
   descriptions refreshed (strict-gate and tier-host-pool materially
   repositioned); this report; the M1/M2/M3 recon reports.

## Benchmark results (RX 6900 XT, DeepSeek-V4-Flash)

| arm | TTFT s | decode tok/s | wall s |
|---|---:|---:|---:|
| upstream `b90a369e`, defaults | 266.1 / 264.3 | 0.603 / 0.613 | 370.5 / 367.0 |
| upstream, `COLI_VK_TIER_HOST=0` | 257.4 | 0.584 | 365.4 |
| **`port/up-2276`, defaults** | **251.9** | 0.603 | **356.4** |
| `port/up-2276` + `COLI_VK_CHAIN_GEMM_ROWS=-1` | **238.8** | 0.598 | **344.3** |
| upstream, `--memory-gb 18` (pool 16.0 GiB granted) | 258.2 | 0.625 | 358.9 |
| `port/up-2276`, `--memory-gb 18` (pool 512 MiB, plan-capped) | 262.0 | 0.551 | 376.3 |
| (old fork, same methodology, reference) | 105–107 | 1.16–1.18 | ~160 |

Reading so far:

- Upstream's tip **fixed its own decode gap** (0.487 → ~0.60 tok/s) with the
  host-pool CPU-compute series — the Phase-0 "outcome B" decode verdict is
  now half-closed by upstream itself.
- At a 28 GiB budget, upstream's now-default host pool **costs ~3 % TTFT**
  (266 vs 257 host-off) while buying ~3 % decode; their `ram_reserve`-only
  accounting keeps the pool generous.
- Our merged tree **keeps upstream's decode and beats both upstream arms on
  TTFT** (251.9 s): the plan-capped pool sizes itself smaller and the
  streaming decisions improve with it. The GEMM knob stacks: 238.8 s,
  **−10.3 % TTFT vs upstream's default** and −7 % vs upstream's best arm
  (host-off), decode unchanged.
- **The 18 GiB pair is the honest F13 story on the new tip.** Upstream's pool
  grants **16.0 GiB beside the plan's 17.65 GiB projection** — 33.7 GiB of
  claims under a 24 GiB cgroup — and survived this run only through lazy
  faulting; the arithmetic still spends RAM the plan already claimed, one
  big routed prompt away from the kill that motivated F13. Ours grants
  **512 MiB — exactly the plan's spare**. The trade is real and stated
  plainly: upstream's overspending pool *bought* decode at this budget
  (0.625 vs 0.551 tok/s — 1,076 pooled experts vs 23) at TTFT parity. The
  plan cap is a safety contract, not a universal speedup; an operator who
  wants the aggressive pool keeps `COLI_VK_TIER_HOST_GB=16` (the override
  wins over the plan, by design, with one line saying so).
- The old fork's numbers remain ahead (decode 2×; TTFT 2.4×). What closes
  the rest is not in the four merged slices: it is P3.2 (the pf4/RDNA2
  expert GEMM family — prefill) and the decode road upstream itself is now
  paving (their promote only fires when the *whole* expert set fits in the
  host pool, which a 167 GB model never does on this host).

## The regression the gates caught (worth retelling)

`deepseek-v4-tiny-check` failed on a freshly generated fixture:
`test_deepseek_v4_brio` "second option: reused 0 tokens, the pin holds 8".
Bisected to the KV cold tier merge. Root cause: upstream's pin contract
stores the pinned prompt's KV **at any length** ("a pinned prompt is short by
nature"); our cold-tier store dropped kind-1 captures under
`v4_ckpt_min_tokens()` (512) and dropped prompt-ends entirely at
`V4_PREFIX_CKPT_DISK=1`. The old fixture passed because the earlier suite
order masked it — regenerating the fixture (the check's own first step)
unmasked it. Fix: pins also take a memory slot beside whatever the cold tier
accepts; restore checks slots before the catalog. Full gate green again
(23 PASS).

Lesson recorded for the PR: our cold-tier branch must carry
`test_deepseek_v4_brio` (upstream's) in its own gate list, not only our
serve-framing tests.

## Upstreamability traps found by the recon pass (all fixed)

1. **The CUDA tier compiles `vk_tier.c` twice** (`cu_tier.c` includes it
   behind ~57 macro redirects): our `coli_vk_degrade` calls broke CUDA-only
   links (no-op macro added) and our public `vkt_host_room` collided as a
   duplicate symbol in `VK=1 CUDA=1` builds (`cut_host_room` mirror added).
2. **Our colibri.c hunk would have silently disabled upstream's landed
   `ram_floor`/`ram_given` pool behaviour** for budgeted runs — dropped; the
   tier-host-pool slice is now expressed as a cap composed with upstream's
   mechanism instead of a second sizing rule.
3. **Upstream builds `qmatmul_bd.spv`/`qmatmul_gate_up_bd.spv` from source**
   now — our branches' committed blobs dropped.
4. Upstream added two silent `bd_fmt` refusals in `coli_vk_matmul`/`_pair`
   (GGUF dense matrices on CPU, no line) — the strict gate now covers them;
   exactly the "broken deployment passes unnoticed" case the gate exists for.

## PR queue recommendation (nothing sent)

1. **#2253 follow-up** (one commit): the bare `make deepseek_v4` no-op fix —
   validated positively by mfethe1; the fix answers their only note. Consider
   also the two one-sentence behavioural notes (GGUF dense matrices and
   `use_prefill_pool=-1` under `-1`) in the PR body.
2. **strict-gate** — now includes the CUDA-compile story; ready when #2253
   lands or in parallel if maintainers prefer.
3. **tier-host-pool** — repositioned as an extension of #2258's mechanism;
   strongest after #2258 has settled a release.
4. **KV cold tier v2** — biggest slice; carries the pin-contract fix and
   upstream's brio test; needs its PR body written against the new base
   (tomorrow).

## What I did not do (and why)

- **No push, no PR** — per instruction. The branch lives in
  `/root/Projects/colibri-upstream` (worktree-shared object store); a Gitea
  backup push is one command when you want it.
- **F12 (`COLI_NO_OMP_TUNE` value check) deliberately not "fixed"** —
  presence-based disable is documented intentional behaviour family-wide
  ("any value, even 0, disables"); the M3 recon suggestion was wrong.
- **No new ports beyond the merge** — P1.2/P1.3/F14-v2 are the next
  candidates (M3 §4 ranks them), but stacking them on an un-merged base
  re-creates the divergence problem this branch just paid down.
- **`.golden` re-pin** — 8 h run; queued as a next gate, not sneaked into
  the night.

## Reproducing

```bash
git -C /root/Projects/colibri-upstream worktree list   # port/up-2276
cd /root/bench-worktrees/up2276-merge/c
make -f Makefile.deepseek-v4 VK=1 ARCH=native -j16 deepseek-v4
make -f Makefile VK=1 ARCH=native vk-tier-check vk-chain-check vk-strict-check
PATH=/root/bench-worktrees/port-baseline/.venv/bin:$PATH \
  make -f Makefile VK=1 ARCH=native deepseek-v4-tiny-check
/root/bench-colibri/run-arm2276.sh <engine-c-dir> <tag> [ENV=val ...]   # one arm
cat /root/bench-colibri/up2276/summary.txt
```
