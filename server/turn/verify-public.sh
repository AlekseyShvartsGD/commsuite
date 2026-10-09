#!/bin/sh
# Verify the PUBLIC CloudPub TURN-over-TCP endpoint (run in WSL).
# NOTE: HTTP/WS signaling no longer uses this tunnel (CloudPub blackholes HTTP in
# tcp tunnels) - it travels via the separate https://...cloudpub.ru endpoint.
# usage: bash verify-public.sh tcp.cloudpub.ru 20653
HOST="${1:-tcp.cloudpub.ru}"
PORT="${2:-20653}"

echo "public TURN-over-TCP via tunnel:"
cd /mnt/c/Users/aleks/Desktop/alekz/server || exit 1
TURN_HOST="$HOST" TURN_PORT="$PORT" node test/turn_smoke.js 2>&1 | tail -2