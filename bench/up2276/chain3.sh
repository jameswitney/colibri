#!/bin/bash
set -u
R=/root/bench-colibri/run-arm2276.sh
$R /root/bench-worktrees/up2276-merge/c merge-all-r1 COLI_VK_CHAIN_GEMM_ROWS=-1 COLI_VK_TIER_GEMM_ROWS=4 COLI_VK_TIER_STREAM_SLOTS=192 COLI_VK_TIER_HOST_GB=8 COLI_VK_TIER_PROMOTE=32
$R /root/bench-worktrees/up2276-merge/c merge-s256-gr4-r1 COLI_VK_CHAIN_GEMM_ROWS=-1 COLI_VK_TIER_GEMM_ROWS=4 COLI_VK_TIER_STREAM_SLOTS=256
echo DONE3 >> /root/bench-colibri/up2276/summary.txt
