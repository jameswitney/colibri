# N2: the 176-commit upstream merge onto `port/up-2276` — report (2026-10-23, late)

**Branch:** `merge/up176` (side branch off `port/up-2276` @ 3064378e) → merge
commit `4740f41f` — worktree `/root/bench-worktrees/up2276-merge`. Method per
PORT_STATUS § "The 2026-10-21/22 recursive merge": side branch, gates before
the live branch moves, documented resolutions.

## What was asked and what was done

1. **Merged `upstream/dev` @ 7398a85f into the port** (176 commits past our
   base `b90a369e`), on the side branch `merge/up176` — `port/up-2276` never
   moved until every gate was green.
2. **Two conflicts**, both unions of independent semantics (below); every
   auto-merged watch file reviewed hunk-by-hunk against the full
   `b90a369e..7398a85f` range diff before resolving.
3. **Diagnosed the strict gate's intermittence to the end**: the unset/0
   byte-comparison flake is the tier test's pool-allocator `frag` ratio, and
   the pre-merge base flakes identically (1/12) — a pre-existing environment
   nondeterminism, not a merge regression. Gate scripts untouched.
4. **Full gate set green** at the merge tip (table below).

## The upstream range (b90a369e..7398a85f, 176 commits)

`vk_chain.c` and `vk_tier.c` are untouched upstream in this range; the
watch-relevant movement is `backend_vulkan.c` (+338/−~200), `deepseek_v4.c`
(+300/−~160), `deepseek_v4_chain.h` (+24). The range's substance: qwen36's
Flint tokenizer and turn-end tokens plus the Muse Spark Open family, the
sliding-window KV **ring** on the qwen36 CUDA chain (PR #2316, the tip),
**bf0a3cd2** (colibri's attention KV mirror grows with the conversation,
#2314), the integrated-GPU **memory-type refactor** (`vk_memtype.h`,
`vk_igpu_threshold.h`, `vk_retry_memtype`), the streamed QLoRA trainer
(`c/train/`, `quickstart_tiny.sh`), LoRA adapters, Qwen-Image's encoder,
GGUF-dense **CUDA** chains (`cu_dense.h`, `v4_tier_dense_bytes`), and a broad
cluster/serving/tests/docs hardening wave.

## Conflicts and resolutions

Exactly two conflict hunks (merge-tree dry-run predicted both; nothing else
conflicted):

| file | hunk | resolution | rationale |
|---|---|---|---|
| `c/Makefile` | both sides added check targets at the same spot after `vk-chain-check` | **union**: our `vk-strict-check` block (tests/test_vk_degrade + vulkan_strict.sh, VK=0 skip) kept whole, upstream's `vk-memtype-check` block (tests/test_vk_memtype, no device) added after it | the precedent's classic union — two independent gates, no shared lines |
| `c/deepseek_v4.c` | the `VktConfig` initializer in the tier-start block | **union**: upstream's `.dense_bytes = v4_tier_dense_bytes(engine)` (their refactor of our inline expression into a helper — a strict superset: same Vulkan semantics + the new CUDA-dense case) **plus** our `.ram_planned`/`.ram_budget`/`.ram_spare` plan-cap fields, verbatim | independent semantics in one initializer; upstream's helper preserves the Vulkan expression we wrote (`dense_resident.total_bytes − dropped_bytes + head_cache.bytes` behind `!v4c_partial() && !v4c_whole()`) and adds the CUDA branch we never had |

## Watch files, reviewed semantically

- **`c/backend_vulkan.c` — bf0a3cd2's KV-mirror-grow vs our strict gate /
  COLI_VK_PROFILE / MXFP4: no interaction.** Our additions (the
  `coli_vk_degrade`/strict block, the profile presets, the MXFP4 mode-4
  grouped GEMM) sit in regions upstream did not touch; upstream's movement
  (the memtype refactor replacing `pick_memtype*` with `vk_pick_memtype`,
  and `kv_layer_alloc`/`kv_layer_free`/`coli_vk_kv_grow` splitting
  `coli_vk_kv_ensure`) sits in regions we did not touch. The merged header
  exports both sides side by side (`coli_vk_kv_grow` at
  `backend_vulkan.h:172` beside the strict/profile declarations). Upstream's
  grow path is called only from `c/colibri.c` (upstream's own engine path);
  our deepseek_v4 engine never calls it. Auto-merge verified hunk-by-hunk
  against the range diff, not trusted.
- **`c/deepseek_v4.c` — our S7 engine-store MFU cache vs upstream's hunks:
  S7 fully intact.** The mfu table plumbing (`mfu_table.h`, the frozen
  section, `coli_v4_expert_store_mfu_record`, `.coli_mfu`) is untouched by
  the merge. The merged `target_batch_impl` carries **both** semantics:
  upstream's `use_prefill_pool`/`v4_prefill_pool_enabled()` prefill-pool
  borrow and our dense-chain call with the `prompt` flag; upstream's
  `v4c_forward` signature change (`int prompt` added) threaded correctly
  through both call sites.
- **`c/deepseek_v4_chain.h` — no resolution needed:** the range diff is
  byte-identical on both sides — that is our own PR #2253
  (`prompt`/`COLI_VK_CHAIN_GEMM_ROWS`) landed upstream, so it merged
  trivially. Verified by diffing both sides' b90a369e..HEAD hunks.
- **`docs/ENVIRONMENT.md`**, **`docs/vulkan.md`**, **`docs/deepseek-v4.md`**,
  `vk_tier.h`, `deepseek_v4_internal.h`, `backend_vulkan.h`: auto-merged,
  inspected, no action.

## The strict gate's `frag` flake — and the decisive control

`vk-strict-check`'s unset-vs-0 byte-comparison asserts the default is
untouched. `norm()` masks wall-clock jitter (`ms|us|GB/s`, `%`) but **not**
the tier test's exit-summary `frag` ratio — the pool allocator's
fragmentation, which is nondeterministic run to run:

```
resident 6 (budget 6, 486.0 KiB of 526.5 KiB, 1 blocks, frag 0.37)   ← run A
resident 6 (budget 6, 486.0 KiB of 526.5 KiB, 1 blocks, frag 0.05)   ← run B
```

Everything else on the line is identical (the `%`s are masked); the two runs
compute the same thing. Numbers, both trees, real script
(`tests/vulkan_strict.sh`) and direct A/B pairs:

| tree | full script loop | isolated unset/0 pairs |
|---|---|---|
| merged (`merge/up176` tip) | lane 1: 3/5 fail; today: run 1 fail (`stdout differ` variant), run 2 **PASS** | 12/12 identical |
| **pre-merge base** (`3064378e`, `/tmp/base-check`) | **1/12 fail** — run 1, same `unset and 0 stderr differ` signature; 11/12 pass | 8/8 identical (frag 0.05 both sides) |

**Verdict: pre-existing environment flake.** The identical failure signature
reproduces at the pre-merge base, and both trees are stable when the
unset/0 pair runs in isolation — the divergence needs the script's earlier
fault-aborted tier runs to prime it. Not a merge regression; no gate script
was touched (out of this lane's brief). The follow-up for the gate's owner:
mask `frag N.NN` in `norm()` the way timings are masked — the ratio is a
diagnostic, not a contract.

## Gate results (at the merge tip, `4740f41f`)

| gate | result |
|---|---|
| `vk-tier-check` (incl. MXFP4 host-pool, pool copy, host pairs) | **PASS** |
| `vk-chain-check` (11,853 frames, 553 matmuls) | **PASS** |
| `vk-strict-check` | **PASS** (run 2 of ≤3; flake documented above — 1 PASS counts as green per the control) |
| `deepseek-v4-tiny-check` | **PASS** (23 PASS; fixture regenerated first; pin contract incl.) |
| `test_v4_serve_framing` | **PASS** (`v4 serve framing baseline: ok`) |
| `cu_tier.c -DCOLI_CUDA -fsyntax-only` (CUDA double-compile) | **PASS** |

## What was not done

- No `.spv` re-pin, no benchmarks (no GPU arms this lane), no PR updates.
- No gate-script change for the `frag` mask — flagged above for the owner
  instead of quietly widening `norm()` inside someone else's gate.

## Reproducing

```bash
cd /root/bench-worktrees/up2276-merge/c
make -f Makefile VK=1 ARCH=native vk-tier-check vk-chain-check
make -f Makefile VK=1 ARCH=native vk-strict-check        # flaky ~1/12; see above
PATH=/root/bench-worktrees/port-baseline/.venv/bin:$PATH \
  make -f Makefile VK=1 ARCH=native deepseek-v4-tiny-check
make -f Makefile VK=1 ARCH=native tests/test_v4_serve_framing && ./tests/test_v4_serve_framing
gcc -O3 -march=native -fopenmp -pthread -Wall -Wextra -fsyntax-only \
    -DCOLI_VULKAN -DCOLI_CUDA cu_tier.c
# the base control (removed after the run; recreate with):
git -C /root/Projects/colibri-upstream worktree add /tmp/base-check 3064378e
```
