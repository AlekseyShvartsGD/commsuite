#!/usr/bin/env bash
# Starts only the coturn TURN relay (inside WSL2), no server/tunnels.
set -u
BASE="/mnt/c/Users/aleks/Desktop/alekz"
LOG_DIR="${TMPDIR:-/tmp}/commsuite-logs"
mkdir -p "$LOG_DIR"
pkill -x turnserver 2>/dev/null && sleep 1 || true
nohup /usr/bin/turnserver -c "$BASE/server/turn/turnserver.conf" >>"$LOG_DIR/turn.log" 2>&1 &
sleep 1
pgrep -x turnserver >/dev/null && echo "turnserver up on 127.0.0.1:3478" || echo "WARNING: turnserver failed (see $LOG_DIR/turn.log)"