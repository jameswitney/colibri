# AL — PW-C3: the S=1 single-dispatch mHC pair, ported from the fork (2026-10-25)

**Lane:** PW-C3 (the mHC fusion slice of the parity wave; AF = C1's falsification, AG = C2's
flash tile, **this = AL** — the wave's research letters coordinated D-fix = AJ, A2 = AK, both
in flight as this is written). **Tree:** `port/pw-c3` @ `d30df627` + this commit (branched
from `port/up-2276`'s head; worktree `/root/bench-worktrees/pw-c3`, sole writer). **Rig:** this
box's RX 6900 XT (RADV NAVI21) for the unit oracle and the gates; the model-scale smoke ran on
the same card, gate-class only — **no bench arms** (the manager's windows own the verdicts).

**The candidate (shader-census §2 row 9 / §4 rank 4):** the fork's *single-dispatch* decode
mHC pair — `mhc_dec_pre.comp` / `mhc_dec_post.comp` — against the port's per-op chain, the
census' "port-slower (fusion), UNTESTED, est. −20…−30 ms/tok" against the measured **mHC
36.1 ms/tok** decode bucket (V-g1). Dossier P §5 L5 had already narrowed it: the port records
`vkc_mhc(SPLIT/COLLAPSE/POST)` *in-frame* for any row count, so the fork's +19 % host→device
class does not apply; what remains is the S=1 consolidation, pre-registered "~0 to +2 %, MED
that it is a wash — the cheapest thing to falsify". This lane implements it behind
`COLI_VK_CHAIN_MHC_S1` (default off) and measures what there is to measure at gate class.

## 0. The premise check (the C1 discipline)

The port's S=1 mHC path is **not** already single-dispatch — the premise holds. At one row,
`v4c_pre` (`deepseek_v4_chain.h:1096`) records **six** dispatches — `vkc_matmul(fn)` (fmt 10
f32, the "GEMV other" bucket), `chain_mhc` SPLIT (one workgroup: the RMS-inverse and the
Sinkhorn), `chain_mhc` COLLAPSE, a `chain_dsv4` mode-7 bf16 round, `chain_norm`, another
round — and `v4c_post` records **two** (mode-2 POST, then its round): eight a site, sixteen
a layer at decode (×2 sites ×2 halves). The bucket arithmetic checks out exactly: the
V-g1-class whole run (`dprof-a-r1.log:41`) counts **mhc 2472.7 ms (17286)** = 63 decode
forwards × 43 layers × 6 + the prompt's 4 chunk-visits × 258, with the rounds under
"element-wise" and the norms under "norm" — the 36.1 ms/tok decode figure is the mhc bucket's
decode share (≈2325 ms / 63). The fork's counterpart record: its 3-dispatch prefill chain
wired at tokens=1 measured **0.315 → 1.161 ms/call REGRESSION** standalone
(`decode-gpu-full-residency-review-2026-10-02.md:28`, `COLI_VK_MHC_DECODE`, default off) —
the port's 8-dispatch form is the same class, only more so.

## 1. What the fork actually claims for the pair (the survey's citations)

- **The pre** (`COLI_VK_MHC_DECFUSE`, `ENVIRONMENT.md:410`): the decode pre as *two*
  dispatches in one submit — `[fn GEMV, full grid] → mhc_dec_pre.spv` (ONE 256-thread
  workgroup: RMS-inverse + Sinkhorn + collapse + branch RMSNorm; bodies verbatim ports of
  `mhc_sinkhorn.comp`'s 16-lane exchange order replayed serially on lane 0 +
  `mhc_rmsnorm.comp`'s fold bodies). **Measured: the mhc op tick a WASH** (0.317–0.321 vs the
  host loop's 0.306–0.311 ms/call) — but decode **1.385–1.414 vs 1.169–1.183 tok/s (+19 %,
  3×/3× replicated, the default-config run 1.400)**, the win sitting "in the untimed
  serialized host path (mechanism not yet localized)". Parity: the same gates as the prefill
  batch suite (post/comb 1e-3, normalized/out 1e-2); measured max-rel-diffs post 1.6e-6 /
  comb exact / normalized 1.65e-3 / out 1.05e-3. Refusal (M≠4, H>4096, pipeline absent)
  falls back bitwise.
- **The post** (`COLI_VK_MHC_DECFUSE_POST`, `:399`): ONE dispatch, thread-per-output over
  M·H = 16 K outputs, **bitwise vs the deployed host loop's codegen** (comb terms separately
  rounded, the post term one fused `vfmadd`, replicated with `precise` + GLSL `fma()`).
  Measured: the op tick a wash (0.26 ms both arms), end-to-end within noise, greedy text
  byte-identical.
- **The port's reading** (dossier L5, verbatim): the +19 % was "host-loop → device-fuse, a
  step the port never takes" — the port's chain is already in-frame, so the remaining value
  is the dispatch count itself: 8 → 3 a site. The fork's third record — the multi-dispatch
  chain at one row regressing — is the direct evidence the count is what matters at S=1.

## 2. What shipped

- **`c/shaders/chain_mhc_dec.comp`** — the pair on `chain_mhc`'s own contract. Mode 0 (the
  pre, ONE workgroup) and mode 1 (the post, one thread an output) behind a mode word, the
  fork's bodies verbatim (the fma affines, the serial Sinkhorn replay, the LDS-staged
  collapse, the `precise` two-rounding accumulation, `bf16r`, `recip_special`) generalised
  from the fork's hardwired M=4/H≤4096 to **H ≤ 8 streams (chain_mhc's own cap) and D ≤ 4096
  hidden** (the fork's own LDS cap, refused host-side beyond). Bindings are chain_mhc's five
  (x streams, m the mixes / the branch, hp, prm, y) with the port's float offsets; `hp`
  keeps **chain_mhc's `[pre H][post H][comb H*H]` layout** (the fork's state layout was
  `[post][comb][pre]`), so a fused pre's state stays consumable by a standing POST and the
  pair composes with either chain order — the refusal grammar never mixes layouts.
- **`c/vk_chain.c`** — the lazy pipeline (`mhcd_pipe`, loaded only when the lever is armed —
  unset/0 never even loads the module), the lever `COLI_VK_CHAIN_MHC_S1` read per call (a
  test arms it case by case), `vkc_mhc_dec(mode, x, m, hp, prm, y, p)` with every refusal
  (streams > 8, D > 4096, a negative offset, a missing pipeline, the lever unset) returning
  0 **before** any state is touched, `VkcStats.mhc_dec` counting engagements, the dispatches
  recording under **PK_MHC** so the DPROF mHC bucket keeps counting the engaged path, and
  the shutdown hook beside `dsv4_fa_shutdown`'s.
- **`c/deepseek_v4_chain.h`** — the seam: `v4c_pre` records the fn matmul, then tries
  `vkc_mhc_dec(0, …)` at `n == 1` (into `ch->nrm`, the bf16 rounds folded — the standing
  chain's `ch->col` scratch untouched) and falls back to the standing six on refusal;
  `v4c_post` tries mode 1 (into `ch->xn`, the round folded) and falls back to mode 2 + the
  round. Both call sites (the chunk order and the layer-outer S3 order) share them; V4.1's
  own `v41c_pre/post` (a different algorithm — the collapse reads the *previous* site's pre,
  no inter-op rounds) is untouched, as is GLM-5.3's chain_mhc use. **Default off =
  byte-identical by construction**: with the lever unset the seam calls a function that
  returns 0 before touching anything, and the standing sequence records exactly as before.
- **`c/Makefile`** — `chain_mhc_dec.spv` in `VK_SPV` with the committed-`.spv` fallback rule
  (the flash tile's pattern; a deployment without glslc keeps the committed blob).
- **`c/tests/test_vk_chain.c`** — `test_mhc_dec` (§3).

## 3. The unit oracle (vs the standing 3-dispatch path at S=1)

The standing chain recorded exactly as `v4c_pre`/`v4c_post` record it at one row (matmul,
SPLIT, COLLAPSE, round, norm, round, POST, round), the fused pair beside it off the same
buffers; the hp layout additionally guarded against the CPU's `coli_hc_split_sinkhorn` over
the device's own mixes (the isolation trick from `test_mhc`). Bit-stability double-run and
the engagement counter checked per case; refusals (D past the cap armed, a good shape with
the lever unset) verified to record nothing.

| case (H streams, D, iters) | hp vs standing | hp vs CPU | nrm (bf16) | post out (bf16) |
|---|---:|---:|---|---|
| **4, 4096, 20 — the model's geometry** | **5.8e-11** | 6.0e-7 | **bit-identical** (4096/4096) | **bit-identical** (16384/16384) |
| 2, 128, 3 — the tiny's geometry | 0.0 (exact) | 6.0e-8 | bit-identical | bit-identical |
| 8, 2048, 1 — the widest streams | 1.5e-8 | 4.2e-7 | bit-identical | 5.3e-6 rel, **1 bf16 flip in 16384** |

Reading: the divergence vs the standing chain is confined to the *unrounded* state (the
single-rounding fma class, ~1e-11…1e-8), and the bf16-rounded outputs the engine consumes
came out **bit-identical at the model's geometry** — the fork's fused bodies and the port's
standing shaders sit inside the same bf16 envelope everywhere but the knife edge (one value
in 16 K at H=8 sat on a boundary). This is the D11 thresholded class registered at its
weakest: the envelope is the bf16 round, and the measured flip rate is ~0 at the model's
shape.

## 4. The greedy channel

- **Tiny oracle** (fixture `hc_mult` 2, hidden 128, 3 Sinkhorn rounds — the lever *engages*
  there, unlike C2's shape-inert hd gate): all three harnesses — `test_deepseek_v4_tiny`,
  `_prefix`, `_brio` — **PASS token-exact with `COLI_VK_CHAIN_MHC_S1=1`**, as they do at CPU
  and plain `COLI_VULKAN=1`. Engagement proven by exact dispatch arithmetic at the tiny
  (8-token leg, `COLI_VK_CHAIN_PROF=1`): **mhc 144 → 102, norm 125 → 83, element-wise
  637 → 511 (= −3 rounds/pair), GEMV other 301 → 301** — 42 engaged site-pairs × (−1, −1,
  −3), the fn matmuls unchanged.
- **Model scale**: the smoke's two arms (§5) generate **coherent, on-topic text both ways**
  and diverge in wording from the first sentences — the D11 count-band class, the fork's own
  precedent for its fused decode pre ("text differs from the host arm, config-class"). The
  clean lever-on arm's tier state is the same class as the lever-off arm (hit-rate 28.4 vs
  26.0 %), so the divergence here is the mHC numerics class, not a residency change.

**Verdict (D11 registration): the armed path is a thresholded class, not token-exact, at
model scale; at the tiny it is token-exact in fact, and at the unit scale its bf16 outputs
are bit-identical to the standing chain at the model's geometry.**

## 5. Gates and the model-scale smoke

- `vk-chain-check` — **PASS** (12,114 frames; the three `test_mhc_dec` cases + engagement +
  refusals inside).
- `vk-tier-check VK=1` — **PASS** (both invocations) — *after this lane re-armed
  `test_vk_tier`'s `packed_scales` around `COLI_VK_TIER_FMT15`*: the W1 hotfix (`d73b82e1`)
  made fmt 15 opt-in and left the test expecting the packed bytes by default, which had the
  gate **red at the branch point** — proven on a clean `git archive d30df627` tree (same two
  `packed scales` FAILs), and the whole suite passes with the lever armed. PW-D's debt, paid
  here because the standard gate set must run; two lines, test-only.
- `vk-strict-check` — **PASS ×2** (was red at the branch point through the same tier case;
  the base-tree proof above).
- `deepseek-v4-tiny-check` legs (fixture weights borrowed from the merge worktree's banked
  copy — this box has no PyTorch; config/ref/tokenizer diff-equal): CPU **PASS ×3**,
  `COLI_VULKAN=1` **PASS ×3**, `+ COLI_VK_CHAIN_MHC_S1=1` **PASS ×3**.
- **Model-scale smoke** (the runner's standing set, `COLI_VK_MM8=1 TIER_HOST_GB=8
  TIER_PROMOTE=32`, `COLI_VK_CHAIN_PROF=1`, 2,515-tok prompt / 64 tokens, exclusive rig,
  settle discipline; logs `/root/bench-colibri/up2276/pw-c3-mhc-smoke-{off,on2}.log`):
  - **off**: rc=0, chunks 768 rows, TTFT 349.453 s, decode 0.5605 tok/s, coherent.
  - **on**: rc=0, **the same 768-row shape**, TTFT 364.752 s, decode 0.5509 tok/s,
    coherent. **Engagement exact at model scale**: mhc 17286 → **11868** (−5418), norm
    15345 → 9927 (−5418), element-wise 79482 → 63228 (**−16254 = 3 × 5418**), GEMV
    other/dsa/mm8 **+0** — 5418 = 63 one-row forwards × 43 layers × 2 sites exactly, every
    engaged site 8 → 3 dispatches. The three buckets' whole-run device time 3931 → 3508 ms
    (**−422 ms ≈ −6.7 ms/tok device** on the mHC-adjacent buckets) — the in-frame
    consolidation's own scale, against the census' −20…−30 which priced the fork's
    host-loop class the port never had. The single-leg decode rates (0.5509 vs 0.5605) are
    inside this shape's run-to-run scatter: the dossier's "wash" prior, not contradicted —
    and not a bench verdict (one leg each, gate class).
  - A first `on` arm (`pw-c3-mhc-smoke-on.log`) is **kept as evidence of a confound, not
    read**: it booted beside a sibling lane's VRAM holder (the fit saw 0.07 GiB free → 35-row
    chunks → a different tier/streaming shape entirely, hit-rate 6.7 %), and my wrapper's
    timeout orphaned it past the runner's rc line. Its one clean fact: the engine exited
    through its full close path with coherent text. The rig's co-tenancy discipline is why
    `on2` exists.

## 6. Residual risks

- **The knife-edge class**: a bf16 boundary value in the normed row or the post output flips
  one rounding (measured once in 16 K values, at H=8). The D11 count-band covers it at model
  scale; the fork shipped the same class as its default.
- **D > 4096 hidden refuses** (the fork's own LDS cap): a DSV4 variant wider than Flash
  keeps the standing chain — a decline, never a misread. V4.1's mHC (a different collapse
  algorithm) is out of scope by construction.
- **The chunk-shape hazard the smoke tripped** (a sibling lane's VRAM at boot silently
  re-shapes a run through the rows fit) is a rig fact this lane paid for once; recorded for
  whoever owns the runner.
- No bench arms: the −6.7 ms/tok device figure is the smoke's bucket arithmetic, not a
  verdict; the wave's windows own the A/B.

## 7. Anchors

Fork: `c/shaders/mhc_dec_{pre,post}.comp`, `docs/ENVIRONMENT.md:399,410`
(`COLI_VK_MHC_DECFUSE{,_POST}` — the pair's own measured record),
`docs/decode-gpu-full-residency-review-2026-10-02.md:28,99` (the 3-dispatch regression and
the single-dispatch prescription), `c/backend_vulkan.c:3125-3152,7475-7560`. Port:
`c/shaders/chain_mhc_dec.comp`, `c/vk_chain.c` (`g_mhcd`, `vkc_mhc_dec`),
`c/vk_chain.h` (`VkcMhcDec`, `VkcStats.mhc_dec`), `c/deepseek_v4_chain.h:1096-1121`
(`v4c_pre`/`v4c_post`), `c/Makefile` (`chain_mhc_dec.spv`), `c/tests/test_vk_chain.c`
(`test_mhc_dec`), `c/tests/test_vk_tier.c` (`packed_scales` re-arm). Campaign:
`docs/research/AD-audit-series-2026-10-25/shader-census.md` §2 row 9 / §3 lead 5 / §4 rank 4,
`P-optionB-dossier-2026-10-22.md` §5 L5 + §6 row 2, V-g1 (the 36.1 bucket),
`AI-pw-w1-2026-10-25.md` (the fmt-15 hotfix the tier-test re-arm belongs to).
