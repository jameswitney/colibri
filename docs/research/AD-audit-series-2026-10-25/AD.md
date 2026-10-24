# AD — the audit series index (2026-10-25)

Four read-only comparative audits — kernels ([shader-census.md](shader-census.md)), memory placement and
submission ([placement-submission-census.md](placement-submission-census.md)), CPU runtime and kernels
([cpu-parity-census.md](cpu-parity-census.md)), GPU synchronisation ([barrier-census.md](barrier-census.md)) —
run against the fork `colibri-ds4-vulkan` @ `d11fba5b` and the port @ `0c847722` beside the same-day race
(`bench/up2276/audit-*`: fork 107.5 s TTFT / 1.143 tok/s and 108.2 / 1.126 vs port 154.6 / 0.537 and
154.0 / 0.546 — a ×1.43 TTFT and ×2.10 decode gap, ×8 rc=0, greedy text with no degradation on either
prompt). Their synthesis: the gap is **not** kernels (9 of 16 op classes same-class or measured-equivalent;
the kernel ceiling is ≈155–205 ms/tok of the ~750 ms/tok decode gap and ~0 s of TTFT), not CPU kernels
(byte-identical), not MTP (decisively no), not synchronisation (≤10 ms/tok, bounded dead on both sides).
It decomposes onto **(A)** the decode expert placement stack (~822 ms/tok host compute beside fork-class
device kernels), **(B)** prefill staging serialisation (105.6 s inline on the engine thread), **(C)** three
cheap kernel slices (head-on-host 60–70 ms/tok, the V4 FA tile + f16 KV 40–55, mHC fusion 20–30), **(D)**
the expert slab's UE8M0 u8-scale packing (−15…−16 s TTFT, +17.6 % tier capacity), and **(E)** the fork's
decode MoE lanes (unpriced on the port stack) — the manager's "parity without the cell-pipeline
transplant" conclusion that the PARITY WAVE implements, D→A→B→C→E.
