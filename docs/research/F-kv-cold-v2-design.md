# F — P1.1 KV cold tier v2: implementation-ready design

Target: `/root/Projects/colibri-upstream` @ `a0037a3a` (`upstream/dev`). Source of
the capability: `/root/Projects/colibri-ds4-vulkan` @ `d11fba5b` (`19764dd0`,
`PLAN_kv_cold.md`, REVIEW 2026-10-16/18). Read-only survey; no code changed here.

## 0. Verdict — integration shape

**Upgrade in place, in `c/deepseek_v4.c`, inside the existing
`COLI_V4_UNIT_GENERATE_STATS` region** — the same TU that
`c/tests/test_v4_serve_framing.c` `#include`s, so the statics stay testable. The
tier is ~320 lines of statics whose whole interface is five call sites in
`session_generate_impl` plus one session field: no new module.

1. **Two backends, one interface.** `V4_PREFIX_CKPT_DISK=0` keeps today's
   in-memory pool (`V4PrefixCkpt`, 8 slots) verbatim; `1`/`2` route to the disk
   catalog; `v4_ckpt_restore/store/have/plan` dispatch. Every existing setting
   keeps its behavior and there is a zero-disk fallback needing no test rewrite.
2. **Defaults frozen at landing.** `_MIN` stays **512**, `_DISK` stays **1**,
   `_SLOTS` keeps its name. The fork's `512→64` and `1→2` are separate gated
   commits (§7 S9/S10): both change default behavior and both are measurements
   from the fork's host, not this one.
3. **The in-memory fast path that survives is `kv_prefix_reuse`, not the resident
   slots.** Their only unique capability (no disk read on a repeat system prefix)
   is dominated by a 25–80 ms restore and costs ~250 MB/slot; the RAM-side fast
   paths after this change are per-session live reuse and catalog matching on ids
   with no disk touch. The pool survives only as the `DISK=0` backend.

## 1. Upstream as it stands (`c/deepseek_v4.c`)

| what | lines |
|---|---|
| `V4PrefixCkpt {ids,len,layers,snapshots,used,kind}`; `V4_CKPT_MAX_SLOTS=8`; array + clock | 15331–15341 |
| `v4_ckpt_slot_count()` — `V4_PREFIX_CKPT_SLOTS`, default **4** | 15343–15355 |
| statics: dir, fingerprint, disk mode, loaded | 15369–15373 |
| `v4_ckpt_disk_wanted()` — default **1** | 15375–15381 |
| `v4_ckpt_disk_init()` — `<model>/.coli_ckpt`, `coli_own_is_link` guard, FNV-1a over 7 config ints | 15383–15404 |
| `v4_ckpt_disk_path()` — `ckpt_%08x_%d.bin` (slot index) | 15406–15408 |
| `v4_ckpt_disk_write(i)` — magic `COLIV4CK`, `head[4]={1,kind,len,layers}`, whole slot at once, fixed `.tmp` + rename | 15412–15437 |
| `v4_ckpt_disk_load()` — per index, fingerprint check, free+`remove` on failure | 15441–15470 |
| `v4_ckpt_have()` — exact len + memcmp over slots; `v4_ckpt_prev_ids/len` (process-global) | 15472–15480 |
| `v4_ckpt_min_tokens()` — `V4_PREFIX_CKPT=0` off, `_MIN` 512, clamp ≥64 | 15482–15493 |
| `v4_ckpt_restore()` — match = longest slot strictly prefixing the prompt *and shorter* (15510–15522); GPU invalidate 15525; unconditional per-layer weight-load + `window_attention_prepare` sweep 15527–15546; restore 15548–15551; `kv_prefix_clear/record` 15548–15550 | 15505–15554 |
| `v4_ckpt_plan()` — LCP vs previous prompt, skip if `have`, never the whole prompt, `lcp>count-8→0` | 15556–15581 |
| `v4_ckpt_store()` — victim = empty, else LRU prompt-end, else LRU overall; **materialises all layers at once**; disk write when `kind==0||disk>=2`, else deletes the slot's stale file | 15583–15628 |
| triggers: restore 15707, plan 15725, gateway hint 15734–15746, prefix store 15875, prompt-end 15881–15884, `pin=1` 15926 | — |
| cancel branch (`options->should_abort`) — **no capture** | 15820–15841 |

Format: `"COLIV4CK"` + `uint32 fp` + `int32[4]{1,kind,len,layers}` + ids + per-layer
snapshots. Snapshots carry no length prefix and no checksum (writer 8343–8359,
reader 8361–8383, which fails on a short read), so a torn file is caught only by
a short read somewhere in the payload.

Multi-slot: `KV_SLOTS` (1–16) creates `n` sessions (`v4_serve_main` 17318,
`g_v4_mux_slots` 13335) and runs `v4_serve_mux` 17227; `v4_mux_start` 17196 runs
the **whole prefill synchronously** (`prefill_only=1`) inside the single loop.
Each session has its own `fed` (live reuse per slot — what `--kv-slots` buys)
while the checkpoint tier is process-global. Hint plumbing:
`V4ServeRequest.prefix_bytes` 16601, `allow_prefix_hint` 16624,
`v4_serve_take_submit` 16807.

## 2. The fork's v2, mapped (`c/deepseek_v4.c` 24329–25010, sites 25360–25552)

- `V4CkptEntry {ids,len,kind,bytes,used,file[64]}` 24375–24382; catalog +
  `cat_bytes` 24383–24388. Caps: prompt-ends `_SLOTS` default **32** (≤4096)
  24432; bytes `_DISK_GB` default **8 GiB**, 0 = unlimited, 24447.
- Content address: `ids_hash` FNV-1a64 (24458) → `kv_%08x_%016llx.bin` (24470).
- `clear/add/drop` 24476–24543; `gc()` 24545–24588: LRU `kind==1` until
  prompt-ends ≤ cap and bytes ≤ budget, file removed; `kind==0` never a victim.
- Fingerprint 24590–24624: 7 config ints **+ `sliding_window`** + shard count +
  per-shard size/mtime (`coli_st_shard_count/_path`, internal.h 61–62).
- `disk_scan()` 24626–24686: `opendir`, header+ids only, deletes invalid files,
  **deletes every `ckpt_*`**; `_WIN32` → `return` (catalog empty after restart).
- `have` 24688, `best_match` (pure) 24697–24708.
- `disk_write` 24713–24748: streams one layer
  (`snapshot_create→write→destroy`), temp+rename, returns `st_size`.
- `store` 24750–24768: floor, disk-mode gate, `have` dedup, catalog add, `gc`.
- `restore` 24764–24834: header checked against the catalog row (kind, len,
  layers), `need_prepare = fed.len==0` skips the weight sweep, read→restore→destroy
  per layer; on failure `remove`+`catalog_drop`, return 0.
- Pure predicates: `plan_probe` 24836, `hint_len` 24856, `capture_predict` 24886.
- Triggers: restore 25375, plan 25390, hint 25399, checkpoint split 25486,
  **cancel demote** 25488–25504, prefix store 25542, prompt-end 25546–25552.

Upstream's region has **not** changed shape vs the fork's baseline (the fork's v1
was byte-identical): the port is a transplant plus four deviations (§4).

## 3. `--kv-slots` interaction (D4 = both)

- **Catalog stays process-global**, keyed by ids + content address: session B
  restoring a boundary A captured is the point (an idle slot reusing the system
  prefix a busy one already paid for).
- **`v4_ckpt_prev_ids` must move into `ColiV4Session`.** It is global today
  (15479); with `KV_SLOTS>1` the LCP runs against *another slot's* prompt — wrong
  lineage, wrong "already captured" verdict. New fields `ckpt_prev_ids`/`_len`
  (`deepseek_v4_internal.h` 1151–1203), freed in `session_free_buffers` (15121).
- **No in-process writer concurrency** (single-threaded loop) → no locking;
  cross-process safety is content addressing + per-pid temp names (§4c).
- **Latency is the mux cost**: a store (materialise + 70–250 ms write) inside
  `v4_mux_start` stalls every other slot's decode — the same materialisation v1
  already pays. Phase-2 candidate.
- **GPU KV invalidation**: `restore` calls `coli_v4_gpu_kv_cache_invalidate_all()`
  and `v4_mux_start` already does (17200–17202), so no new site — but v2 restores
  fire on nearly every request, dropping the device ring far more often (gate
  T7).

## 4. File-by-file change plan

### 4.1 `c/deepseek_v4.c` (the only file with code)

**a. Types/statics** — keep `V4PrefixCkpt` + `v4_ckpt_slots[]` for the `DISK=0`
backend; add:

```c
typedef struct {
    int *ids; int len; int kind;        /* 0 = system prefix, 1 = prompt end */
    uint64_t bytes; uint64_t used;
    int verified;                       /* 0 = unchecked, 1 = crc ok, 2 = too large */
    char file[64];
} V4CkptEntry;
static V4CkptEntry *v4_ckpt_cat; static int v4_ckpt_cat_n, v4_ckpt_cat_cap;
static uint64_t v4_ckpt_cat_bytes, v4_ckpt_ids_bytes, v4_ckpt_clock;
static char v4_ckpt_dir[1024]; static uint32_t v4_ckpt_fingerprint;
static int v4_ckpt_disk_mode = -1, v4_ckpt_disk_scanned;
```

**b. Functions** (fork signatures; `+` = new):

```c
static int  v4_ckpt_have(const int *ids, int len);
static int  v4_ckpt_best_match(const int *ids, int count);          /* pure */
static int  v4_ckpt_restore(ColiV4Session *, int prompt_count);     /* dispatcher */
static void v4_ckpt_store(ColiV4Session *, int len, int kind);      /* dispatcher */
static int  v4_ckpt_plan(ColiV4Session *, const int *ids, int count);/* + session */
static int  v4_ckpt_plan_probe(const ColiV4Session *, const int *, int);
static int  v4_ckpt_hint_len(ColiV4Session *, const char *prompt,
                             size_t prompt_length, size_t prefix_bytes,
                             int prompt_count, int reuse);
static uint64_t v4_ckpt_ids_hash(const int *ids, int len);
static void v4_ckpt_entry_file(char *out, size_t, const int *, int);
static int  v4_ckpt_catalog_add(const int *, int, int, uint64_t, const char *);
static void v4_ckpt_catalog_drop(int index);
static void v4_ckpt_gc(void);
static uint32_t v4_ckpt_crc32c(uint32_t, const void *, size_t);      /* + */
static int  v4_ckpt_verify(const char *path, V4CkptEntry *);         /* + */
static void v4_ckpt_disk_scan(void);                                 /* + Win */
static void v4_ckpt_scan_one(const char *name, uint64_t bytes);      /* + */
static uint64_t v4_ckpt_disk_write(ColiV4Session *, int, int, const char *);
static void v4_ckpt_mem_restore(ColiV4Session *, int);               /* v1 body */
static void v4_ckpt_mem_store(ColiV4Session *, int, int);            /* v1 body */
```

**c. On-disk header v2.1 — magic `COLIV4C3`, 44 bytes:**

```
char magic[8]="COLIV4C3"; uint32 fp; int32 h[6]={3,kind,len,layers,payload_bytes,crc};
int32 ids[len]; <layers × snapshot payload>
```

Not `COLIV4C2`: its header is 4 words followed by ids *and* the fork's
fingerprint input set differs, so its files can never match us — a distinct magic
turns "silently misparsed" into "cleanly skipped". `payload_bytes`/`crc` are
patched by seeking back in the tmp file after the streaming write (page-cache
resident, no second pass). Temp names carry the pid (`getpid()`/`_getpid()`), so
two processes on one model dir cannot clobber an in-flight write.

**d. Capture triggers** — the three existing plus one:

1. gateway hint, 15734–15746 → `v4_ckpt_hint_len` (factored);
2. LCP plan on a fully fresh prefill, 15725 (per-session state now);
3. prompt-end after every fresh prefill, 15881–15884 (unchanged);
4. **cancelled-prefill demote**, in the `should_abort` branch (15820–15841)
   before `return -1`:
   `if (done_upto >= v4_ckpt_min_tokens() && v4_ckpt_disk_wanted() >= 2 && !v4_ckpt_have(...)) v4_ckpt_store(session, done_upto, 1);`

**e. GC** — as 24545, plus two deviations:

- **pinned cap**: `pin_cap = g_v4_mux_slots > 1 ? g_v4_mux_slots : 4`; beyond it
  the LRU `kind==0` row is evictable. The fork pins all prefixes, so a fleet can
  pin the whole byte budget and starve prompt-ends — exactly the thrash the tier
  exists to prevent. No new knob.
- **catalog ids cap**: `v4_ckpt_ids_bytes > budget/8` also triggers eviction, so
  4096 entries × 100k-token ids (1.6 GB) cannot eat the RAM the tier returns to
  the expert pool.

**f. Edit map**

| lines | edit |
|---|---|
| 15357–15372 | rewrite the block comment (cold tier, disk as system of record); `#include <dirent.h>` under `!_WIN32`; keep `"own_file.h"` |
| 15375–15381 | `V4_PREFIX_CKPT_DISK` default stays **1** |
| 15383–15404 | `disk_init`: + `sliding_window`, + shard count/size/mtime |
| 15406–15408 | `disk_path` → `entry_file` |
| 15412–15437 | `disk_write`: streaming, unique tmp, patched header |
| 15441–15470 | `disk_load` → `disk_scan` (+ Windows arm) |
| 15472–15493 | `have` dispatched; `_min_tokens` unchanged (512) |
| 15505–15581 | `restore` → catalog; `plan` → probe + per-session record |
| 15583–15628 | `store` → dispatched; old body kept as `mem_store` |
| 15725, 15875, 15881, 15926 | call-site signature updates |
| 15820–15841 | insert the demote capture |

### 4.2 `c/deepseek_v4_internal.h`

`struct ColiV4Session` (1151–1203): add `int *ckpt_prev_ids; int ckpt_prev_len;`
after `fed`; the tier otherwise stays file-static.

### 4.3 Windows scan

`v4_ckpt_disk_scan` gets a `_WIN32` arm using
`FindFirstFileA("dir\\kv_*.bin")`/`FindNextFileA`, sharing `v4_ckpt_scan_one`
with the POSIX arm so the two `#ifdef`s differ only in enumeration (`own_file.h`
already pulls `<windows.h>`).

### 4.4 Migration / back-compat for `ckpt_<fp>_<n>.bin`

The fork deletes them (24677–24685). **We must not.**

- **Default: ignore, never delete.** The scan skips `ckpt_*` and any `kv_*`
  whose magic is not `COLIV4C3` or whose fingerprint differs, logging
  `v4_ckpt disk legacy=N unrecognised (left in place)`. Nothing is lost: v1 could
  only restore via its index-keyed load, which the new scan never performs.
- **Opt-in import** `V4_PREFIX_CKPT_LEGACY_IMPORT=1`: for each `ckpt_<fp>_<n>.bin`
  whose fp equals the **v1 fingerprint recomputed with the v1 field set** (7 ints,
  15395–15403), validate the header, parse the payload into scratch and discard,
  then write `kv_<newfp>_<hash>.bin` with the v3 header — payload stream-copied
  verbatim, ids from the v1 header. The `ckpt_*` file is removed only after the
  rename. Idempotent (same content address).
- **Foreign `kv_*.bin`** (fork C2 files): logged, left alone, never matched.
- **`.gitignore`: add `**/.coli_ckpt/`** — `c/deepseek_v4_tiny/` is *tracked*
  (`config.json`, `ref.json`, `tokenizer.json`, `.coli_usage`) and the tiny e2e
  writes checkpoints into it.

## 5. Tests and gates

Extend **`c/tests/test_v4_serve_framing.c`** (the GENERATE_STATS TU, built at
`c/Makefile:2721`, run by `make test-c` → `tools/run_tests.py`, `c/Makefile:3068`):
fake session + `mkdtemp`, poking the statics.

| id | gate |
|---|---|
| T1 | round-trip: store → byte-check header (`COLIV4C3`, fp, kind, len, layers, payload_bytes, crc) + ids → rescan → restore → `snapshot_write` bytes identical to a hand-crafted payload |
| T2 | restart rescan: clear catalog, `scanned=0`, rescan → same rows; a second scan is a no-op |
| T3 | torn/truncated at header / inside ids / inside payload → scan rejects the first two, restore drops + removes the third |
| T4 | GC: prompt-end cap 1 evicts LRU **with its file**; byte budget stops at pinned rows; ids-bytes cap; `pin_cap` evicts the LRU prefix |
| T5 | checksum: flip one payload byte in a ≤256 MiB entry → `verify` fails, row dropped, file removed, restore returns 0 |
| T6 | migration: v1 `ckpt_*` untouched+unmatched by default, imported byte-identically with `LEGACY_IMPORT=1`, removed only after the v2 file exists; a `COLIV4C2` file survives |
| T7 | `--kv-slots`: `ckpt_prev_ids` is per-session (no cross-contamination); a row added for one session is visible to another's `best_match` |
| T8 | Windows scan: T1/T2 bodies with no `#ifdef` in the test (per-OS implementation), run on the Windows leg |
| T9 | e2e cold restart + A/B/A/B + fork-to-earlier-point, tiny fixture **copied to a temp dir**, `V4_PREFIX_CKPT_MIN=64`: A stores 200 → fresh B logs `disk load` + `hit prefix=200`, `DONE reuse=200`; A/B/A/B each turn restores the other lineage; mid-fork at 100 → `reuse=0` — in `c/tests/test_deepseek_v4_prefix.py` (`deepseek-v4-tiny-check`, `c/Makefile:843`) |
| T10 | unchanged-green: `test_deepseek_v4_prefix.py` live reuse/reset/repeat; the same binary with `V4_PREFIX_CKPT_DISK=0` still reuses via the memory backend |
| T11 | VK=0 and VK=1 build clean; `docs/deepseek-v4.md` 289–304 + env table (447) updated |

No test writes into a tracked path; none asserts on timing (CRC cost is measured
in S8, not gated).

## 6. Risks and open questions

1. **CRC cost vs the 25–80 ms read budget.** Verify **once per entry, lazily,
   before its first restore**, cache `verified` in the catalog, skip above 256 MiB
   (`verified=2`). If the overhead exceeds ~50% of the read, verify ids + first
   layer only.
2. **fsync cadence.** Recommended: **none** — a capture is regenerable, the scan
   drops torn files, rename covers crash-mid-write, and a lost capture costs a
   re-prefill, never a wrong answer (`kv_persist.h` fsyncs because it is the only
   copy).
3. **Writer concurrency.** In-process none; cross-process the same fingerprint
   means the same address and identical bytes, so per-pid temp names make the
   race benign. Open: two processes with *different* weights on one dir duplicate
   payloads and neither GC sees the other's files (bounded leak, follow-up).
4. **Fingerprint inputs.** shard count + size + mtime is cheap and catches a
   re-download with identical geometry; it false-misses on `touch`/copy (safe
   direction). Open: add a tokenizer hash (a template change invalidates ids)?
   Recommend yes **before first deployment** — it changes every entry's
   fingerprint, so it cannot be added later without a re-capture.
5. **Pinned-prefix cap** deviates from the fork; if pure pinning is preferred it
   needs a `kind==0` byte-budget policy instead, or the tier can be starved.
6. **Default flips** (`_MIN` 64, `_DISK` 2) are not in this PR — each needs its
   own on-host measurement.
7. **`v4_ckpt_capture_predict` has no caller upstream** — P1.3 admission does not
   exist here (`v4_request_kv_delta`, `g_v4_kv_positions_hwm`,
   `v4_session_context_ceiling`: 0 hits). Out of scope; the pure predicates are
   factored so P1.3 can project without touching the tier.
8. **Snapshots carry no per-layer length**, so a file truncated exactly at a
   layer boundary and followed by stale bytes is caught only by the CRC — it is
   load-bearing for T5, not decoration.

## 7. Implementation sequence

1. **S1** types + header + catalog (`V4CkptEntry`, statics, `ids_hash`,
   `entry_file`, catalog ops, `have`, `best_match`, `gc`, `crc32c`), landing with
   S2 so no new static is unused.
2. **S2** scan (POSIX + Windows) with the legacy policy and foreign-magic skip.
3. **S3** streaming write/restore, `COLIV4C3` header, pid temp, header patch,
   `verify`, `need_prepare = fed.len==0`. 4. **S4** dispatch: catalog vs memory
   backends; per-session `ckpt_prev_ids` + `session_free_buffers`.
5. **S5** triggers: cancel demote, `plan` signature, factored hint.
6. **S6** hermetic tests T1–T8. 7. **S7** e2e T9/T10 in
   `test_deepseek_v4_prefix.py`. 8. **S8** docs (cold-tier section, env table + `_DISK_GB`, `LEGACY_IMPORT`),
   `.gitignore`, REVIEW/PORT_PLAN, measured CRC/restore numbers.
9. **S9** (own commit, gated) `V4_PREFIX_CKPT_DISK` 1→2, evidence = T9.
10. **S10** (own commit, gated) `V4_PREFIX_CKPT_MIN` 512→64, with an on-host
    TTFT measurement reproduced (not the fork's number).

### Acceptance criteria

- **AC1** with `_DISK` unset, `test_v4_serve_framing`, `test_deepseek_v4_prefix`,
  `test_deepseek_v4_tiny` and `test_deepseek_v4_brio` are green; `DISK=0` still
  reuses via memory; `V4_PREFIX_CKPT=0` disables the tier.
- **AC2** T1–T8 green on Linux (`make test-c`), T8 green on Windows;
  `deepseek-v4-tiny-check` includes T9 and stays green.
- **AC3** no `ckpt_*`, no `COLIV4C2` and no fingerprint-mismatched file is ever
  removed, and the count is logged; with `LEGACY_IMPORT=1` the v1 payload is
  byte-preserved and the v1 file disappears only after the v2 rename.
- **AC4** `git status` after a full `deepseek-v4-tiny-check` is clean.
- **AC5** VK=0/VK=1 build clean (two known warnings only), docs updated, every
  default identical to `a0037a3a`.
