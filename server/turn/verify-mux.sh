#!/bin/sh
# Verify the protocol multiplexer routes HTTP and TURN correctly (run in WSL).
set -e
cd /mnt/c/Users/aleks/Desktop/alekz/server || exit 1

echo "1) HTTP via mux:"
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:7777/api/auth/me || true)
echo "   GET /api/auth/me -> $CODE  (expect 401 = routed to node)"

echo "2) TURN-over-TCP via mux:"
TURN_HOST=127.0.0.1 TURN_PORT=7777 node test/turn_smoke.js 2>&1 | tail -2

echo "3) direct coturn still OK:"
TURN_HOST=127.0.0.1 TURN_PORT=3478 node test/turn_smoke.js 2>&1 | tail -2