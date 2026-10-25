#!/bin/bash
# w2-run.sh — the W2 window's driver: 4 arms x3 strict round-robin (c0 -> gf -> full
# -> ring, the W1 interleaving discipline), then one DPROF rep each of FULL and RING
# (COLI_VK_CHAIN_DPROF=1 COLI_VK_CHAIN_PROF=2 — B's STAGE/MOEH/A1 bucket reads).
# Every leg is w2-arm.sh (the settle discipline) and is verified before the next:
# rc=0 in the leg's log AND the summary's parse line present. Anything else stops
# the window (a dead model-scale leg is the P0 class — stop and report, never ride).
set -u
cd /root/bench-worktrees/up2276-merge/bench/up2276
OUT=/root/bench-colibri/up2276
BASE="COLI_VK_PROFILE=RDNA2 COLI_VK_TIER_STREAM_BYPASS=1 COLI_VK_TIER_HOST_GB=4 COLI_VK_CHAIN_ROWS_MAX=2048"
GF="COLI_VK_TIER_DECODE_GROW=1 COLI_VK_CHAIN_ATTN_FA=1"
FULL="COLI_VK_CHAIN_MHC_S1=1 COLI_VK_TIER_STREAM_RING=1"
DPROF="COLI_VK_CHAIN_DPROF=1 COLI_VK_CHAIN_PROF=2"

leg () {   # leg <tag> <envs...>
  TAG=$1; shift
  ./w2-arm.sh "$TAG" "$@" || { echo "W2-STOP $TAG: arm refused/failed rc=$?"; exit 9; }
  if ! grep -q "^rc=0 $TAG" "$OUT/$TAG.log"; then
    echo "W2-STOP $TAG: engine rc != 0"; exit 9
  fi
  if [ "$(tail -1 "$OUT/summary.txt")" = "PARSE-FAIL" ]; then
    echo "W2-STOP $TAG: PARSE-FAIL"; exit 9
  fi
  echo "W2-OK $TAG: $(tail -1 "$OUT/summary.txt")"
}

for r in 1 2 3; do
  leg w2-c0-r$r   $BASE
  leg w2-gf-r$r   $BASE $GF
  leg w2-full-r$r $BASE $GF $FULL
  leg w2-ring-r$r $BASE COLI_VK_TIER_STREAM_RING=1
done
leg w2-full-dprof-r1 $BASE $GF $FULL $DPROF
leg w2-ring-dprof-r1 $BASE COLI_VK_TIER_STREAM_RING=1 $DPROF
echo "W2-WINDOW-DONE $(date +%H:%M:%S)"
