#!/bin/sh
# Try CloudPub's multi-service agent: register BOTH tunnels, run them via one agent.
CLO=/mnt/c/Users/aleks/Desktop/alekz/tools/cloudpub-linux/clo
$CLO stop publish 2>/dev/null; true
$CLO clean 2>&1 | tail -1
$CLO register http 3000 2>&1 | tail -1
$CLO register tcp 7777 2>&1 | tail -1
echo "--- registered ---"
$CLO ls 2>&1 | tail -5
echo "--- starting agent (run) ---"
setsid $CLO run </dev/null >>/tmp/commsuite-logs/clo-run.log 2>&1 &
sleep 8
echo "--- run log ---"
tail -8 /tmp/commsuite-logs/clo-run.log