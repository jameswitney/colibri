#!/bin/bash
# ab2.sh — day-2 A/B: old fork (port-source-2026-10-19) vs port/up-2276
# Interleaved, same controls as run-arm2276.sh / ab-forks.sh.
set -u
R=/root/bench-colibri/run-arm2276.sh
FORK_ENV="COLI_DSV4_VK_DENSE=1 COLI_DSV4_VK_EXPERTS=1 COLI_V4_DIRECT=1"
$R /root/bench-worktrees/fork-ab/c fork-r1 $FORK_ENV
$R /root/bench-worktrees/up2276-merge/c merge-default-r2
$R /root/bench-worktrees/fork-ab/c fork-r2 $FORK_ENV
$R /root/bench-worktrees/up2276-merge/c merge-gemm-r2 COLI_VK_CHAIN_GEMM_ROWS=-1
echo "AB2 DONE" >> /root/bench-colibri/up2276/summary.txt
