# AK — PW-A2: zero-disk decode closes **premise-falsified, no lever** (2026-10-25)

**Date:** 2026-10-25 · **Lane:** pw-a2 (`port/pw-a2` @ `d30df627`, docs-only close). GPU used for
gates only (no bench arms — the window is the manager's; every number below is read off existing
logs). **Pre-registered frame** (the parity wave's A2): the decode-disk asymmetry — the fork's
decode reads `expert_requests=0 … bytes=0` where the port's run totals ~92 GB / ~6.9k disk loads —
so *make decode never read disk*: at prompt-end, cover the decode hot set in the store's RAM cache,
ranked by the landed `.coli_mfu` decode-only table, env-gated, default off.

**The verdict, up front:** the magnitude premise **held** — the port's decode window owns **59–63 %
of the run's expert-disk bytes (~54–59 GB, 4.0–4.6k loads, ~64 loads/token sustained)**. But the
asymmetry premise is **false**, and the mechanism is **dead on the tree's own evidence**:

1. **The fork reads the same mass at decode.** Its `bytes=0` line is the *store lease counter
   only*; beside it, the fork's own `v4_direct` line reads **199.82 GB whole-run / 15,880 reads**
   — net of the 11,008-record prefill ring pass (147.2 GB), **52.7 GB at decode**. The port's
   decode window (53.9–59.3 GB) is **at parity**. "Zero-disk decode" was never the fork's
   property; this is the placement census's **second counter-class error** (§4 caught the same
   population error in the hit-rate row and kept it in the bytes row — row 8 of §1.2 stands
   corrected by this doc).
2. **The working set is 2.1× the store.** The decode set is **~4,000–4,440 distinct experts**
   (~102/layer), the store holds **48 slots/layer (2,064 slots = 25.70 GiB, exactly spent** — the
   S-map's premise #1: no RAM to widen into). No preload at this capacity approaches zero; a
   *perfect-oracle* preload saves ≤ 2,064 loads (~27.6 GB) and nothing more.
3. **The mandated rank source is measured null-to-negative, in-tree.** The S7 arms already ran the
   coverage lever's every shape: the full-store `.coli_mfu`-ranked prewarm (2,064 experts,
   25.7 GiB, 12.1 s) moved decode-window misses **4,435 → 4,534 (worse)**; pin tenure worse still
   (F32 4,643, F48 5,160; `hit_rate_d` 68.1 → 62.9). "The history rank displaces the live decode
   set" is `docs/deepseek-v4.md`'s own recorded verdict.

The manager confirmed the close: a clean falsification beats a pointless lever. Where the real
lever is — §5.

---

## 1. Step 0 — the split (what the ~92 GB run figure actually is)

The W1/census figure (~92 GB, ~6.9k loads) is **whole-run store-miss bytes**. The store prints
decode-only counters (`hit_rate_d`, S7's landing), so the window splits exactly. Method: the
decode-window store-request population is the non-device decode visits — `D_d = 16,254 −
device_served` (the tier run line's `decode: N of 16254 routed experts on the device`); decode
hits `H_d = hit_rate_d · D_d`; decode-window misses `= D_d − H_d`; the remainder of the run's
misses is boot-warm + prefill-window traffic (the tier's 545 warm-start uploads and prefill's
host-computed expert leases, all cold misses at `PREWARM=0`). Every leg closes to ±0.3 % (the
residual is the printed rate's rounding); bytes/miss = 13.37 MB = one 12.75 MiB expert record +
slack, uniform across legs.

| leg | store requests / misses / GB (run) | `hit_rate_d` | dev served | **decode-window misses / GB** | boot+prefill-window misses / GB |
|---|---|---:|---:|---:|---:|
| `w1-c0-r1` (C0, standing) | 16,973 / 6,878 / 91.95 | 71.481 | 2,124 | **4,030 / 53.9** | 2,848 / 38.1 |
| `s3-l-dprof` (mode-0 ref) | 16,444 / 7,152 / 95.62 | 68.220 | 2,596 | **4,341 / 58.0** | 2,811 / 37.6 |
| `w1-gf-dprof` (G+F) | 14,499 / 7,187 / 96.09 | 62.618 | 4,421 | **4,423 / 59.1** | 2,764 / 37.0 |
| `s7-c-C1` (S7 control) | 17,137 / 7,360 / 98.40 | 68.134 | 2,337 | **4,435 / 59.3** | 2,925 / 39.1 |
| `s7-p-P1` (full prewarm) | 18,347 / 7,633 / 102.05 | 67.421 | 2,337 | **4,534 / 60.6** | 3,099 / 41.4 |
| `s7-f-F32` (frozen 32) | 19,217 / 7,440 / 99.47 | 66.635 | 2,337 | **4,643 / 62.1** | 2,797 / 37.4 |
| `s7-f-F48` (frozen 42) | 19,590 / 7,848 / 104.92 | 62.924 | 2,337 | **5,160 / 69.0** | 2,688 / 35.9 |

Anchors: `/root/bench-colibri/up2276/w1-c0-r1.log:34` (`v4_tokens … expert_requests=16973 hits=10095
misses=6878 … hit_rate_d=71.481 bytes=91954348032`) and `:43` (the tier run line,
`decode: 2124 of 16254 … (13.1%)`); `s3-l-dprof.log:33/:72`; `w1-gf-dprof-r1.log:34/:71`;
`/root/bench-colibri/up2276/s7-{c-C1,p-P1,f-F32,f-F48}-1.log` (the S7 lane's legs, same lines).
Cross-check for `w1-c0-r1`, the tightest closure: `D_d = 16,254 − 2,124 = 14,130`; `H_d =
0.71481 × 14,130 = 10,096 ≈ 10,095` printed hits — the decode window owns 4,030–4,035 of the
6,878 misses; boot+prefill owns ~2,845, and that ~2,820–2,850 prefill-window count is stable
across all seven legs regardless of `hit_rate_d` (it is the cold-store population: 545 tier
warm-start lookups + prefill's host-computed expert leases).

**So the audit's class is real and material: ~64 misses/token sustained across the whole window
(4,030/63), ~856 MB/token — 59–63 % of run bytes.** The pre-registered stop rule (decode-window
< 5 GB ⇒ weak premise) does not fire. The lane dies on different, stronger grounds.

## 2. The fork-parity falsification — census row 8 corrected

The census's §1.2 row "routed experts — disk at decode: fork **0 bytes** / port **91.85 GB**"
reads the fork's store counter as its disk traffic. The fork's own full-arm log carries the two
counters side by side:

```
fork audit-fork-r1.log:5350: v4_tokens … expert_requests=0 hits=0 misses=0 … bytes=0 target_only=1
fork audit-fork-r1.log:5357: v4_direct reads=15880 flock_reads=0 fallbacks=0 payload_bytes=199816642560
```

`v4_tokens` counts the **v5 store lease path only**; every other read (the prefill ring, the
decode demand installs, the async MoE lanes' read+compute jobs) rides `v4_direct`. The arithmetic:

- prefill ring = 11,008 records × 13,369,344 B = **147.17 GB** (`prefetched=11008 consumed=11008`,
  `audit-fork-r1.log:3335`);
- **decode window = 199.82 − 147.17 = 52.65 GB over 4,872 reads** (15,880 − 11,008);
- the fork's no-tier arm agrees exactly: `fork-noexperts-r1.log:3338/:3345` — store decode misses
  **5,113**, and `v4_direct` reads 16,121 − 11,008 = **5,113** (the store miss and the direct read
  are the same event, one per distinct expert), 55.68 GB net of the ring.

| | decode-window disk | whole-run expert disk |
|---|---:|---:|
| fork, full arm (`audit-fork-r1`) | **52.7 GB** / 4,872 reads | 199.82 GB (`v4_direct`) |
| fork, noexperts (`fork-noexperts-r1`) | 55.7 GB / 5,113 reads | 202.85 GB |
| port, standing (`w1-c0-r1`) | **53.9 GB** / 4,030 loads | 91.95 GB (store) |
| port, S7 control (`s7-c-C1`) | 59.3 GB / 4,435 loads | 98.40 GB |

**Parity.** The fork does not avoid decode disk; it *hides* it — behind six async MoE lanes that
overlap the read with the compute (census §1.2/§2.3) and behind VRAM demand installs for the hot
head (A1's landed `COLI_VK_TIER_DECODE_GROW`, W1's G verdict: device share 13.1 → 24.9 %). The
census itself caught exactly this counter-population error once — §4: "the fork's 68.5 % is
measured in its noexperts arm — in the fast arm the decode store path records zero requests…
'parity' of a component the fork's fast configuration does not use" — and then kept the same
error in the bytes row one table above. **Row 8's fork cell reads `0` because the fork's fast
arm stops using the counted path, not because it stops reading.** W1's own G-arm note (AI §3:
"the 154 installs are one-time cold uploads… not in I/O reduction") is the same finding from the
other side.

## 3. The capacity bound — why no preload can reach zero

- The decode working set is **~4,000–4,440 distinct experts**: the cold-store controls' whole
  decode-window miss counts (4,030–4,435) *are* the distinct counts — every distinct expert's
  first visit misses, and revisit hits then keep the rate at `hit_rate_d`. Per layer that is
  **~102 of 256 experts**.
- The store holds **48 slots/layer = 2,064 slots = 25.70 GiB**, and that is the whole RAM plan
  (`target_cache` exactly spent, 179.6 MiB spare = 14 places — S-store-map premise #1,
  `l3-a0-hot0.log:10`). The store's own grain cannot widen (option (b) of the brief has no bytes
  to widen into); the census's fork-vs-port RAM totals are the same 27.6–27.8 GiB both engines.
- Working set ÷ capacity = **2.1×**. The misses are **sustained** (64/token through the window,
  not a decaying warm-up): with 102 distinct/layer against 48 slots/layer, every below-head visit
  is a capacity miss. A *perfect-oracle* prompt-end preload of all 2,064 slots saves at most the
  head's first-visit misses — **≤ 2,064 loads ≈ 27.6 GB** — and leaves ~2,000 loads of tail
  regardless. "Never read disk" is unreachable at this RAM plan, for this store *and* for the
  fork's pool (1,982 slots + ~666 VRAM ≈ 2,648 places < 4,400 — which is why §2's fork reads
  52.7 GB at decode).

## 4. The S7 re-read — the mandated rank source already measured

The brief's rank source is the `.coli_mfu` decode-only table (S7's landing), and the S7 lane
already armed every coverage shape at the standing rig (single legs, `/root/bench-colibri/up2276/s7-*`,
recorded in `docs/deepseek-v4.md`'s `COLI_V4_FROZEN_PCT` row):

- **P (the preload, boot-time, full store):** `[v4] expert cache: reading each layer's most used
  experts (2064 experts, 25.7 GiB) … read in 12.1 s (2.13 GiB/s)` — decode-window misses
  **4,435 → 4,534 (worse)**, `hit_rate_d` 68.1 → 67.4, `after_first` 115.4 → 116.3 s. The history
  rank predicts the live decode set no better than the demand LRU already does, and the preloaded
  slots displace live-set LRU content at the margin.
- **F32/F48 (pin tenure, the brief's option (a)):** `hit_rate_d` 66.6 / **62.9**, decode-window
  misses 4,643 / 5,160 — the frozen set actively displaces the live set (the doc row's own words).
- **P's real win was TTFT −5.4 s (154.4 → 149.0 s)** — page-cache warming of prefill's stream
  files (the prewarm's 25.7 GiB sits in the page cache the 183-GiB stream then partly hits). A
  **prompt-end** preload cannot get that: it runs after prefill, pays its ~12 s with no stream to
  warm, and buys the measured-null decode coverage. The prompt-end variant is *strictly worse
  than the landed boot prewarm on both axes* — which is why this lane closes instead of building
  it.
- Third witness, W1's G-arm: 154 VRAM installs by the same decode-only rank moved disk loads
  6,878 → 6,962 (**+84**) — residency growth does not reduce the tail's reads either.

## 5. Where the lever actually is (the redirect this close hands the campaign)

The port's decode window, decomposed (V-g1, closes exactly): 1,619.5 ms/tok = tier MoE CPU
**821.9 (50.7 %)** + forward glue 518.8 (32.0 %) + chain waits 235.0 (14.5 %, 97.7 % device time)
+ head 72.9 − overlap 29.1. The disk reads sit inside that first term: the port computes its
non-device experts **inline on the engine thread**, reading each missed expert (64/token, ~856
MB/token) synchronously between submits. The fork pays the same reads and hides them behind **six
async MoE read+compute lanes** (+ a 4-lane next-layer pilot), its own A/B pricing that family at
**+23 % decode** — census reconciliation row 7, **never-tested on the port**, the last
never-tested row of the decode fold after G (row 6, landed as `COLI_VK_TIER_DECODE_GROW`, W1:
+16 %) . That mechanism — overlap the measured 54–59 GB decode-window read mass, not remove it —
is the remaining decode-disk answer, and it enters the queue as the re-briefed PW-E slice (the
manager's follow-up: from "probe" to "the lanes design against the measured 54–59 GB
decode-window read mass").

## 6. What this lane changed

Nothing executable on the close itself — the falsification is the deliverable. The gate run that
was to be the no-op proof found the **W1 hotfix's own debt** and repaired it test-only:
`d73b82e1` made fmt 15 opt-in without updating PW-D's `packed_scales` case
(`tests/test_vk_tier.c`), so `vk-tier-check` — and `vk-strict-check`'s unset leg, which re-runs
that binary — were red at the branch point (`expert bytes: ue8m0-packed 15.00 MiB, f32 scales
15.00 MiB`). The repair: the case's env-independent half (the ue8m0↔f32 identity, the
scale-word counts) stays in every leg; the byte-shrink half reads the formats through
`vkt_expert_bytes`, whose `dev_fmt()` routes `MXFP4_E8M0` to fmt 15 only while armed, so it runs
in a new third gate leg — `COLI_VK_TIER_FMT15=1 ./tests/test_vk_tier shaders/qmatmul.spv fmt15`
(the host-pairs pattern; the env is set at `main`'s top, before `tier_fmt15()`'s one-time
cache) — and asserts the shrink **whichever way the default later lands** (if PW-Dfix returns
fmt 15 to default-on the env is redundant and every check still holds). Full standard set green
at the close head: vk-tier ×3 legs (the armed leg prints 12.75 vs 15.00 MiB ×1.1765), vk-chain
12,039 frames, vk-strict (one timing-jitter flake between its comparison legs — green on re-run,
byte-identical by hand under the script's own mask), `deepseek-v4-tiny-check` ×2 (torch absent
on this box: the shared banked fixture, byte-identical config/ref/tokenizer, weights borrowed
read-only from up2276-merge — AH's precedent), tiny-dmoe all 8 legs, serve-framing, `cu_tier.c
-DCOLI_CUDA -fsyntax-only`; no ENVIRONMENT row (no new knob). CHANGELOG and PORT_STATUS carry
the closure. Census row 8's correction rides in §2.

## 7. Sources

Port legs: `/root/bench-colibri/up2276/w1-{c0,gf-dprof}-*.log`, `s3-l-dprof.log` (also committed at
`bench/up2276/`), `s7-{c-C1,p-P1,f-F32,f-F48}-1.log` (the S7 lane's legs, rig-side only — the
numbers are quoted verbatim in §1/§4 so the record is self-contained). Fork legs:
`/root/bench-colibri/up2276/audit-fork-r1.log` (`:3335` ring, `:5350` store, `:5357` v4_direct),
`fork-noexperts-r1.log` (`:3338`, `:3345`), `fork-full-r3.log:4093+` (the post-prefill refill and
demand installs the census read as the 0-bytes arm). Design/context: `docs/research/
AD-audit-series-2026-10-25/placement-submission-census.md` §1.2 row 8 and §4 (the error class),
`S-store-mfu-map-2026-10-23.md` (premise #1, §5d coverage arithmetic), `V-g1-dprof-2026-10-24.md`
(the decode decomposition), `AH-pw-a1-decode-grow-2026-10-25.md` + `AI-pw-w1-2026-10-25.md` (G's
measured device-share win and its I/O-neutrality), `docs/deepseek-v4.md`'s `COLI_V4_FROZEN_PCT`
row (the S7 verdict of record).
