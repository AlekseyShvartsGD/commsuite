#!/bin/sh
CLO=/mnt/c/Users/aleks/Desktop/alekz/tools/cloudpub-linux/clo
printf 'y\ny\ny\n' | $CLO clean >/tmp/commsuite-logs/clo-clean.out 2>&1
echo "--- clean result ---"
tail -2 /tmp/commsuite-logs/clo-clean.out
printf 'y\n' | $CLO register http 3000 >/tmp/clo-reg-http.out 2>&1
printf 'y\n' | $CLO register tcp 7777 >/tmp/clo-reg-tcp.out 2>&1
echo "--- register results ---"
tail -2 /tmp/clo-reg-http.out
tail -2 /tmp/clo-reg-tcp.out
echo "--- registered ---"
$CLO ls 2>&1
echo "--- one agent for all (run) ---"
setsid $CLO run </dev/null >>/tmp/commsuite-logs/clo-run.log 2>&1 &
sleep 10
tail -10 /tmp/commsuite-logs/clo-run.log