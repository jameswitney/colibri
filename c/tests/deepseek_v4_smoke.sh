#!/usr/bin/env bash
# deepseek-v4-smoke — the model-scale smoke gate (AI-pw-w1's institutional lesson:
# every unit/tiny gate that blessed PW-D's fmt 15 ran at geometries that cannot
# reach the model's resident path, and the P0 surfaced only when a window spent a
# GPU-hour on the real model; a slice that changes a tier/chain default owes one
# ~2-minute generation on the real model before merge).
#
#   make deepseek-v4-smoke            # from c/ (VK=1 build of deepseek_v4)
#   MODEL=... make deepseek-v4-smoke   # another checkpoint
#
# What it runs: DeepSeek V4 Flash (MODEL, default the rig's path) on a ~100-token
# prompt for 16 tokens, and checks:
#   rc = 0;
#   a non-empty generated_text of real words (not just whitespace or one token);
#   no failure lines in the log ("chained block failed", "device is lost", a
#     non-finite router class, a submit that failed).
# SKIPS cleanly (exit 0, a SKIP line) when the model directory, the Vulkan
# device or the shaders are absent — the house rig gates' rule: absent
# environment is not a failure. A busy card (other /dev/dri holders) fails the
# gate with the holders named: an arm beside a co-tenant is confounded, not
# skipped.
#
# The tier's format lever rides the caller's environment: the gate at defaults
# runs the tree's standing default, `COLI_VK_TIER_FMT15=1 make deepseek-v4-smoke`
# the packed form armed — the P0's two legs.
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL=${MODEL:-/root/Projects/colibri-v4-docker/models/DeepSeek-V4-Flash}
BIN=./deepseek_v4
PROMPT=tests/deepseek_v4_smoke_prompt.txt
TOKENS=${DEEPSEEK_V4_SMOKE_TOKENS:-16}
TIMEOUT_S=${DEEPSEEK_V4_SMOKE_TIMEOUT:-1500}
RAM_GB=${DEEPSEEK_V4_SMOKE_MEM_GB:-28}
OMP=${OMP_NUM_THREADS:-16}

fail() { echo "FAIL: deepseek-v4-smoke: $*" >&2; exit 1; }
skip() { echo "SKIP: deepseek-v4-smoke: $*" >&2; exit 0; }

[ -d "$MODEL" ] || skip "no model at $MODEL (MODEL=<dir> to point elsewhere)"
[ -f "$MODEL/config.json" ] || skip "$MODEL has no config.json"
[ -f "$PROMPT" ] || fail "no prompt file $PROMPT (the gate's own)"
if [ ! -x "$BIN" ] || ! nm "$BIN" 2>/dev/null | grep coli_vk >/dev/null; then
    make deepseek-v4 VK=1 || skip "no Vulkan build of deepseek_v4 (VK=1 needed)"
fi
nm "$BIN" 2>/dev/null | grep coli_vk >/dev/null || skip "deepseek_v4 built without the Vulkan backend"

# a device: the run's own log says "no Vulkan device" when there is none, and the
# gate reads it back below; the holders check keeps a co-tenant's run from
# silently shrinking the tier (the 2026-10-22 mmmm arm's 2.1 GiB lesson).
HOLDERS=$(fuser /dev/dri/by-path/*render* 2>/dev/null | tr -s ' ' ',' || true)
VRAM_SYSFS=$(ls /sys/class/drm/card*/device/mem_info_vram_used 2>/dev/null | head -1)
VRAM0=""
[ -n "$VRAM_SYSFS" ] && VRAM0=$(cat "$VRAM_SYSFS")
[ -z "$HOLDERS" ] || fail "the GPU has holders ($HOLDERS); settle the card and retry"

LOG=${DEEPSEEK_V4_SMOKE_LOG:-$(mktemp -t dsv4-smoke-XXXXXX.log)}

# the rig's frozen expert-history snapshots, where they exist (the bench arms'
# protocol): the warm start plans by the same counts every run, and the gate leaves
# the shared model's history as it found it
for s in coli_usage coli_mfu; do
    [ -f "/root/Projects/colibri-upstream/bench/$s.fixed" ] && \
        cp "/root/Projects/colibri-upstream/bench/$s.fixed" "$MODEL/.$s"
done
rm -f "$MODEL/.coli_ckpt"   # no cold-KV restore in a smoke leg

echo "deepseek-v4-smoke: model $MODEL, prompt ~100 tokens, $TOKENS tokens out, vram0=${VRAM0:-?}B ($VRAM_SYSFS), tier fmt ${COLI_VK_TIER_FMT15:-default}"

set +e
timeout "$TIMEOUT_S" env COLI_VULKAN=1 COLI_TEMP=0 KVSAVE=0 V4_PREFIX_CKPT=0 COLI_V4_PREWARM=0 \
    OMP_NUM_THREADS=$OMP OMP_PROC_BIND=close OMP_PLACES=cores \
    "$BIN" "$MODEL" --prompt-file "$PROMPT" --max-tokens "$TOKENS" \
    --memory-gb "$RAM_GB" >"$LOG" 2>&1
rc=$?
set -e
echo "deepseek-v4-smoke: rc=$rc, log $LOG"

# absent environment is a skip, not a failure
grep -q "no Vulkan device" "$LOG" && skip "no Vulkan device on this host"
[ "$rc" = 124 ] && fail "timeout after ${TIMEOUT_S}s (log $LOG)"
[ "$rc" = 0 ] || { tail -5 "$LOG" >&2; fail "rc=$rc (log $LOG)"; }

# the failure classes the window found: a tier/chain default that corrupts
# resident-expert compute dies mid-decode with the router's non-finite class
grep -q "chained block failed" "$LOG" && fail "chained block failed in MoE (log $LOG)"
grep -qi "device is lost" "$LOG" && fail "device is lost (log $LOG)"
grep -q "submit failed" "$LOG" && fail "a submit failed (log $LOG)"
grep -Eq "\[VK\][^(]*failed [1-9][0-9]*" "$LOG" && fail "a [VK] failed counter is nonzero (log $LOG)"

# a real generation: the line exists and carries words
TXT=$(grep -m1 "^generated_text=" "$LOG" | cut -d= -f2-)
[ -n "$TXT" ] || fail "no generated_text line (log $LOG)"
WORDS=$(echo "$TXT" | wc -w)
[ "$WORDS" -ge 3 ] || fail "generated_text is not coherent text ($WORDS words: '$TXT')"
echo "deepseek-v4-smoke: PASS (${WORDS} words: $(echo "$TXT" | cut -c1-72)...)"
exit 0
