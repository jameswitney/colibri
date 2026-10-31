#!/bin/bash
set -u
R=/root/bench-colibri/run-arm2276.sh
$R /root/bench-worktrees/up2276-merge/c merge-t5-bigchunk-r1 COLI_VK_CHAIN_GEMM_ROWS=-1 COLI_VK_TIER_GEMM_ROWS=4 COLI_VK_TIER_STREAM_SLOTS=160 COLI_VK_TIER_GB=5
$R /root/bench-worktrees/up2276-merge/c merge-t6-midchunk-r1 COLI_VK_CHAIN_GEMM_ROWS=-1 COLI_VK_TIER_GEMM_ROWS=4 COLI_VK_TIER_STREAM_SLOTS=192 COLI_VK_TIER_GB=6
echo DONE7 >> /root/bench-colibri/up2276/summary.txt
