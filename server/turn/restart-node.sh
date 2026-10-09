#!/bin/sh
# Restart ONLY the Node API server and the protocol mux (keeps the CloudPub
# tunnel on the same public port). Run inside WSL by path to avoid
# pkill self-matching the invoking shell:
#   bash /mnt/c/.../server/turn/restart-node.sh
pkill -f "[n]ode index.js" 2>/dev/null
pkill -f "mux.js" 2>/dev/null
sleep 1
cd /mnt/c/Users/aleks/Desktop/alekz/server || exit 1
setsid node index.js </dev/null >>/tmp/commsuite-logs/node.log 2>&1 &
setsid node turn/mux.js </dev/null >>/tmp/commsuite-logs/mux.log 2>&1 &
sleep 2
ss -ltn | grep -qE ':3000 ' && echo "node up (pid $(pgrep -f '[n]ode index.js'))" \
  || { echo "node FAILED; log:"; tail -5 /tmp/commsuite-logs/node.log; }
ss -ltn | grep -qE ':7777 ' && echo "mux  up (pid $(pgrep -f 'mux.js'))" \
  || { echo "mux  FAILED; log:"; tail -5 /tmp/commsuite-logs/mux.log; }