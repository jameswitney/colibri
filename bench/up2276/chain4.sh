#!/bin/bash
set -u
R=/root/bench-colibri/run-arm2276.sh
RAM_GB=24 $R /root/bench-worktrees/up2276-merge/c merge-all2-r1 COLI_VK_CHAIN_GEMM_ROWS=-1 COLI_VK_TIER_GEMM_ROWS=4 COLI_VK_TIER_STREAM_SLOTS=192 COLI_VK_TIER_HOST_GB=5 COLI_VK_TIER_PROMOTE=32
echo DONE4 >> /root/bench-colibri/up2276/summary.txt
