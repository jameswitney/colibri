# golden parity report — 20261024-113148

- fork HEAD: a46dad8d test(dsv4): port the golden-parity harness — the D11 re-pin leg
- leg A ref: 073a03b68452ecb6b1b3e9138838d72d5bf95817 — 073a03b6 bench: G1's instrumented legs -- the pipeline gap settles negative (ARTIFACT)
- model: /root/Projects/colibri-v4-docker/models/DeepSeek-V4-Flash
- tiny gate: GREEN
- real deploy pass: findings: 2
- real pinned gate: RED
- deploy-pass findings: 2
- mode: legs=record,cpu,gpu
- oracle validation: CPU-path (target_batch(NULL,…)); GPU parity = scripts/vk_prefill_cell_ab.sh
- cache: /root/bench-worktrees/up2276-merge/.golden/cache/073a03b68452ecb6b1b3e9138838d72d5bf95817 (disabled)
- gpu-inconclusive: 0
- long prompt: >= 2100 tokens (GOLDEN_LONG_BLOCKS='auto')
- total elapsed: 8174.8 s
- per-leg walls: see console.log ([time] lines)

Artifacts: /root/bench-worktrees/up2276-merge/.golden/run-20261024-113148 (per-run stdout/stderr, oracle fixtures, console.log)
