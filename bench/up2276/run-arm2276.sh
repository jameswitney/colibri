#!/bin/bash
# run-arm2276.sh — one benchmark arm of the 2026-10-21 upstream-tip campaign.
# Mirrors scripts/ab-forks.sh controls (same model, prompt, state snapshot,
# cgroup ceiling, interleaving handled by the caller) but takes the engine dir
# so arms can point at any worktree build.
#
# Usage: run-arm2276.sh <engine-c-dir> <tag> [extra env assignments...]
# Output: /root/bench-colibri/up2276/<tag>.log  (parse line appended to summary)
set -u
DIR=$1; TAG=$2; shift 2
BIN=$DIR/deepseek_v4
MODEL=/root/Projects/colibri-v4-docker/models/DeepSeek-V4-Flash
PROMPT=/root/Projects/colibri-upstream/bench/prompt_2k.txt
USAGE_SNAP=/root/Projects/colibri-upstream/bench/coli_usage.fixed
MFU_SNAP=/root/Projects/colibri-upstream/bench/coli_mfu.fixed
OUT=/root/bench-colibri/up2276
RAM_GB=${RAM_GB:-28}; OMP=16; TOKENS=64
mkdir -p "$OUT"

[ -x "$BIN" ] || { echo "missing $BIN" >&2; exit 2; }
if ! nm "$BIN" 2>/dev/null | grep -q coli_vk; then
  echo "$TAG: refusing a CPU relink (no Vulkan symbols in $BIN)" >&2; exit 1
fi

# same expert-history state before every run
cp "$USAGE_SNAP" "$MODEL/.coli_usage"
[ -f "$MFU_SNAP" ] && cp "$MFU_SNAP" "$MODEL/.coli_mfu" || true
rm -f "$MODEL/.coli_ckpt" 2>/dev/null || true   # no cold-KV restore in perf arms

LOG=$OUT/$TAG.log
systemd-run --scope --quiet --unit=arm2276-$TAG --collect \
  -p MemoryMax=$((RAM_GB + 6))G -p MemorySwapMax=2G \
  env COLI_TEMP=0 KVSAVE=0 V4_PREFIX_CKPT=0 COLI_VULKAN=1 COLI_V4_PREWARM=0 \
      OMP_NUM_THREADS=$OMP OMP_PROC_BIND=close OMP_PLACES=cores \
      "$@" \
  timeout 3600 "$BIN" "$MODEL" --prompt-file "$PROMPT" --max-tokens "$TOKENS" \
      --memory-gb "$RAM_GB" >"$LOG" 2>&1
echo "rc=$? $TAG" >>"$LOG"

awk '
  /time_to_first_token=/ { split($0,a,"time_to_first_token="); split(a[2],b," "); ttft=b[1] }
  /TUNE decode:/         { split($0,c,"TUNE decode:"); n=split(c[2],d," "); toks=d[1]; for(i=1;i<=n;i++) if(d[i]=="in") sec=d[i+1] }
  END {
    if (sec=="" || ttft=="") { print "PARSE-FAIL"; exit }
    dec = (toks-1) / (sec-ttft)
    printf "%.3f %.4f %.3f\n", ttft, dec, sec
  }' "$LOG" | tee -a "$OUT/summary.txt" | sed "s/^/   $TAG  ttft decode wall: /"
