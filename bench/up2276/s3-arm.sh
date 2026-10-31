#!/bin/bash
# s3-arm.sh — one S3-window arm with the settle-to-floor discipline (the S1 teardown-race
# lesson, AA §6): wait the card back to the exact idle floor (541057024 B) before the
# launch, refuse to proceed if it does not settle within 300 s.
# Usage: s3-arm.sh <tag> [extra env assignments...]
set -u
TAG=$1; shift
FLOOR=541057024
V=/sys/class/drm/card2/device/mem_info_vram_used

# settle to the floor (the scope teardown of the previous arm can hold VRAM briefly)
for i in $(seq 1 150); do
  v=$(cat "$V" 2>/dev/null || echo 0)
  [ "$v" = "$FLOOR" ] && break
  sleep 2
done
v=$(cat "$V")
if [ "$v" != "$FLOOR" ]; then
  echo "$TAG: REFUSED — vram did not settle to the floor ($v B after 300 s)" >&2
  exit 2
fi
if fuser /dev/dri/renderD128 /dev/dri/renderD129 >/dev/null 2>&1; then
  echo "$TAG: REFUSED — /dev/dri holders present" >&2
  exit 2
fi
echo "$TAG: vram0=$(cat $V) B at the floor, no /dev/dri holders — launching $(date +%H:%M:%S)"

VRAM_MAX_USED_MB=2600 /root/bench-worktrees/up2276-merge/bench/up2276/run-arm2276.sh \
  /root/bench-worktrees/up2276-merge/c "$TAG" "$@"
echo "$TAG: rc-line above; vram after settle-wait: $(cat $V) B"
