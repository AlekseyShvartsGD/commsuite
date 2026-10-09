#!/bin/sh
# Experiment: bring up the CloudPub HTTP tunnel alongside the live TCP tunnel
# to test whether BOTH can serve at the same time on this account.
setsid /mnt/c/Users/aleks/Desktop/alekz/tools/cloudpub-linux/clo publish http 3000 \
  </dev/null >>/tmp/commsuite-logs/clo-http.log 2>&1 &
echo "started; sleeping..."
sleep 8
echo "--- http log ---"
cat /tmp/commsuite-logs/clo-http.log
echo "--- tcp log tail ---"
tail -1 /tmp/commsuite-logs/clo-tcp.log