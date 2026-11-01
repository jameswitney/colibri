#!/bin/bash
# STAGE 3a: fresh build of the PR binary /tmp/selftune/c/deepseek_v4.
# Waits for the in-tree `make check VK=1` (flock /tmp/gpu.lock, started 21:19)
# to fully exit first: two makes in one tree interleave on shared .o files.
LOG=/tmp/selftune/st-build.log
echo "st-build: waiting for in-tree make check (pid 652086) to exit $(date)" >>"$LOG"
tail --pid=652086 -f /dev/null
sleep 5
echo "st-build: make check exited $(date); /tmp/check.log tail: $(tail -1 /tmp/check.log 2>/dev/null)" >>"$LOG"
cd /tmp/selftune/c || { echo "st-build: FAIL cd /tmp/selftune/c" >>"$LOG"; exit 1; }
make -j18 VK=1 deepseek_v4 >>"$LOG" 2>&1
rc=$?
echo "st-build: make -j18 VK=1 deepseek_v4 rc=$rc $(date)" >>"$LOG"
if [ $rc -eq 0 ] && nm deepseek_v4 | grep -q coli_vk; then
  echo "st-build: BINARY-OK $(ls -la deepseek_v4)" >>"$LOG"
else
  echo "st-build: BINARY-CHECK-FAILED" >>"$LOG"
fi
exit $rc
