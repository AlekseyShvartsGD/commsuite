#!/usr/bin/env bash
# Free public TURN tunnel for Commsuite via serveo.net (SSH, no account).
#
# serveo publishes a random public TCP port that forwards to our local coturn
# TCP listener (localhost:3478). The free anonymous policy is limited: one
# random port, ~10 min per session, max 2 simultaneous connections, ~256 KiB/s.
# This script keeps the tunnel alive by reconnecting whenever the session drops.
#
# Usage:
#   ./serveo-tunnel.sh
#   cat /tmp/commsuite-serveo-port.txt   # current public port
#
# Point the app at: host serveousercontent.com, port <printed>,
# user commsuite, pass commsuite-1.

set -u

PORT_FILE=/tmp/commsuite-serveo-port.txt
LOG_FILE=/tmp/commsuite-serveo.log

while true; do
  # -R 0 asks serveo for a random public port that forwards to local 3478.
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -R 0:localhost:3478 serveo.net > "$LOG_FILE" 2>&1 &
  PID=$!

  PORT=""
  for _ in $(seq 1 20); do
    PORT=$(grep 'Forwarding TCP connections from' "$LOG_FILE" | head -1 \
           | grep -oE ':[0-9]+' | tr -d ':')
    [ -n "$PORT" ] && break
    sleep 1
  done

  [ -n "$PORT" ] && echo "$PORT" > "$PORT_FILE"
  echo "serveo -> localhost:3478 at serveousercontent.com:${PORT:-?}"

  wait "$PID"   # block until the tunnel session dies, then reconnect
  sleep 2
done
