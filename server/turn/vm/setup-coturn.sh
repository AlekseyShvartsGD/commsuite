#!/usr/bin/env bash
# Commsuite TURN relay for a public-IP cloud VM (Ubuntu 22.04 / 24.04).
#
# Unlike the WSL2 setup (coturn + mux.js + a single CloudPub raw-TCP tunnel),
# here the VM has a real public IP, so coturn is reachable DIRECTLY on 3478
# (UDP + TCP) with no tunnel. Peers therefore receive a relay address they can
# actually reach, and calls connect even behind carrier-grade NAT, symmetric
# NAT, or an emulator whose UDP is filtered (BlueStacks).
#
# Signaling is untouched: it keeps running wherever it already is; this VM only
# relays media.
#
# Usage (on the VM, as root):
#     sudo bash setup-coturn.sh [PUBLIC_IP] [PRIVATE_IP]
#
# PUBLIC_IP defaults to the internet-facing address (auto-detected via
# ipify.org); PRIVATE_IP defaults to the NIC address used for the default route.
# Cloud providers (Oracle, GCP, AWS, Azure) NAT a public IP onto a private NIC,
# which is exactly why coturn needs BOTH.
#
# Afterwards, in the app under Settings > TURN:
#     host = <PUBLIC_IP>   port = 3478   user = commsuite   pass = commsuite-1
set -euo pipefail

TURN_USER="${TURN_USER:-commsuite}"
TURN_PASS="${TURN_PASS:-commsuite-1}"
TURN_REALM="${TURN_REALM:-commsuite.local}"
MIN_PORT="${TURN_MIN_PORT:-49152}"
MAX_PORT="${TURN_MAX_PORT:-65535}"

PUBLIC_IP="${1:-}"
PRIVATE_IP="${2:-}"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org || true)"
[ -n "$PRIVATE_IP" ] || PRIVATE_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"

if [ -z "$PUBLIC_IP" ] || [ -z "$PRIVATE_IP" ]; then
  echo "Could not detect PUBLIC_IP/PRIVATE_IP." >&2
  echo "Pass them explicitly: sudo bash setup-coturn.sh <public-ip> <private-ip>" >&2
  exit 1
fi

echo "==> Installing coturn (public=$PUBLIC_IP private=$PRIVATE_IP)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y coturn curl

echo "==> Writing /etc/turnserver.conf"
cat >/etc/turnserver.conf <<EOF
listening-port=3478
listening-ip=0.0.0.0
# A public IP is NAT'd onto a private NIC address, so coturn must advertise the
# pair (<private>/<public>) or peers are handed an unreachable relay address.
external-ip=$PRIVATE_IP/$PUBLIC_IP
relay-threads=1
lt-cred-mech
user=$TURN_USER:$TURN_PASS
realm=$TURN_REALM
min-port=$MIN_PORT
max-port=$MAX_PORT
fingerprint
no-tls
no-dtls
no-cli
verbose
log-file=/var/log/coturn/commsuite-turn.log
EOF

mkdir -p /var/log/coturn

# coturn is disabled until the Debian wrapper is told to run it.
if [ -f /etc/default/coturn ]; then
  sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
else
  echo 'TURNSERVER_ENABLED=1' >/etc/default/coturn
fi

echo "==> Opening the local firewall"
# ufw, when it is the active manager.
if command -v ufw >/dev/null 2>&1; then
  ufw allow 3478/tcp >/dev/null 2>&1 || true
  ufw allow 3478/udp >/dev/null 2>&1 || true
  ufw allow "$MIN_PORT:$MAX_PORT/udp" >/dev/null 2>&1 || true
fi

# Oracle Cloud Ubuntu images ship a restrictive iptables ruleset (SSH only).
# Insert ACCEPT rules ahead of the REJECT and persist them across reboots.
if [ -f /etc/iptables/rules.v4 ] && command -v iptables >/dev/null 2>&1; then
  iptables -I INPUT 5 -p tcp --dport 3478 -j ACCEPT || true
  iptables -I INPUT 5 -p udp --dport 3478 -j ACCEPT || true
  iptables -I INPUT 5 -p udp --dport "$MIN_PORT:$MAX_PORT" -j ACCEPT || true
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
fi

echo "==> Starting coturn"
systemctl enable coturn >/dev/null 2>&1 || true
systemctl restart coturn
sleep 1

if systemctl is-active --quiet coturn; then
  echo "    coturn is running."
else
  echo "coturn failed to start. See: journalctl -u coturn -n 50" >&2
  exit 1
fi

cat <<INFO

Done.

IMPORTANT - also open these IN THE CLOUD CONSOLE (Security List / Firewall /
Security Group), source 0.0.0.0/0:
    3478/tcp
    3478/udp
    $MIN_PORT-$MAX_PORT/udp

Then in the app > Settings > TURN:
    host = $PUBLIC_IP
    port = 3478
    user = $TURN_USER
    pass = $TURN_PASS

Verify the TCP relay path from any machine with Node (uses server/test/turn_smoke.js):
    TURN_HOST=$PUBLIC_IP TURN_PORT=3478 TURN_USER=$TURN_USER TURN_PASS=$TURN_PASS \\
      node server/test/turn_smoke.js
INFO
