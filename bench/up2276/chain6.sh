#!/bin/bash
# The GPU-FOLD attribution series: fork full / fork without its expert fold / new fork.
set -u
R=/root/bench-colibri/run-arm2276.sh
F="COLI_DSV4_VK_DENSE=1 COLI_V4_DIRECT=1"
$R /root/bench-worktrees/fork-ab/c           fork-full-r3        COLI_DSV4_VK_EXPERTS=1 $F
$R /root/bench-worktrees/up2276-merge/c      new-s256gr4-r2      COLI_VK_CHAIN_GEMM_ROWS=-1 COLI_VK_TIER_GEMM_ROWS=4 COLI_VK_TIER_STREAM_SLOTS=256
$R /root/bench-worktrees/fork-ab/c           fork-noexperts-r1   COLI_DSV4_VK_EXPERTS=0 $F
$R /root/bench-worktrees/fork-ab/c           fork-full-r4        COLI_DSV4_VK_EXPERTS=1 $F
$R /root/bench-worktrees/up2276-merge/c      new-s256gr4-r3      COLI_VK_CHAIN_GEMM_ROWS=-1 COLI_VK_TIER_GEMM_ROWS=4 COLI_VK_TIER_STREAM_SLOTS=256
$R /root/bench-worktrees/fork-ab/c           fork-noexperts-r2   COLI_DSV4_VK_EXPERTS=0 $F
echo DONE6 >> /root/bench-colibri/up2276/summary.txt
