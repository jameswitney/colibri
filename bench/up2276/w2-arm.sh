#!/bin/bash
# w2-arm.sh — one W2-window arm, the settle discipline carried from W1 (AI-pw-w1 §0)
# unchanged: the post-event stable idle baseline 592 031 744 B (+48.6 MiB over the
# historical 541 057 024 floor, itself unreachable this session), the +16 MiB
# tolerance, the /dev/dri holder refusal, VRAM_MAX_USED_MB=2600, the frozen
# usage/MFU snapshots per leg (run-arm2276.sh's own protocol).
# Usage: w2-arm.sh <tag> [extra env assignments...]
set -u
TAG=$1; shift
V=/sys/class/drm/card2/device/mem_info_vram_used
BASE=592031744
TOL=$((16*1024*1024))

for i in $(seq 1 150); do
  v=$(cat "$V" 2>/dev/null || echo 0)
  [ "$v" -le $((BASE+TOL)) ] && break
  sleep 2
done
v=$(cat "$V")
if [ "$v" -gt $((BASE+TOL)) ]; then
  echo "$TAG: REFUSED — residue grew: $v B > baseline $BASE B + $TOL B after 300 s" >&2
  exit 2
fi
if fuser /dev/dri/renderD128 /dev/dri/renderD129 >/dev/null 2>&1; then
  echo "$TAG: REFUSED — /dev/dri holders present" >&2
  exit 2
fi
echo "$TAG: vram0=$v B (baseline $BASE B) — launching $(date +%H:%M:%S)"

VRAM_MAX_USED_MB=2600 /root/bench-worktrees/up2276-merge/bench/up2276/run-arm2276.sh \
  /root/bench-worktrees/up2276-merge/c "$TAG" "$@"
echo "$TAG: rc-line above; vram after settle-wait: $(cat $V) B"
