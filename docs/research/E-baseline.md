# E — Phase 0 baseline (pre-flight)

**Date:** 2026-10-19 · **Target:** `upstream/dev` @ `a0037a3a` (v2.0.0+~590)
**Host:** 18 threads, 38 GiB RAM, AMD RX 6900 XT (RADV NAVI21, Mesa 26.2.1),
`glslc` present, no cooperative matrices, no native fp8 MMA, no fp64 shaders.
**Worktree:** `/root/bench-worktrees/port-baseline` (detached at `a0037a3a`).
Upstream moved from `5d56c05a` to `a0037a3a` during the analysis (PRs #2224–#2238);
the pre-flight below was first run at `5d56c05a` and the build/GPU checks were
re-run at `a0037a3a`.

## Build

```bash
make -f Makefile.deepseek-v4 VK=1 ARCH=native -j18 deepseek-v4
# real 0m6.389s (all 30 V4 units + expert_store_registry + backend_vulkan + vk_tier + vk_chain)
```

Clean build, no errors. The binary loads Vulkan dynamically (no `libvulkan`
in `ldd`), consistent with upstream's optional-backend design.

## GPU pre-flight — `make VK=1 vk-tier-check`

**PASS** (11.8 s). Device:

```
[VK] ready: AMD Radeon RX 6900 XT (RADV NAVI21), compute qfam 0, memtype 3,
     fused gate+up, absorb attention, tiled GEMM from S=2 and S*O>=4096, staged uploads
```

DeepSeek-V4-specific result (the activation contract the fork's shaders would
have to re-prove):

```
DeepSeek V4:
  MXFP4 ue8m0, DeepSeek V4 roundings
    device 271 of 306 assignments, 271 rows bit-identical to the CPU's arithmetic,
    worst row 0.00e+00, worst sum 0.00e+00
```

Other formats and the streaming/fault paths also pass (`worst` 3e-7 class;
MXFP4 V4 roundings 9.75e-03 is the documented thresholded case).

## GPU pre-flight — `make VK=1 vk-chain-check`

**PASS** (24.1 s):

```
chain: 10594 frames, 6561 ops, 252 matmuls (32 GEMM), 28704 barriers
kvs cold: every case with the host's part on the device, the same bits however the forward is cut
```

The KV split past the device budget works here with
`COLI_VK_KV_COLD=device`, and the chain's decode/prefill cuts are
bit-consistent. This is upstream's DSV4-capable attention/KV machinery running
on the target GPU.

## Blocked — tiny fixture oracle

`make VK=1 deepseek-v4-tiny-check` fails at fixture generation:

```
DeepSeek V4 tiny generation requires PyTorch and an official Transformers build
with DeepseekV4ForCausalLM
```

`torch` / `transformers` are not installed. The fork's generated
`c/deepseek_v4_tiny/model.safetensors` cannot be reused: upstream's tiny
`config.json` differs (`5cee1204…` vs the fork's `ce1c797b…`), so the weights
would not match upstream's committed `ref.json`.

Options:
1. create a venv in the worktree and install
   `tools/requirements-deepseek-v4-tiny.txt` (torch 2.13.0+cpu,
   transformers 5.14.1, safetensors 0.8.0);
2. skip the tiny oracle for Phase 0 and rely on the real-checkpoint run;
3. generate the fixture on a host that already has the dependencies.

## First measurement attempt — OOM and a real upstream bug

The first real-checkpoint launches (at `5d56c05a`) were killed by the host OOM
killer. The log shows why:

```
[VK] tier deepseek_v4: host pool on, 1742 experts in 25.75 GiB of system RAM ...
ram_tiers available=16.00GiB ... target_cache=13.39GiB ... projected=15.51GiB
radv/amdgpu: Not enough memory for command submission.
[VK] chain: queue submit failed (-4): the device is lost
```

`COLI_VK_TIER_HOST` (undocumented in `docs/ENVIRONMENT.md`) defaults on and
sizes the host expert pool from `mem_available() - 4 GiB`, ignoring the
engine's `--memory-gb` plan. It allocated 25.75 GiB beside a 15.5 GiB engine
cache. Mitigation for the baseline: `COLI_VK_TIER_HOST=0`, and a 24 GiB
systemd cgroup so an overcommit kills the engine, not the agent. This is
recorded as fix **F13** in the plan.

## Pending — the actual baseline measurement (D10 approved)

- real checkpoint `/root/Projects/colibri-v4-docker/models/DeepSeek-V4-Flash`
- `COLI_VULKAN=1`, default chain first, then `COLI_VK_CHAIN=0`
- 2k code prompt / 64 decode tokens; 8k prompt TTFT
- record: decode tok/s, TTFT, prefill tok/s, disk-busy %, GPU %, tier hit rate

The fork's comparison points are in `C-perf-evidence.md` §1.
