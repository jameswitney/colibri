#!/bin/bash
# Chain the remaining benchmark arms sequentially (machine exclusivity).
set -u
R=/root/bench-colibri/run-arm2276.sh
$R /root/bench-worktrees/up2276-merge/c merge-default-r1
$R /root/bench-worktrees/up2276-base/c  base-default-r2
$R /root/bench-worktrees/up2276-merge/c merge-gemm-r1 COLI_VK_CHAIN_GEMM_ROWS=-1
RAM_GB=18 $R /root/bench-worktrees/up2276-base/c  base-18g-r1
RAM_GB=18 $R /root/bench-worktrees/up2276-merge/c merge-18g-r1
echo "ALL ARMS DONE" >> /root/bench-colibri/up2276/summary.txt
