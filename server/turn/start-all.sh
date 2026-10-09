#!/usr/bin/env bash
# Commsuite all-in-one launcher (run inside WSL2 Ubuntu as the normal user):
#   wsl ~/... -- bash /mnt/c/Users/aleks/Desktop/alekz/server/turn/start-all.sh
# Starts: coturn TURN relay (:3478), the Node.js API server (:3000), the
# protocol multiplexer mux.js (:7777), and ONE CloudPub TCP tunnel that
# publishes :7777 -> public tcp.cloudpub.ru.<port>.
#
# CloudPub allows only one live tunnel per account, so HTTP/WebSocket (node)
# and TURN media (coturn) share the public TCP endpoint; mux.js splits the
# stream by sniffing the STUN magic cookie vs HTTP bytes.
#
# Prerequisites (one-time, inside WSL2):
#   sudo apt-get install -y coturn
#   /mnt/c/Users/aleks/Desktop/alekz/tools/cloudpub-linux/clo login   # or: clo set token <TOKEN>
#   cd /mnt/c/Users/aleks/Desktop/alekz/server && npm ci
# NOTE: systemd's coturn.service must be disabled (it launches a second,
# wrong-config coturn on every WSL boot):
#   wsl -d Ubuntu -u root -- systemctl disable --now coturn
set -u

BASE="/mnt/c/Users/aleks/Desktop/alekz"
SERVER_DIR="$BASE/server"
CLO="$BASE/tools/cloudpub-linux/clo"
LOG_DIR="${TMPDIR:-/tmp}/commsuite-logs"
mkdir -p "$LOG_DIR"

# Start the background services fully detached (setsid) so they survive the
# exit of the `wsl ... bash start-all.sh` session (turnserver/clo daemonize
# on their own; node does not).
echo "[1/3] starting TURN relay (coturn) on :3478 ..."
# NOTE: if a previous turnserver was started as root, stop it first from Windows:
#   wsl -d Ubuntu -u root -- pkill -x turnserver
pkill -x turnserver 2>/dev/null && sleep 1 || true
setsid /usr/bin/turnserver -c "$SERVER_DIR/turn/turnserver.conf" \
  </dev/null >>"$LOG_DIR/turn.log" 2>&1 &
sleep 1
pgrep -x turnserver >/dev/null && echo "  turnserver up" || echo "  WARNING: turnserver failed (see $LOG_DIR/turn.log)"

echo "[2/3] starting Node API server :3000 + protocol mux :7777 ..."
pkill -f "node index.js" 2>/dev/null; pkill -f "mux.js" 2>/dev/null; sleep 1
cd "$SERVER_DIR" || exit 1
setsid node index.js </dev/null >>"$LOG_DIR/node.log" 2>&1 &
setsid node "$SERVER_DIR/turn/mux.js" </dev/null >>"$LOG_DIR/mux.log" 2>&1 &
for i in 1 2 3; do
  sleep 1
  ss -ltn | grep -qE ':3000 ' && { echo "  node up"; break; }
  [ "$i" = 3 ] && echo "  WARNING: node not answering yet (see $LOG_DIR/node.log)"
done
ss -ltn | grep -qE ':7777 ' && echo "  mux up" || echo "  WARNING: mux not up (see $LOG_DIR/mux.log)"

echo "[3/3] registering + publishing http:3000 and tcp:7777 via ONE CloudPub agent ..."
pkill -x clo 2>/dev/null; sleep 1
# CloudPub: registers services per account (endpoints stay fixed across re-runs)
# and runs them all from a SINGLE `clo run` agent (separate `clo publish`
# agents would close each other's channels).
if ! "$CLO" ls 2>/dev/null | grep -q 'localhost:3000'; then
  "$CLO" register http 3000 >>"$LOG_DIR/clo-reg.log" 2>&1
fi
if ! "$CLO" ls 2>/dev/null | grep -q 'localhost:7777'; then
  "$CLO" register tcp 7777 >>"$LOG_DIR/clo-reg.log" 2>&1
fi
setsid "$CLO" run </dev/null >>"$LOG_DIR/clo-run.log" 2>&1 &

sleep 3
echo
echo "Public endpoints (grep the log below):"
echo "  Signaling (API + WS): grep -E 'cloudpub.ru' $LOG_DIR/clo-run.log | grep http"
echo "  TURN media (TCP)    : grep -E 'cloudpub.ru' $LOG_DIR/clo-run.log | grep tcp"
echo
echo "App settings ->"
echo "  Server address : https://<host from the http line>"
echo "  TURN host/port : tcp.cloudpub.ru / <port from the tcp line>  (user commsuite / commsuite-1)"
echo
echo "All logs: $LOG_DIR/*.log"
echo "If the tunnel did not start, run '$CLO login' (or 'clo set token') once in WSL, then rerun."