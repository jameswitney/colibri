# AG — PW-C2: the V4 chain's flash-attention tile, ported from the fork's standing arm (2026-10-25)

**Lane:** PW-C2 (the flash-attention slice of the parity wave; AE = D's lane, AF = C1's
falsification, this = AG). **Tree:** `port/pw-c2` @ `0c847722` + this commit (branched from
`port/up-2276`'s head; the worktree `/root/bench-worktrees/pw-c2`, sole writer). **Rig:** this
box's RX 6900 XT (RADV NAVI21) — the same card the fork bench-selected its FA tile on
(`c/Makefile.deepseek-v4`'s `ATTN_FA_TILE` comment) — for the unit oracle and the gates; **no
model-scale legs were run** (the DPROF window owns those; §4).

**The candidate (the census' #2, shader-census §4):** the fork's `sparse_attn_fa` family —
never ported — against the port's `chain_dsv4.comp` mode 0, which runs one workgroup a
(head, row) with two scalar 512-length passes over fp32 KV and no LDS staging: a list read
≈ 2·H = 128× per attended row against the tile's heads/Br = 8×, ×2 the read width — the
census' "~32× the KV bytes". The attention DPROF bucket at the standing decode set is
**63.8 ms/tok** (V-g1), the whole-run attention device time **42.9 s / 516 dispatches**;
the fork's own FA measured ~10 ms/tok at decode. Expectation pre-registered by the wave:
−40…−55 ms/tok decode, ~0 s TTFT today (prefill attention hides under the 105.6 s staging
span, X §3) surfacing only post-Option-B.

## 1. The route: port the fork's shader (route ii), not a wiring of `chain_attn_flash` (route i)

The port already ships a flash kernel — `chain_attn_flash.comp` (VKC_P_ATTN_FLASH,
`COLI_VK_CHAIN_FLASH`) — but its contract cannot ride V4's attention shape. All four
mismatches are hard, in the shader and its host pick:

1. **Head dim.** `chain_attn_flash` specialises HD as a multiple of 64 **up to 256**
   (`fa_pipe`'s spec constants; `vkc_attn_w` refuses `hd > 256`). V4's latent head dim is
   **512** — `v4c_attention`'s `hd`, every row, both engines (`deepseek_v4_chain.h:1141`,
   `deepseek_v41_chain.h:925`).
2. **The row source.** `chain_attn_flash` streams a **contiguous causal K cache**
   (`K[k_off + (kvh*cap + t)*hd + d]`, `key <= qpos` inline). V4's attention is a
   per-token **selection list** over two stores — window-ring slots and compressed-pool
   rows, entries possibly dead — resolved by the DSA indexer's top-k. There is no list,
   no second store, no dead entry in the dense kernel's vocabulary.
3. **The sink.** V4 folds a per-head sink into the denominator (`prm[sink_off + h]`);
   `chain_attn_flash`'s push constants carry sink fields only to zero them ("the fields
   after v_off are zero here").
4. **The shape.** GQA-folded, per-kv-head dispatch (`grid.y = KVH`, GQ | 16) over one
   head-major cache; V4 is MQA over window+pool — the fork's tile already encodes exactly
   this (`dispatch (tokens, heads/Br)`, K ≡ V one latent row).

Its numerics class is also the wrong one to inherit: f16 **operands** on the matrix units
("Not bit-identical to chain_attn.comp (f16 operands)"), against the fork tile's fp32
arithmetic with bf16 rounds exactly where the CPU reference makes them.

The fork's `sparse_attn_fa.comp` (@ `d11fba5b`) ports cleanly because it was written for
this op: llama.cpp's `flash_attn.comp` tile decomposition (online softmax, per-row M/L
registers, D_split subgroup-shuffle reduction, shmem final reduction, the SINK_ENABLE end
block) over **the fork's own V4 row resolution** — window ring, compressed pool, per-token
selection, sinks, and the bf16 probability/output rounds. The port's mode-0 contract is a
strictly simpler front-end over the same rows (the list resolves ring slot / pool row /
dead instead of the fork's meta/chunk/sel tables), in the same six bindings and the same
push-constant block — so the adaptation is `kv_load`, the Q/out addressing, and a
`flags & 1` runtime gate for the bf16 rounds. The tile geometry (256 threads, row_split 2,
D_split 16, Bc 16, LDS-staged K/V, Br 8 prefill / Br 2 decode twin at tokens==1, the fork's
four builds) carries over **verbatim**, including the fork's 2026-10-02 decode-tile fix
lesson baked into the host pick (`DS4VK_ATTN_FA_BR` = the true build's Br — the mismatch
once dispatched 7/8 dead workgroups).

## 2. What shipped

- **`c/shaders/chain_dsv4_fa.comp`** — the tile on mode 0's contract: same bindings
  (q, ring, pool, list, params, out) and the same `int v[32]` push constants at mode 0's
  slots, so `vkc_dsv4_attn` dispatches either kernel from one call. Four builds from the
  one source (the fork's four): `chain_dsv4_fa{,_f16,_dec,_dec_f16}.spv`, Br 8 / Br 2 ×
  fp32 / KV_F16.
- **`c/shaders/chain_dsv4_fa_gather.comp`** — the f16 mirror's builder. The fork stored
  its ring and pool as fp16 (`COLI_DSV4_VK_KV_F16`, **retired ON** in its standing arm —
  `backend_vulkan.c:4747`: "Default on (fp16); set =0 to use fp32", storage-only, "fp16's
  11-bit significand holds any bf16 (8-bit) or e4m3 (4-bit) value exactly in the normal
  range"). This port's ring and pool are written by device copies the fork's writers
  replaced (`vkc_copy_regions`, the compressor's own output), so converting the storage
  would touch every reader — `chain_kvs.comp` mode 4 (the split path), the host pulls, the
  lowering writes — a misread-prone surface for a byte-width change. Instead the f16 form
  is a **read-side mirror**: one dispatch an attention converts every ring and pool row to
  f16 (round to nearest even — the fork's storage conversion) into a grown scratch the
  KV_F16 builds read by entry index. The FA reads only rows that pass wrote, so nothing is
  permanent and no writer changes at all; the numerics class is the fork's own.
- **`c/vk_chain.c`** — the lazy pipeline family (`fa4_pipe`, loaded only when the lever is
  armed), the lever, the mirror scratch (`scratch_grow`, the `adec_scratch` pattern
  refactored to a second user), and the arm inside `vkc_dsv4_attn`:
  `COLI_VK_CHAIN_ATTN_FA` (read per call, so a test arms it case by case) — **unset/0 =
  mode 0, byte-identical by construction** (the unarmed path does not even load the FA
  modules); **1** = the tile + the f16 mirror (the fork's standing class); **2** = the tile
  over fp32 rows (the fork's `KV_F16=0` A/B arm). A shape the tile cannot take (hd ≠ 512,
  heads % 8, or a q/o/w/c offset or stride not a multiple of 4 floats) or a missing
  pipeline falls back to mode 0 — never a misread (the fork's own refuse rule; the split
  path `vkc_kvs_ds` is untouched, so spilling layers keep today's kernel). Arm 1's mirror
  failing (no scratch room, a missing gather pipeline, a failed gather record) degrades
  one rung only — the tile over the fp32 rows — mode 0 still just the tile's own refusals.
  `VkcStats.attn_fa`
  counts engagements.
- **`c/Makefile`** — the five `.spv` rules (the tile builds MUST carry the `-D` set; the
  fork's own comment warns a plain build silently bakes the `#ifndef` defaults and the
  host then dispatches dead workgroups) + the `VK_SPV` entries.
- **`c/tests/test_vk_chain.c`** — the unit oracle (§3).

## 3. The unit oracle (test_vk_chain's `test_ds_attn_fa`, against the scalar reference)

The mode-0 class's own reference (`coli_sparse_attend_scalar` / the V4 bf16 loop), at the
shapes the tile takes — the model's decode list shape (S 1, H 8, window 128, pool 64,
cnt 640: window rows, DSA-selected pool rows, dead entries), the prefill tile (S 3, H 16,
cnt 300, dead entries and both row kinds), the V4.1 no-rounds class (flags 0), and the
fp32 arm — each run twice and checked **bit-stable**:

| case | arm | rel err | bar |
|---|---|---:|---:|
| S 1 H 8 cnt 640 flags 1 | 1 (f16 mirror, decode tile) | **4.06e-3** | 8e-3 |
| S 1 H 8 cnt 640 flags 0 | 1 | **2.28e-4** | 2e-3 |
| S 3 H 16 cnt 300 flags 1 | 1 (prefill tile) | **3.97e-3** | 8e-3 |
| S 2 H 8 cnt 20 flags 1 | 2 (fp32) | **6.53e-3** | 8e-3 |

Engagement: `attn_fa` moved by exactly 8 (4 cases × the stability double dispatch); a
shape the tile refuses (hd 64) passed through mode 0 **under the armed lever**; the empty
row (all entries dead) is exactly zero; the full suite PASS (12,039 frames).

**Numerics verdict, pre-registered per the D11 contract:** the armed path is a
**thresholded class, not token-exact, wherever it engages** — the score dot is a fp32
subgroup tree, the online softmax rescales partial sums in tile order, and the tile max
carries llama's `FATTN_KQ_MAX_OFFSET` (+3·ln2), a global shift that cancels in the
normalization but moves the bf16 probability rounding's scale. This is the fork's own
shipped class (its gate: 2e-3 vs its CPU reference, `tests/test_dsv4_sparse_attn_vk`); our
measured envelope is the table above against the mode-0 house bars (8e-3 flags-1, the same
bar the scalar-path test holds mode 0 to; the small-list fp32 corner is the worst at
6.5e-3, where each rounded probability carries 1/20 of a row's mass). **The f16 mirror adds
nothing measurable** — 4.06e-3 (f16) vs 6.53e-3 (fp32, smaller list): the mirror's
round-to-nearest f16 of even *unrounded* random rows sits under the class noise, and the
engine's real rows are bf16/e4m3/e2m1-rounded before the store (`v4c_attention`'s
`VKC_DS_E4M3` ring round; `v4c_compress`'s output rounds), the class fp16 holds exactly in
its normal range. **Token-exactness at tiny holds vacuously:** the tiny fixture is
`head_dim 32` (`tools/make_deepseek_v4_tiny.py`), the tile's compile-time gate is 512, so
the armed lever is shape-inert there — proven by the three tiny legs below. At model scale
(hd 512, where it engages) any text comparison is the D11 count-band, as it was for the
fork's standing arm.

## 4. Unit-scale engagement (the model-scale DPROF bucket is the window's read)

Throwaway timing harness (the PW-fix1 lane landed it as `c/tests/bench_chain_attn_fa.c` + its
make rule — §8 re-ran the numbers through the in-tree copy), the decode geometry S 1 / H 64 / hd 512 /
window 128 / pool 640 / cnt 768, 200 dispatches, this box's RX 6900 XT:

| arm | µs/dispatch | × |
|---|---:|---:|
| mode 0 (today) | 1,920 | — |
| FA + f16 mirror (arm 1) | **228** | **8.4×** |
| FA fp32 (arm 2) | 239 | 8.0× |

×43 layers ≈ **9.8 ms/tok** — the fork's own ~10 ms/tok decode figure, inside the
−40…−55 expectation off the 63.8 bucket. Prefill shape S 256 (same rows): mode 0
**304 ms** → FA+f16 **6.0 ms** a layer-dispatch (**51×**; the fp32 arm 6.3 ms — at this
size the op sits at the KV-byte floor, and the f16 halves it): the 42.9 s whole-run
attention device time collapses to the ~1–2 s class, hidden under staging today, free
after Option-B. The FA records under `PK_ATTN`, so the DPROF attention bucket is the
counter the window reads; `attn_fa` in `vkc_stats` is the engagement line.

## 5. Gates

- `vk-chain-check` — **PASS** (12,039 frames; the four FA oracle cases + engagement +
  fallback inside).
- `vk-tier-check VK=1` — **PASS** (both invocations).
- `vk-strict-check` — **PASS ×2**. One earlier run failed its "unset and 0 stderr differ"
  byte-compare on tier-stat jitter in fields the script's `norm` does not mask
  (`CPU share … ms` is masked; resident/upload/eviction counts and `frag 0.05` are not);
  the base tree (`up2276-merge` @ the lane's head) passes the same gate, and two
  consecutive post-change runs pass — a pre-existing flaky comparison, not this change
  (the unarmed path is the unmodified code).
- `deepseek-v4-tiny-check` (fixture weights borrowed from `up2276-merge`'s banked copy —
  config/ref/tokenizer diff-equal; this box has no PyTorch to regenerate): CPU **PASS**,
  `COLI_VULKAN=1` **PASS**, `COLI_VULKAN=1 COLI_VK_CHAIN_ATTN_FA=1` **PASS** — token-exact
  everywhere, the armed lever inert at hd 32 (§3).
- `test_v4_serve_framing` — **ok**.
- `cu_tier.c -DCOLI_CUDA -fsyntax-only` — clean.

## 6. Residual risks

- **The f16 envelope at range edges** (pre-registered §3): a stored row value outside
  fp16's normal range (|x| > 65504, or deep subnormals) diverges inside the thresholded
  class. The engine's rounds bound the rows in practice and the fork shipped the same
  class as its default; the unit oracle feeds unrounded values and still holds 4e-3.
- **The split path is not FA'd**: layers under the KV split (`vkc_kvs_ds`, mode 4) keep
  today's kernel; at the campaign's shapes the split is off (the census attributes the
  63.8 bucket to mode 0), and the fork's own refuse grammar says that is the safe side.
- **Model-scale legs not run here** — the DPROF window owns the bucket read; the unit
  timings (§4) are the expectation, not the measurement.
- The `VK_SPV` build dependency: a deployment without glslc keeps the committed `.spv`
  (the rules' fallback), as every other optional shader does.

## 7. Anchors

Fork: `c/shaders/sparse_attn_fa.comp` + `c/Makefile.deepseek-v4:1073-1100` (the four
builds and the tile table), `c/backend_vulkan.c:4747` (KV_F16 retired ON), `:5236-5336`
(the pick, the Br mismatch fix, the f16 refuse rule). Port: `c/shaders/chain_dsv4_fa.comp`,
`c/shaders/chain_dsv4_fa_gather.comp`, `c/vk_chain.c` (`dsv4_fa_*`, `vkc_dsv4_attn`),
`c/vk_chain.h` (`VkcStats.attn_fa`), `c/Makefile` (`DSV4_FA_TILE`), `c/tests/test_vk_chain.c`
(`test_ds_attn_fa`). Campaign: `audits/shader-census.md` §2 row 6 / §3 lead 4 / §4 rank 2
(read at `/root/colibri-upstream-port/audits/`), `docs/research/P-optionB-dossier-2026-10-22.md`
§5 L6, V-g1 (the 63.8 bucket), X (the prefill hiding).

## 8. Addendum (PW-fix1 lane, 2026-10-25): §4 made repo-reproducible

§4's harness is in the tree now — `c/tests/bench_chain_attn_fa.c` (build on demand:
`make tests/bench_chain_attn_fa VK=1`, run from `c/`) — same methodology (§4: one arm
per lever, a one-dispatch warm-up frame that also grows arm 1's mirror scratch, then the
best of 3 frames of N recorded `vkc_dsv4_attn` dispatches timed at the submit; the
`attn_fa` engagement counter checked per arm), the review's P2 "the 8.4×/51× are not
repo-reproducible" closed.

One rig fact the throwaway had skirted: the chunk arm records mode-0 dispatches of
~0.3 s, and the first S 256 run (10 a frame, ~3 s one submission) hit this box's amdgpu
hard recovery — the exact K1/P1 boundary class `COLI_VK_DMOE_ROWS_MAX` documents. The
in-tree default keeps a frame of the chunk arms at 3 dispatches (~0.9 s of GPU work,
comfortably under the ~2–4 s boundary; `COLI_VK_BENCH_N` overrides, the boundary is a
rig fact, not a number to tune to).

Re-measured through the in-tree copy (same box, RX 6900 XT):

| case | arm | this doc (§4) | re-measured | Δ |
|---|---|---|---|---|
| S 1 H 64 cnt 768 | mode 0 | 1,920 µs | 1,811 µs | −5.7% |
| S 1 H 64 cnt 768 | FA + f16 | 228 µs, 8.4× | 191 µs, 9.5× | −16% / +13% on the ratio |
| S 1 H 64 cnt 768 | FA fp32 | 239 µs, 8.0× | 199 µs, 9.1× | −17% |
| S 256 chunk | mode 0 | 304 ms | 305.4 ms | +0.4% |
| S 256 chunk | FA + f16 | 6.0 ms, 51× | 6.17 ms, 49.5× | +2.8% |
| S 256 chunk | FA fp32 | 6.3 ms | 6.57 ms, 46.5× | +4.3% |

Everything inside the ±20% band the review asked to flag loudly about — nothing to
flag. The decode rows are a little faster than §4's (same direction, both arms, so the
ratios drift up ~13%, not down): §4's throwaway and this re-run are different sessions
on the same box, and a best-of-3 over 200 ~2 ms dispatches carries run-to-run scatter of
exactly this size (the chunk row's per-dispatch work dominates and it reproduces §4
almost exactly, which is the same story).
