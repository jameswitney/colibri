#!/bin/bash
# w1-arm.sh — one W1-window arm with the settle discipline adapted to this session's
# card state (the W1 record, AI-pw-w1): the historical idle floor 541057024 B was
# unreachable at window open — 1.20 GiB of kernel-held residue (no /dev/dri holders,
# not TTM-evictable under a 3 GiB probe), which the manager's amdgpu reset attempt
# (sysfs read-only in the container — failed, recorded) cleared with a delay. The
# post-event stable idle baseline is 592031744 B (+48.6 MiB over the historical floor,
# the 17:56 fbcon re-creation the best guess). Arms settle to THAT baseline; a residue
# that grows past it by more than 16 MiB after a 300 s wait refuses the launch (stop
# and report — never raise the ceiling twice, the manager's W1 decision rule 4).
# Usage: w1-arm.sh <tag> [extra env assignments...]
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
echo "$TAG: vram0=$v B (baseline $BASE B; the 541057024 B floor unreachable this session, +48.6 MiB residue, manager (b)) — launching $(date +%H:%M:%S)"

VRAM_MAX_USED_MB=2600 /root/bench-worktrees/up2276-merge/bench/up2276/run-arm2276.sh \
  /root/bench-worktrees/up2276-merge/c "$TAG" "$@"
echo "$TAG: rc-line above; vram after settle-wait: $(cat $V) B"
