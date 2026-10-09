#!/bin/sh
# Print the live state of the Commsuite stack (run inside WSL2).
echo "--- processes ---"
pgrep -ax turnserver || echo "  turnserver: NOT running"
pgrep -f "node index.js"      || echo "  node: NOT running"
pgrep -f "mux.js"           || echo "  mux: NOT running"
pgrep -f "clo publish"        || echo "  clo tunnels: NOT running"
echo "--- sockets ---"
ss -ltn | grep -E ':(3000|3478|7777) ' || echo "  none of 3000/3478/7777 listening"
echo "--- public endpoints ---"
grep -hE 'cloudpub.ru' /tmp/commsuite-logs/clo-run.log 2>/dev/null | tail -4
echo "--- last node/mux/turn lines ---"
tail -1 /tmp/commsuite-logs/node.log 2>/dev/null
tail -1 /tmp/commsuite-logs/mux.log 2>/dev/null
tail -1 /tmp/commsuite-logs/turn.log 2>/dev/null