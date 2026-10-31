# AN — PW-B: the stream ring, the port's fills moved off the engine thread (2026-10-26)

**Tree:** `port/pw-b` @ `a8f45741` (this lane's worktree; sole writer). **Rig:** the parity rig
(RX 6900 XT, RADV), GPU for gates + the smoke only — no benchmark arms. **Charter:** the
manager-run parity wave 3, lane PW-B — the census's rank-1 never-tested row (§5.1: "Move the
port's prefill expert fill off the engine thread, ring-class prefetch worker, one layer ahead",
the mechanism behind S0's measured **STAGE 105.6 s of the 159.0 s TTFT window**, X-ob0).

## 1. The survey (both sides, per the charter)

**The fork** (`deepseek_v4.c:18481–18886`, `deepseek_v4_ram_prefetch.h`): a dedicated pthread
(`v4_ram_worker`) preads the **next layer's complete 256-expert set** (3.19 GiB) into an mmap'd
host ring while the engine computes the current layer — O_DIRECT through
`coli_v4_expert_store_read_bytes` (pread-only: no slot, no lease, no mutex state), an
OMP-parallel team for queue depth (86 MB/s at QD1 vs 696 MB/s at QD8 measured on its 13 MB
records). The join discipline: **one ring, one worker at a time** — `v4_ram_prefetch` joins the
previous worker before launching; the layer switch's `v4_ram_take` joins (the take), then the
next stream launches immediately; `take_join_ms` measured **0–10 ms across all 8 full-arm legs**
(the disk stage never on the critical path). Teardown (`ram_end`/`batch_release`) uses
`v4_ram_cancel_join` — a stop flag polled **between experts**, so the wait bounds to one
in-flight pread (issue #4's lesson: never wait out a discarded stream). Every mismatch (segment
restart, unarmed run, failed worker) degrades to the route-aware disk refill; a partial ring is
profit. The take's ring→bank upload is OMP-parallel at the switch (measured 735→404 ms).

**The port** (`vk_tier.c`): the fill is a *function call on the engine thread* —
`vkt_stream_prefetch` (the call sites `deepseek_v4_chain.h:1462/1828`, between A1's submit and
its wait) builds the candidate list from `T.pred` (the last big step's rows per expert at that
layer — chunk-outer order makes chunk ≥ 1's layers predictable) or heat, then `st_fill_group`
does the disk reads via the engine's `load_batch` hook **on this thread** (the bypass reader's
8 × 16 MiB stage pool, groups of 8 in parallel), the OMP-parallel convert into the 256 stream
slots, and the group commit (`coli_vk_tensor_commit` — documented **any thread**, the backend's
own upload queue and mutex). `issue_big` re-fills mid-step the same way for experts the prefetch
missed. X-ob0's decomposition: the fills move 183.25 GiB at 8.16 GB/s *while filling* but the
STAGE role's wall is 105.6 s ≈ 1.74 GB/s effective — the disk reads (~2.2 GB/s, ~83 s of the
window by arithmetic) sit inline between A1's submit and its wait, serialized against the
engine's own orchestration.

## 2. The design as implemented (`COLI_VK_TIER_STREAM_RING=1`, default off)

The port-shaped ring, the fork's disciplines mapped onto the tier's existing machinery:

- **The hook** (`VktConfig.ring_batch`, new): the group-reader shape called on the ring's
  worker thread. DeepSeek V4 wires it to `v4_vkt_ring_batch` — `v4_vkt_load_batch` without the
  engine-thread gate and **without the lease fallback**, over a stage pool of the ring's own
  (8 × 16 MiB, handed out on the worker alone; the engine's pool stays the engine's, which is
  what keeps both lock-free). An expert the store holds in RAM stops the prefix — the tier's
  plan asks `in_ram` and leaves those out; whatever the reader does not fill stays to the
  inline fill at the step. The CUDA tier does not wire it (its fills stay engine-threaded).
- **The submit/take** (`st_ring_submit`/`st_ring_take`): the prefetch call for layer L is the
  fork's switch point — it **takes** the running job (join; the job's books — fills, upload ms,
  bytes — merge into the tier's counters; a cancelled stream is not a rate sample) and hands
  the worker **layer L+1's predicted set**: the same `st_prefetch_plan` the inline path uses
  (T.pred, est desc, residents and below-rule excluded, now also in-RAM excluded), capped at
  `st_per`. A cold next layer (the prompt's **first chunk**, whose layers have no step behind
  them) submits nothing — the inline fill at the step is the fallback, exactly as the charter
  words it. `pthread_create` per job (the fork's per-stream shape); a failure latches the ring
  off for the run and the call falls to the inline path.
- **The halves**: a job owns one half of the streaming slots (`[0, st_per)` / `[st_per, st_n)`,
  alternating), the half the running step is not reading — `join_big` frees the step's half
  before the next job takes it, so reader, converter and uploader of job L+1 never meet the
  engine's use of job L's fills. The engine's three slot scans in `issue_big` (the
  wrong-layer free, the eslot lookup, the inline fill's free-slot pick) **skip the running
  job's range**; an inline fill short of room outside it joins the ring rather than race it.
  The slot handoff is the join, never a concurrent read.
- **The coexistence joins**: a big step runs *beside* the job (no join — that is the win); the
  ring is joined at the prefetch (the take), at decode-class `vkt_issue`/`vkt_dev_count` (their
  promote paths retire stream slots), at `vkt_report` (the books merge before the line), at
  `quiesce` **when `COLI_VK_TIER_SYNC=1`** (the documented deterministic drain, extended to the
  ring: what is in the slots at a quiescent point depends on the routing alone, never on
  thread timing), and at `vkt_shutdown` — `st_ring_cancel`, the stop flag polled between
  reads, the wait bounded to the read in flight (issue #4).
- **Refactor**: `st_fill_group`'s no-pool body became `st_fill_load(layer, eids, slots, n, ok,
  batch, one, ctx, stop, pref, ms, done)` — the engine path calls it with `T.c`'s hooks and
  identical behaviour (verified: the guard `left >= 2 || !one` keeps the engine's lone-expert
  fallback exactly where it was); the worker calls it with the ring's reader, no lone fallback,
  the stop flag, and its job's own books. Two bugs the engagement legs caught and fixed:
  `ok[]` is zeroed on entry (a reader that fills nothing left the caller counting uninitialised
  bytes — the first engagement leg reported 158 "experts" a 32-slot job), and the ring's reader
  is called even for a single-expert group (`left >= 2` was the lone-fallback's shape).

**Default off is byte-identical**: the env gates one branch in `vkt_stream_prefetch` and three
`T.ring_run` skips that are plain ints at 0; the A/B below proves it.

## 3. Unit evidence (`test_vk_tier`'s new `ring` case, all three gate legs)

```
stream ring:
  inline:    502 assignments streamed, 0 ring reads, 8 inline loads   <- env off: the hook is never called
  cutting:   502 assignments streamed, 9 ring reads, 7 inline loads    <- cut batches; every step byte-equal the inline leg's
  refusing:  502 assignments streamed, 3 ring reads, 7 inline loads    <- fail-all reads; the inline fallback covers, byte-equal
  pipeline:  4 experts one layer ahead, order 2 3 4 5                  <- the prediction's order, consumed with 0 inline loads
  coexist:   the other layer's step ran beside the parked job, the take finished it
  sync drain: the quiescent point waited out the parked read for the ring
  teardown:  cancelled, bounded to the read in flight
```

- **Fills ahead in prediction order**: the pipeline leg establishes `T.pred[1]` with a step,
  hands layer 1's plan at `vkt_stream_prefetch(0)`, and the consuming step at layer 1 loads
  **zero** experts inline (`g_loads == 0`) with the fill order equal to the plan's
  (est desc, ties ascending).
- **The join waits only for what's needed**: the reader parks inside its read (test-controlled
  go flag); the step at the *other* layer completes beside it (measured 4 ms against a 700 ms
  bound) and the very next prefetch takes the parked job.
- **SYNC determinism holds**: with `COLI_VK_TIER_SYNC=1` and the reader parked, `vkt_settle()`
  (a public quiescent point) waits out the read (measured 1064 ms ≥ 400 ms) — the drain
  includes the ring — and the outputs stay exact.
- **Inline fallback on worker failure**: the refusing leg — every ring read returns 0 — and the
  outputs byte-equal the inline leg's.
- **Teardown cancels**: 4 reads of 300 ms each queued, the teardown at read 1 — cancelled, 1
  read, well inside the bounds (the uncancelled job would be 1200 ms).
- **Byte-identity**: modes 1/2 memcmp every step's output rows against mode 0's (the ring
  changes timing, never bytes).

## 4. Gates (the full standard set + the smoke; the final tree)

| gate | result |
|---|---|
| `vk-tier-check` (3 legs: default, host-pairs, fmt15) | **PASS** ×3, 0 FAIL lines (the ring case in each) |
| `vk-chain-check` | **PASS** (12,114 frames) |
| `vk-strict-check VK=1` | **PASS** ×4; one intermittent `frag 0.21/0.26` stderr diff — **reproduced on the clean base archive** (`git archive a8f45741`, run 11 of 13), the pre-existing unmasked tier-stat jitter PW-C2 documented; two earlier flake-protocol catches were mine and fixed (timing values in the ring case's stdout lines — stdout must be byte-identical in the gate's unset-vs-0 pair) |
| tiny oracles: `tiny` / `prefix` / `brio` (defaults) | **PASS** ×3, token-exact |
| `dmoe` legs ×8 (plain/ROWS=1/BANK/BANK+ROWS_MAX/layer-order ×3/composed) | **PASS** ×8, token-exact |
| the ring legs: `tiny` + `prefix` with `COLI_VK_TIER_STREAM_BYPASS=1 COLI_VK_TIER_STREAM_RING=1` | **PASS**, token-exact (the new `deepseek-v4-tiny-check-ring` target); the tiny fixture keeps every expert resident so the ring is shape-inert there (the PW-C2 precedent) — the mechanics live in the unit case, the engagement in the smoke |
| `test_v4_serve_framing` | **PASS** |
| `cu_tier.c` / `vk_tier.c` `-DCOLI_CUDA -fsyntax-only` | clean |
| `deepseek-v4-smoke` at **defaults** | **PASS** (rc=0, coherent text, vram0 = the 600,981,504 B floor, back at floor after, no holders) |
| `deepseek-v4-smoke` with **the ring on** (`BYPASS=1 RING=1`) | **PASS** — the boot line carries `the stream ring on`; the single-chunk smoke prompt arms no job (the cold-start rule: one chunk means no next-layer prediction) |
| the smoke's **engagement leg** (`COLI_VK_CHAIN_ROWS=32` → a 2-chunk prompt, 86 steps) | **PASS**, `the ring 10 jobs (8 experts)`, `prefetched 8 (4 used)` — the reads, the off-thread fills and the prefilled-slot consumption all engage at model scale; the 4-of-8 use is the expected small-chunk prediction overlap (few experts reach R=16 rows in a 256-pair step) |

**Default-off proof, the X-ob0 discipline**: a clean `git archive a8f45741` tree vs this tree,
both VK=1, the tiny harness — every PASS line and token identical; the 16-line diff is
host-state noise only (`ram_tiers available=36.31/36.32GiB`, read rates, the stateful
`.coli_usage` counts, paths). The strict gate's unset-vs-0 byte-pair covers the same claim
in-binary.

## 5. What this does and does not claim

The mechanism is landed and proved (unit + model-scale engagement + byte-identity), but **no
benchmark arm ran** (the window's rule), so the STAGE 105.6 → <10 s campaign expectation is
**not measured here** — and the honest ceiling of the pred-gated design is worth stating now:
on the campaign's 2,515-token prompt (2 chunks), **chunk 0's 43 units keep the inline fill**
(their next layers have no prediction — the cold-start fallback the charter prescribed), so the
ring's coverage is chunk 1's 43 units plus any later prompt of the same process. The chunk-0
half of the 105.6 s bucket needs the fork's literal cold shape — a whole-layer fill with no
prediction — which is a one-rule arm on this machinery (`st_ring_submit`'s cold branch filling
the plan's whole non-resident set instead of nothing) and is recorded here as the follow-up the
bench lane should pre-register beside the arm itself. The measured questions for the arm: the
chunk-1 join tail (the fork's take_join class), the prediction overlap at S=2048 (X-ob0's
10,482/22,016 cold-expert churn says it is high), and whether the in-RAM exclusion's inline
remainder still serializes measurably.

## 6. Files

- `c/vk_tier.h` — `VktConfig.ring_batch` + the ring's contract in the streaming docs.
- `c/vk_tier.c` — `st_fill_load` (the extracted fill), the ring (worker/take/cancel/submit),
  the `issue_big` half-skips + the short-room take, the SYNC drain, the decode/report/shutdown
  joins, the boot/run lines, the env arm.
- `c/deepseek_v4.c` — `v4_vkt_ring_batch` + the ring's own stage pool; the hook wired
  (Vulkan only, bypass-gated).
- `c/tests/test_vk_tier.c` — the `ring` case (7 legs) + the doc comment.
- `c/Makefile` — `deepseek-v4-tiny-check-ring`.
- `docs/ENVIRONMENT.md`, `CHANGELOG.md`, `docs/PORT_STATUS.md` — this row, this entry, this
  session.
