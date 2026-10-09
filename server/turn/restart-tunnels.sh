#!/bin/sh
# Freshen the CloudPub tunnels (keeps node/mux/turnserver running).
# Re-runs the single clo agent; registered endpoints stay the SAME.
pkill -x clo 2>/dev/null
sleep 1
setsid /mnt/c/Users/aleks/Desktop/alekz/tools/cloudpub-linux/clo run \
  </dev/null >>/tmp/commsuite-logs/clo-run.log 2>&1 &
sleep 5
echo "public endpoints:"
grep -hE 'cloudpub.ru' /tmp/commsuite-logs/clo-run.log | tail -4