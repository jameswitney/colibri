# F13 — the Vulkan tier's host pool ignores the engine's RAM budget

Report lane: research (read-only analysis at `a0037a3a`, no product code changed).

## 1. Root cause

`c/vk_tier.c:1666-1689` (`host_init`, called last from `vkt_init` at `c/vk_tier.c:1927`):

```c
double want = g && *g ? atof(g) * GiB : (double)mem_available() - 4.0 * GiB;
...
if (fit > left) fit = left;            /* left = all - dmax[0] - dmax[1], experts, not bytes */
```

The pool's size comes from **`MemAvailable` of the whole machine** less a flat 4 GiB guess
("the engine's own growth, the page cache the loads go through", `c/vk_tier.c:1661-1665`).
It never sees the engine's resolved RAM budget. On the baseline host the planner had
already committed 17.65 GiB of an 18 GiB `--memory-gb` budget (`ram_tiers ... projected=17.65GiB`,
`c/deepseek_v4.c:1783-1805`), and `MemAvailable` was ~29.75 GiB, so `host_init` granted
25.75 GiB to 1742 experts — 17.65 + 25.75 ≈ 43 GiB against an 18 GiB plan. The kernel
killed the process at the first big submission.

The `4 GiB` reserve is not a bound, it is a hope: the engine's *remaining* commitments
(expert cache growth, KV/workspace reserve, head) are typically far larger, and they arrive
after `vkt_init`.

Inputs actually consulted by `host_init`: `COLI_VK_TIER_HOST` / `_HOST_GB`
(`c/vk_tier.c:1667`), `T.uma`, `T.excl`, `T.exp_bytes`, `coli_vk_tier_host_pool()`
(`c/backend_vulkan.c:3838` — needs `bufferDeviceAddress` + a host-visible system-RAM
memory type), `mem_available()` (`c/vk_tier.c:1521`), and `all - T.dmax[0] - T.dmax[1]`
(expert count, not bytes). The bytes the engine has already claimed only show up
implicitly, inside `MemAvailable`.

## 2. Is the budget visible to the tier at init? Partly — it needs one number plumbed

`VktConfig` (`c/vk_tier.h:180-230`) carries `ram_reserve` (cache *growth* still to come)
and `dense_bytes`, but no total process budget, and no "what the plan still intends to
commit". DSV4 computes exactly that in `coli_v4_expert_store_open_planned`
(`c/deepseek_v4.c:1706-1805`): `plan.planner_available_bytes` (= `min(MemAvailable,
--memory-gb)`), `plan.system_reserve_bytes`, `plan.runtime_reserve_bytes`,
`plan.projected_bytes` (= fixed + dense + full expert cache + head). All of them are
**locals**; only `memory_limit_bytes`, `target_expert_cache_bytes`, `dense_resident`,
`head_cache.bytes`, `dspark_reserve_bytes` survive on `engine->runtime`
(`c/deepseek_v4_internal.h:944-956`). `v4_vk_tier_start` (`c/deepseek_v4.c:13729`,
config built at `13795-13806`) therefore cannot recompute the spare.

Minimal plumbing (no invented API, one concept):

```c
/* vk_tier.h, VktConfig, beside ram_reserve/dense_bytes */
int    ram_planned;   /* 0 = the engine keeps no RAM plan (today's behaviour) */
size_t ram_budget;    /* the budget it resolved (--memory-gb / RAM_GB / MemAvailable) */
size_t ram_spare;     /* what that plan leaves unclaimed: most the pool may hold */
```

DSV4: two fields on `ColiDeepSeekV4RuntimeOptions` (`ram_budget_bytes`,
`ram_planned_bytes`) set once from `plan.planner_available_bytes` /
`plan.projected_bytes`; `ram_spare = budget > planned ? budget - planned : 0` at tier
start. colibri.c already has the resolved budget in `g_ram_budget_gb`
(`c/colibri.c:12138`) and calls `cap_for_ram` (13644) before `vk_tier_start` (13649), so
it can opt in with two lines. The other seven engines set nothing and keep the fallback.

## 3. The bound

```
room = min(mem_available(), ram_planned ? ram_spare : ram_available_fallback)
       in fallback: mem_available() - ram_reserve - 4 GiB        /* was: - 4 GiB */
pool_bytes <= room, then quantised to whole 256 MiB blocks as today
fit <= min(left, room / exp_bytes);  if fit < 1 -> pool off, with a line
```

Invariants kept: `T.excl` gate unchanged (the exclusive book is what makes the pool legal
beside the engine cache, `c/vk_tier.c:1658-1665`, `2084`); `left` (experts the devices do
not hold) unchanged; `coli_vk_tier_pool_limit_dev(2, lim)` (`c/backend_vulkan.c:3824-3838`)
unchanged, so the pool's allocator still refuses past `lim`. Init-time arithmetic only — no
allocation on the hot path (the pool's blocks are allocated lazily by the existing pool).

**Default: keep the pool on, correctly bounded.** With the DSV4 baseline numbers the room
is 18 − 17.65 = 0.35 GiB ≈ 23 experts: still on, and the boot line says why it is small.
`COLI_VK_TIER_HOST_GB` stays an explicit operator override that wins over the plan (no
behaviour change when it is set), but is clamped by `mem_available()` as today and prints
one warning line when it exceeds the spare. `COLI_VK_TIER_HOST=0` still disables. Nothing
is disabled silently: every "off" path prints why.

## 4. Boot line and docs

`c/vk_tier.c:1685-1688`, today one line; new wording, three cases:

```
[VK] tier deepseek_v4: host pool on, 23 experts in 350.0 MiB of system RAM the device
  reads over PCIe (the RAM plan leaves 350.0 MiB of 18.00 GiB; 1742 the devices leave;
  COLI_VK_TIER_HOST=0 off, COLI_VK_TIER_HOST_GB overrides)
[VK] tier deepseek_v4: host pool on, 900 experts in 13.3 GiB ... (no RAM plan: MemAvailable
  less 4 GiB and the engine's cache growth ...)
[VK] tier deepseek_v4: host pool off: the RAM plan leaves 0.10 GiB beside the expert cache
  (--memory-gb 18.00; COLI_VK_TIER_HOST_GB overrides, COLI_VK_TIER_HOST=0 silences)
```

`docs/ENVIRONMENT.md`, after `COLI_VK_TIER_MTP` (line 252) / beside `COLI_VK_TIER_EXCLUSIVE`
(315):

| `COLI_VK_TIER_HOST` | on, beside `COLI_VK_TIER_EXCLUSIVE` | The host pool: the main layers' experts neither device holds, kept in system RAM the primary device reads by address over PCIe. Sized from the engine's RAM plan (the room it leaves beside its expert cache at capacity, its dense weights in RAM, its head and its KV/workspace reserves); an engine without a plan falls back to `MemAvailable` less 4 GiB and its own cache growth. `0` off; `1` also on a device that shares the host's RAM (tests). Needs `bufferDeviceAddress` and a system-RAM host-visible memory type. |
| `COLI_VK_TIER_HOST_GB` | the plan's room | The pool's size in GiB. Wins over the engine's plan (a `[VK] ... over the RAM plan` line says when it does), never over `MemAvailable`. |

Also one sentence in `docs/vulkan.md` §"The routed expert tier" (near the host-pool
discussion at 2046) and a `host pool ... (budget N of M)` note in the tier report
(`c/vk_tier.c:1968-1971` already prints `h_budget`; add the plan figure).

## 5. Tests

All in `c/tests/test_vk_tier.c` (built by `c/Makefile:2357-2362`, run on Lavapipe):

1. **Pure gate** — extract the arithmetic as `vkt_host_room(size_t avail, size_t budget,
   size_t spare, int planned, size_t hold)` (declared in `vk_tier.h`, implemented in
   `vk_tier.c`, stub in the non-VK branch at `vk_tier.h:314`). Cases: plan spare 350 MiB
   → 350 MiB; explicit `budget` below `avail` → budget-bound; fallback → `avail - hold -
   4 GiB`; spare 0 → 0; never negative; never above `avail`.
2. **Fake `--memory-gb` integration** — `vc.ram_planned = 1; vc.ram_budget = 18 GiB;
   vc.ram_spare = 350 MiB;` with `COLI_VK_TIER_HOST=1` on Lavapipe: assert
   `vkt_host_pool_on()`, `T.h_budget <= 350 MiB`, and the boot line names the plan.
   Then `ram_spare = 0`: assert `!vkt_host_pool_on()` and an explicit "off: the RAM plan
   leaves ..." line (capture stderr).
3. **OOM regression** — replay the baseline numbers symbolically (18 GiB / 17.65 GiB /
   15.1 MiB per expert): assert `planned + pool_bytes <= budget` and that the pool holds
   ≤ 23 experts, i.e. the 25.75 GiB grant is unrepresentable.
4. **Explicit knob unchanged** — `COLI_VK_TIER_HOST_GB=0.5` with a plan that leaves
   0.35 GiB: the pool is 0.5 GiB as before, plus the one warning line.

`test_vk_tier.c:1202` already guards the rest of the suite with `COLI_VK_TIER_HOST=0`
(overwrite 0, so CI can still force it), so no existing expectation moves.

## 6. Diff size and files

| file | change |
|---|---|
| `c/vk_tier.c` | `host_init` rewrite (+~35/−12), `vkt_host_room` (+~20), boot-line text |
| `c/vk_tier.h` | 3 `VktConfig` fields + declaration + non-VK stub (+~12) |
| `c/deepseek_v4_internal.h` | 2 runtime fields (+2) |
| `c/deepseek_v4.c` | set them at plan time (1735-1805), pass 3 fields at 13800 (+6) |
| `c/colibri.c` | `.ram_planned/.ram_budget/.ram_spare` from `g_ram_budget_gb` (11305) (+3) |
| `c/tests/test_vk_tier.c` | `host_budget()` case + 3 sub-tests (+~90) |
| `docs/ENVIRONMENT.md` | 2 rows |
| `docs/vulkan.md` | ~8 lines |

≈ 180 lines across 8 files; no new dependency, no ABI change (struct is stack-built per
engine).

## 7. Risks / open questions

- The plan's spare is computed at store-open time; the engine may shrink its cache later
  (the exclusive book gives copies back), so the pool can be conservative. Accepted: it
  errs toward not OOMing, and the boot line makes it visible.
- Engines with no plan keep the fallback, now `MemAvailable - 4 GiB - ram_reserve` (strictly
  safer than today but still a heuristic). Wiring their planners is a follow-up per engine.
- `--memory-gb` caps the *process*; with an explicit cap the planner reserves no system
  share, so the pool legitimately uses the full remaining budget. This is the right
  invariant, but it means a host with 18 GiB total and `--memory-gb 18` still leans on the
  OS. Worth one line in the docs row; not a code change.
- Not addressed here: re-partitioning RAM between the engine cache and the pool (the
  fork's v5 cache sizes the RAM slot pool straight from the resolved budget). That is a
  policy change and a separate PR.
