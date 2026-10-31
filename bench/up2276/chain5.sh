#!/bin/bash
set -u
R=/root/bench-colibri/run-arm2276.sh
$R /root/bench-worktrees/up2276-merge/c merge-s256-gr4-draft4-r1 COLI_VK_CHAIN_GEMM_ROWS=-1 COLI_VK_TIER_GEMM_ROWS=4 COLI_VK_TIER_STREAM_SLOTS=256 V4_DRAFT=4
$R /root/bench-worktrees/up2276-merge/c merge-s256-gr4-mtp4-r1 COLI_VK_CHAIN_GEMM_ROWS=-1 COLI_VK_TIER_GEMM_ROWS=4 COLI_VK_TIER_STREAM_SLOTS=256 V4_MTP=1 V4_DRAFT=4
echo DONE5 >> /root/bench-colibri/up2276/summary.txt
