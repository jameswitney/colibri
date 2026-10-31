# G — P1.5: opt-in strict capability gate (`COLI_VK_STRICT`)

Target `/root/Projects/colibri-upstream` (`upstream/dev` @ `a0037a3a`; tip `422c0fe5` = docs only).
Reference `/root/Projects/colibri-ds4-vulkan` @ `d11fba5b`: `coli_vk_capability()` `backend_vulkan.c:2353–2400`,
boot line `:17138`, `docs/ENVIRONMENT.md:195`. D5: silent degradation stays the default; strict is opt-in.

## 0. Design principle

The fork gates **every** optional-kernel site, aborting on ordinary hardware capability — fatal-everything,
not the goal. Upstream's defect is narrower:

> **A site is a degradation only when every precondition it depends on has already been verified.**

The gate is called **after** the capability probe, never at it: `has_coop`, shared-memory size, clustered
subgroups, fp64, `VK_EXT_*`, shape/format support and budget arithmetic are *refusals*. That rule keeps
strict safe on Lavapipe, small-shared-memory GPUs and f32 checkpoints, and the diff small.

## 1. Sites → class → action

**(a)** legitimate refusal (shape/format/capability/operator config): allowed under strict, at most a
one-shot `[VK] refused:` line. **(b)** degradation hiding a bug: aborts under strict, naming the op.
**(c)** expected fallback (budget/policy/environment): counted, never fatal. `SILENT` = nothing printed today.

### 1.1 Bring-up — `c/backend_vulkan.c`

| # | line | today | class | action |
|---|---|---|---|---|
| 1 | 81 | no loader | c | count |
| 2 | 90 | loader lacks 1.2 fn | c | count |
| 3 | 103 | `VKCHECK: %s failed` (95) | b/c | b = pipeline/descriptor/fence/cmdpool after probes; c = instance/device/queue |
| 4–8 | 1030,1063,1349,1377,1390,1395 | no device / queue / host memory / staged uploads / ReBAR | c | count |
| 9 | 1403 | core `.spv` unopenable/bad | **b** | gate `core shader` |
| 10 | 1406 | core pipeline fails | **b** | gate `core pipeline` |
| 11 | 1415 | `_gemm.spv` absent | **b** | gate `qmatmul_gemm.spv` |
| 12,15 | 1420,1437 | `*_TILE rejected` | a | refuse-line |
| 13 | 1426 | gemm present, no slot | **b** | gate |
| 14 | 1432 | `_coop.spv` absent (probe passed) | **b** | gate |
| 16 | 1444–48 | coop present, no pipe | **b** | gate |
| 17 | 1466 | `_gate_up.spv` absent | **b** | gate |
| 18 | 1467 | gate_up pipe fails | **b** | gate |
| 19 | 1474 | `rmsnorm.spv` absent | **b** | gate |
| 20 | 1477 | nrm pipe fails | **b** | gate |
| 21 | 1490 | `attention_absorb.spv` absent | **b** | gate |
| 22 | 1491 | att pipe fails | **b** | gate |
| 23 | 2643 | `no usable Vulkan device (shaders %s), running on the CPU` | **b** | aggregate the boot test keys on |
| 24–25 | 2914–3031 / 3017 | `dev2:` no GPU-queue-mem (c) / `gate_up shader required` (**b**) | b,c | opt-in `COLI_VK_DEV2` / gate |

### 1.2 Runtime — `c/backend_vulkan.c`

| # | line | today | class | action |
|---|---|---|---|---|
| 26 | 2377 | `fence wait failed — disabling offload` | **b** | gate `matmul fence` |
| 27 | 2688 | **SILENT** `G.ready=0` | **b** | gate |
| 28 | 2811 | eg fence failed | **b** | gate |
| 29 | 2891 | upload lost | **b** | gate |
| 30 | 3267 | dev2 eg fence failed | **b** | gate |
| 31 | 3326 | **SILENT** fence (prefetch) | **b** | gate |
| 32 | 3468,3528,3636,3711 | **SILENT** KV-mirror fences | **b** | gate `kv mirror fence` |
| 33–36 | 4869,4949,5128,5250 | batch submit/fence/sum failed, tier stops | **b** | gate |
| 37 | 4109 | scratch alloc failed | c | budget-derived (**UNKNOWN**) |
| 38 | **5636** | `coli_vk_mark_lost()` — **SILENT** | **b** | **gate here** |
| 39 | **5658** | `coli_vk_mark_lost_dev()` — **SILENT** | **b** | **gate here** |
| 40 | 1730 | upload failed (lost) | **b** | gate |


38/39 are the highest-value seam: every engine's `*_chain.h` wrapper funnels loss through them
(`qwen36_chain.h:1014`, `qwen38_chain.h:1303`, `glm_chain.h:705`, `kimi_k3_chain.h:953`, `mimo_chain.h:624`,
`deepseek_v4_chain.h:1285`, `glm53_chain.h:811` — 11 sites, 10 files). Two lines cover all.

### 1.3 Chain — `c/vk_chain.c`, `c/vk_kvsplit.h`

| # | line | today | class | action |
|---|---|---|---|---|
| 41 | 187 | `chain: %s failed — lost` (`lose()`) | **b** | gate; single choke point |
| 42 | 365 | shader cannot load | **b** | gate |
| 43 | 473 | `shader %s unavailable, chain off` | b/a | split: file absent/bad → b; capability probe → a |
| 44 | 884 | out of descriptor sets | **b** | gate |
| 45 | 906,925,926,986 | misuse guards | **b** | gate; fatal even unstrict |
| 46–48 | kvsplit 250,255,755 (c) / 895,976,1059 (a) | KV-cold host mem, no shadow / step past the split | a,c | shape / count |

### 1.4 Tier — `c/vk_tier.c`

| # | line | today | class | action |
|---|---|---|---|---|
| 49 | 517 | `experts go back to the CPU` (`d2_stop`) | b/c | b if fault, c if dev2 policy |
| 50–51 | 837,841,1063 | no streaming-slot / step-scratch memory | c | count |
| 52 | 1208,1243,1477 | `a batch failed … tier stops` | **b** | derivative of 33–36 |
| 53–54 | 1304 / 1602,1608,1636 | device stopped answering (**b**) / dev2 not up (c) | b,c | gate / count |
| 55 | **1704** | `format … has no device form` | **a** | refuse-line — **the class-(a) test case** |
| 56 | 1711 | no batch (shaders?) | **b** | gate |
| 57–59 | 1716,1727,1777,1806,1813,1850 | too many forms / extra-layer form / no room / budget small | a,c | refuse-line (1716,1727) / count |

### 1.5 Engines

`deepseek_v4.c:13950` `the device that held the dense layers is gone` — **b**, derivative of 38/39.
`backend_vulkan.c:5342,5364` silent `!fmt_uploadable → return 0` — **a**, refuse-line.

**Counts: (a) 11, (b) 28, (c) 20, 2 split (3, 43), 1 UNKNOWN (37).** **11 (b) sites print nothing today**
(11, 13, 14, 16, 21, 27, 31, 32×4, 38, 39, 5342/5364) — under strict the gate line is their only diagnostic.

## 2. The seam

One helper, one enum, one static table; no Vk handle touched, so it unit-tests without a device.

```c
/* backend_vulkan.h */
typedef enum { COLI_VK_REFUSE = 0, COLI_VK_DEGRADE = 1, COLI_VK_FALLBACK = 2 } ColiVkClass;
/* Returns for REFUSE/FALLBACK always, and for DEGRADE when strict is off.
 * COLI_VK_STRICT=1 + DEGRADE: one line naming op, then exit 70. */
void coli_vk_degrade(ColiVkClass cls, const char *op, const char *reason);
long coli_vk_degrade_events(void);   /* tests */
int  coli_vk_strict(void);
```

Call site is one line: `coli_vk_degrade(COLI_VK_DEGRADE, "qmatmul_gate_up.spv", "absent: fused MLP off");`

- `COLI_VK_STRICT` read **once** (`g_strict`, −1 sentinel) in `coli_vk_init`; `1` = on, unset/other = off.
- Boot line, printed **before** any early `return 0`: `[VK] strict: on (COLI_VK_STRICT) — a capability
  degradation aborts` / `[VK] strict: off`.
- **Knob unset ⇒ no new stderr, no changed control flow** (counters only) ⇒ default bit-identical to
  `a0037a3a`, even for tests that diff `[VK]` logs.
- Strict `DEGRADE`: `[VK] strict: aborting, op=%s — %s`, then `exit(70)` — immediate, not a fail-fast flag
  (upstream has no engine-side "next op" checkpoint; that costs 10 engine edits, and the degradation already
  changed the executed computation).
- `REFUSE` never exits, never counts as degradation; under strict it prints one `[VK] refused: op — reason`
  per distinct op.
- 64-entry table `{op, cls, events}`, one line per distinct op (the fork's dedup reused). Strict only: exit
  summary `[VK] strict: %ld degradations, %ld refusals`.

## 3. Bit-identity and build variants

| variant | expectation |
|---|---|
| knob unset | identical stdout/stderr/exit; counters only |
| `VK=0` | `backend_vulkan.c`/`vk_tier.c`/`vk_chain.c` unbuilt (`Makefile:709–730`); enum inert; no non-VK TU calls it |
| Lavapipe | strict **must pass**: no coop/clustered subgroups/small shared memory are probes ⇒ (a)/(c); a strict `vk-tier-check`/`vk-chain-check` run is the anti-fatal-everything check |
| only `qmatmul.spv` | strict aborts naming the first absent optional shader (11/14/17/19/21) — intended; deployments ship full `VK_SPV` |
| CUDA/Metal/XDna; no device | untouched; class (c) ⇒ no abort (deployment greps `[VK] ready:`, §6) |

## 4. Test matrix

Existing fault knobs suffice — no new hook.

| id | condition | env | expect |
|---|---|---|---|
| T1 | boot, core shader | `COLI_VK_STRICT=1 COLI_VK_SHADERS=<dir w/o qmatmul.spv>` | **exit 70**, `strict: on`, `op=core shader` |
| T2 | boot, optional shader | `COLI_VK_STRICT=1`, `qmatmul_gate_up.spv` aside | **exit 70**, `op=qmatmul_gate_up.spv` |
| T3 | mid-run loss | `COLI_VK_STRICT=1 COLI_VK_WAIT_FAULT=1 ./tests/test_vk_tier` (its `timeout` section drives this) | **exit 70**, `op=expert batch fence` |
| T4 | mid-run loss | `COLI_VK_STRICT=1 COLI_VK_STAGED_FAULT=wait` | **exit 70**, `op=staged upload` |
| T5 | 2nd device | `COLI_VK_STRICT=1 COLI_VK_DEV2_FAULT=1` (skip-0 without a 2nd GPU) | **exit 70**, `op=dev2 …` |
| T6 | default, T1–T4 | `COLI_VK_STRICT` unset and `=0` | **exit 0**; T3/T4 keep their old line; stderr byte-identical to the baseline |
| T7 | **class (a), strict** | `COLI_VK_STRICT=1` + a format with no device form (tier 1704; synthetic `VktSrc` in `test_vk_tier`, or a `qwen38` int2 fixture) | **exit 0**, `has no device form … CPU`, no `strict: aborting` |
| T8 | **class (c), strict** | `COLI_VK_STRICT=1 COLI_VK_DEVICE_CAP_MB=64` over budget; tiny `COLI_VK_TIER_GB` | **exit 0**, `no room for experts`, `scratch … failed` |
| T9 | Lavapipe, strict, no faults | `VK_ICD_FILENAMES=lvp_icd.json COLI_VK_STRICT=1 make vk-tier-check vk-chain-check` | **exit 0** |
| T10 | no-VK build | `make deepseek-v4` (VK=0) + strict | exit 0; no `coli_vk_degrade` symbol |
| T11 | helper unit | new `tests/test_vk_degrade.c`, no device | class→behaviour table; `fork`+`waitpid` asserts exit 70 and `op=`; one line per op; counters; env parse |
| T12 | boot line | any strict run | exactly one `[VK] strict: on` |

New: `c/tests/test_vk_degrade.c` (T11, ~180 lines, in `check`, no device); `c/tests/vulkan_strict.sh`
(T1–T10, ~140 lines, modeled on `vulkan_engines.sh`); `make vk-strict-check` (skip-0 when `VK≠1`/no device).
T6 = run the same command twice (baseline binary vs new), diff stderr.

## 5. Files and diff size

| file | change | lines |
|---|---|---|
| `c/backend_vulkan.h` | enum, 3 decls, comment | +14 |
| `c/backend_vulkan.c` | helper+table+summary (~75), boot line (3), ~30 call sites, `mark_lost{,_dev}` | +115/−6 |
| `c/vk_chain.c` | 187, 365, 473 (split), 884, 4 guards | +10/−4 |
| `c/vk_tier.c` | 517, 1304, 1704, 1711, 1716, 1727 | +9/−5 |
| `c/vk_kvsplit.h` | 250/255, 895/976/1059 | +5/−2 |
| `docs/ENVIRONMENT.md` | one row after line 238 | +1 |
| `docs/vulkan.md` | "Strict degradation mode" subsection | +25 |
| `c/Makefile` | `test_vk_degrade` rule + `vk-strict-check` | +12 |
| `c/tests/test_vk_degrade.c` | new | +180 |
| `c/tests/vulkan_strict.sh` | new | +140 |
| **total** | | **≈ +510/−17** (core ≈120, tests ≈320) |

One PR. `c/deepseek_v4.c` unchanged (covered by `mark_lost_dev`). Nothing in `backend_cuda*`,
`backend_metal*`, `backend_xdna*`; no engine default moves. ENVIRONMENT row: default `0`; `1` = `exit 70`
with `[VK] strict: aborting, op=…` on a capability degradation; legitimate refusals continue; boot prints
`[VK] strict: on|off`; unset/`0` byte-identical; for deployment/CI of a `VK=1` build with the full `.spv` set.

## 6. UNKNOWN — evidence needed

1. **37 (`4109`)** — (c) as budget-derived, but a leak looks identical. Evidence: sweep `COLI_VK_DEVICE_CAP_MB`;
   if it fires with a generous cap, reclassify to (b).
2. **3 (`VKCHECK`, 95 sites)** — needs an audit splitting instance/device/queue (c) from pipeline/descriptor/
   fence (b); P1.5 ships the latter subsets only.
3. **49 (`d2_stop`)** — `why` is caller-built; fault vs dev2 policy is not statically decidable. Evidence: the
   5 call sites plus a `COLI_VK_DEV2_FAULT` run.
4. **no device + strict** — (c) ⇒ no abort. "VK_ONLY" would need a level 2 (`COLI_VK_STRICT=2` promotes
   environment to fatal) or a wrapper grepping `[VK] ready:`. Decision, not analysis.

## 7. First PR (P1.5a)

Seam + the sites printing **nothing** today (bug-hiding, no audit needed): helper, table, boot line, strict
exit; gate at `coli_vk_mark_lost{,_dev}` (38, 39), the silent fence waits (27, 31, 32×4), the silent
shader/pipeline sites (11, 13, 14, 16, 17/19/21), plus (a) refuse-lines at 12, 15, 55, 57, 58, 5342/5364.
Tests T1, T2, T3, T6, T7, T9, T11, T12. Follow-up: T4, T5, T8, T10 with the `VKCHECK` audit.
