# Y — OB1: the pre-S1 upstream sync-merge onto `port/up-2276` (2026-10-24, evening)

**Lane:** OB1 (sole writer, exclusive rig) · **Branch:** `merge/ob1` (side branch off
`port/up-2276` @ `092d39ca`) → merge commit `6506a18c` — worktree
`/root/bench-worktrees/up2276-merge`. Method per N2 (side branch, gates before the live
branch moves, documented resolutions) and OB0-fold-transplant-plan r3 §7 risk 1 /
checklist item 1.

## What was asked and what was done

1. **Verified the movement claim from the fetched diff** — and it had grown: the plan's
   `7398a85f..681c0f17` (7 commits, host-pool-heap series) is now
   **`7398a85f..61646cbd` = 67 commits, 81 files, +4206/−425** (the KV16/kv-oom batch
   #2330 landed on top: colibri's latent KV in float16, qwen36 mux chains/KV_SLOTS>1,
   chain_moe_gv's int4 HQ fast path, the f16-overflow `wide` guard, windows commit-bound
   sizing, CANCEL/STOP prefill control, tests). Proceeded per the lane brief; the overlap
   is reported below.
2. **Merged on the side branch**, resolved 3 conflicts (2 beyond docs-class, both
   unions/compositions of independent semantics — N2 method), hunk-reviewed the
   watch files semantically.
3. **Full gate set green** at the merge tip (one incident, mine, below).
4. **The F7 post-merge pin re-validation** vs the D11 baseline — **PASS per the D11
   diff contract** (the gate before any armed Option-B arm records first-divergence).
5. `port/up-2276` fast-forwarded and pushed to origin after gates+control were green.

## The overlap the plan did not expect (reported per the lane brief)

The plan's §7-risk-1 file list ("none touch `vk_chain.c`, `vk_dmoe.h`, or
`deepseek_v4_chain.h`") was network-read at 681c0f17 and **no longer holds at 61646cbd**:

- `c/vk_chain.c` +26/−8 — auto-merged clean over our tree (the merged-vs-ours diff is
  exactly upstream's five hunks; none of our DPROF/`CHAIN_GEMM_ROWS`/MXFP4 regions
  displaced).
- `c/deepseek_v4_chain.h` +2/−2 — auto-merged clean: both `VkcKvPart` initializers
  widened with the new trailing `kv16` field = **0**.
- `c/vk_dmoe.h` — untouched (verified: zero diff vs ours).

No watch-file conflict markers; no watch-file semantic conflict (verdicts below).

## Conflicts and resolutions

| file | hunks | resolution | rationale |
|---|---|---|---|
| `c/deepseek_v4.c` | 1 | **union**: our `v4_vkt_load_{one,load,batch}` tier loaders (S1+S2 landed seam) kept whole, upstream's new `v4_state_later` (serve-state RAM accounting) added beside them before `v4_vk_tier_start` | two independent function families inserted at the same anchor; upstream's `.ram_later = v4_state_later(engine)` auto-merged into our `VktConfig` initializer beside our `.ram_planned/.ram_budget/.ram_spare` plan fields (both semantics carried; the pre-existing duplicated comment above `.dense_bytes` at 092d39ca left as-is — N2 leftover, cosmetic) |
| `c/vk_tier.c` (`host_init`) | 3 | **composition** (below) | the port's H RAM-plan fix and upstream's host-pool-heap series rewrote the same sizing block |
| `docs/ENVIRONMENT.md` | 1 | **row-union** of the tier env table | upstream's `COLI_VK_TIER_HOST` row (a strict superset: +ram_later +heap sentences) and new `COLI_VK_TIER_HOST_HEAP_GB` row; our `COLI_VK_TIER_PROMOTE` row (unchanged upstream); `COLI_VK_TIER_HOST_GB` composed (our RAM-plan text + upstream's "within the driver's heap" clause and KV note) |

`host_init` composition, hunk by hunk: (i) `want` = our plan-aware `vkt_host_room(...)`
with upstream's `- ram_later` folded into the **no-plan fallback only** (a planned
engine's state pages are the plan's own accounting — `v4_state_later` mirrors
`context_bytes`); our GB validation block verbatim; then upstream's driver-heap cap
(`coli_vk_tier_host_heap_room`, `cut`, `hh`) applied after it. (ii) The early-out keeps
our plan/plain "host pool off" messages with upstream's heap/ram_later variants ahead of
them. (iii) The `fit < left` cache-least adjustment keeps our `&& !T.c.ram_planned` guard
(plan already sized the pool beside the cache) around upstream's cut-aware subtraction
(`least - cut`). (iv) Boot reporting: our three branches carrying upstream's heap/ram_later
notes; our late `hl[32]` humanizer renamed `hm` (collision with upstream's `hl[96]` note).

## Watch files, reviewed semantically

- **`c/vk_chain.c`** — upstream's five hunks over our tree: (a) `moe_gvq[10][17]` +
  `vkc_moe_gv_hq` + spec-constant widening = the chain_moe_gv **int4 HQ fast path**
  (default on, `COLI_VK_MOE_GV_HQ=0` keeps the loop); fmt-4-class only, does not touch
  our `vkc_moe_rows` fmt-7 chunk path or the tier's issue paths; its numerics risk on V4
  decode GEMVs is exactly what the F7 control adjudicates (verdict: PASS). (b) the
  `!ti->wide` guard on the cooperative-matrix GEMM — strictly conservative (an
  f16-overflow correctness fix, `scales_wide` in `backend_vulkan.c`; can only turn the
  path off). (c) `vkc_mla_qkv`'s kv16 rounding — gated on the new `VkcMla.kv16`, which
  V4 never sets. (d) the shutdown destroy loop for `moe_gvq`. **No interaction with our
  DPROF window, `vkc_layer_recorded` batching, mm8/GEMM_ROWS, or MXFP4 mode-4 paths.**
- **`c/deepseek_v4_chain.h`** — both `VkcKvPart` sites widened with `kv16 = 0`: V4's KV
  split parts stay float32 host-side; **no behavior change for the V4 engine**. Our DMOE
  arm (`:683-715`, `:1380-1402`), GEMM_ROWS and DPROF prompt-window regions intact.
- **`c/vk_dmoe.h`** — untouched by the range.

## Gate incident (mine) and its fix

First `vk-tier-check` run at the merge tip **segfaulted** in `host_init`'s boot
reporting; the pre-merge base (092d39ca, `/tmp/base-ob1`) passed the same gate —
attribution to the merge, and to my own resolution: the composed `ram_planned`-branch
`fprintf` carried **four trailing `%s` for three arguments** (a varargs mismatch that
-O0 survives and -O3 turns into a wild `%s` read). `-Wformat` had flagged it at build
time (missed in the piped gate output). Fixed by dropping the unmatched specifier;
the merge commit was amended with the fix. Lesson recorded for the next merge lane:
grep gate-build output for `-Wformat` before running.

## Gate results (at the merge tip, `6506a18c`)

| gate | result |
|---|---|
| `vk-tier-check` | **PASS** (after the fix; MXFP4 g32 / FP8 g128 grouped-vs-per-pair legs included) |
| `vk-chain-check` | **PASS** (11,935 frames, 7,370 ops, 553 matmuls) |
| `vk-strict-check` | **PASS** (run 2 of ≤3; run 1 failed with the N2-documented `frag`-class flake — "unset and 0 stderr differ", pre-existing at the base, not a merge regression) |
| `deepseek-v4-tiny-check` | **PASS** |
| `deepseek-v4-tiny-check-dmoe` | **PASS** (`COLI_VK_DMOE=1` + `COLI_VK_DMOE_ROWS=1`, token-exact) |
| `tests/test_v4_serve_framing` | **PASS** (`v4 serve framing baseline: ok`) |
| `cu_tier.c -DCOLI_CUDA -fsyntax-only` | **PASS** |

## The F7 post-merge pin re-validation (vs the D11 baseline at 073a03b6)

**Form:** `--quick` (the short-prompt class — the smoke leg covers only leg C and cannot
carry the SECONDARY channel) — tiny gate + deploy + pinned passes, legs A cache-hit /
B CPU / C GPU, at the merged tip `6506a18c`, all Option-B levers off by construction
(`BASE_ENV` arms none of them). Wall **200.4 s**. VRAM idle floor verified before launch
(`vram0 = 541057024 B`, the standing 541 MiB floor); `gpu-inconclusive: 0` (the tier
booted); leg A **cache HIT** on both passes (banked sigs `c6bc848a93f3` /
`b4764177bde0` — the D11 fixtures, no re-record); leg-B canaries OK.

| channel | D11 baseline (short p0) | merged tip `6506a18c` | verdict |
|---|---|---|---|
| **PRIMARY greedy byte-identity** | 9/9 everywhere | **9/9** — deploy CPU+GPU, pinned CPU+GPU | **GREEN** |
| **SECONDARY CPU TF token-exact** | 18/18 both configs | **18/18** deploy, **18/18** pinned | **GREEN** |
| **GPU TF count-band** (thresholded) | deploy 17/18, pinned 17/18 (band ≥17/18) | **deploy 18/18, pinned 17/18** | **PASS, within envelope** |
| tiny gate | GREEN 3/3 | **GREEN 3/3** | **GREEN** |

The one GPU-TF flip: pinned p0 **pos 7, expected 51119 → got 2107, logit 27.192** — the
D11-documented near-tie/reassociation class (D11's own example: "pos 7 → 671 deploy /
2107 pinned"; identical `got`). Counts recorded: **deploy 0 flips, pinned 1 flip**.
Harness exit 1 comes solely from the pinned-GPU token-exact bar — the D11 §5 shape the
repo's own contract holds to the envelope, **not** a regression. No STOP condition fired
(greedy and CPU TF are exact everywhere).

Run artifacts: `.golden/run-20261024-151936/` (report.md, console.log; gitignored per
the fork's `.golden` rules).

## What was not done (out of this lane's brief)

- **The frag-mask strict-gate fix** (N2 follow-up; charter checklist item 1's last
  clause) — **not landed**: the lane brief for OB1 did not carry it, and N2's own ruling
  (masking `frag N.NN` in `vulkan_strict.sh`'s `norm()`) belongs to the gate's owner, not
  a merge lane. The flake fired once here (run 1 of 3) exactly as documented. Flagged to
  the owner with this report.
- No benchmarks, no `.spv` re-pin, no PR updates, no armed Option-B arm (this merge is
  the pre-S1 base; S1's first-divergence recording now has a revalidated baseline).

## Reproducing

```bash
cd /root/Projects/colibri-upstream && git fetch upstream          # 61646cbd
git diff --stat 7398a85f..upstream/dev                            # 67 commits, 81 files
cd /root/bench-worktrees/up2276-merge/c
make -f Makefile VK=1 ARCH=native vk-tier-check vk-chain-check
make -f Makefile VK=1 ARCH=native vk-strict-check                 # flake ≤3 runs
PATH=/root/bench-worktrees/port-baseline/.venv/bin:$PATH \
  make -f Makefile VK=1 ARCH=native deepseek-v4-tiny-check deepseek-v4-tiny-check-dmoe
make -f Makefile VK=1 ARCH=native tests/test_v4_serve_framing && ./tests/test_v4_serve_framing
gcc -O3 -march=native -fopenmp -pthread -Wall -Wextra -fsyntax-only -DCOLI_VULKAN -DCOLI_CUDA cu_tier.c
cd .. && VRAM_MAX_USED_MB=2600 ./scripts/vk_golden_parity.sh --quick \
    --upstream-ref=073a03b68452ecb6b1b3e9138838d72d5bf95817       # 200 s, the F7 control
# the base control (removed after the run):
git -C /root/Projects/colibri-upstream worktree add --detach /tmp/base-ob1 092d39ca
```
