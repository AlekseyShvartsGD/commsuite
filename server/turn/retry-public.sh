#!/bin/sh
# Retry the public HTTP path a few times (diagnosis).
HOST="${1:-tcp.cloudpub.ru}"
PORT="${2:-17113}"
for i in 1 2 3; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 25 "http://$HOST:$PORT/api/auth/me" 2>/dev/null)
  echo "attempt $i: $CODE"
  [ "$CODE" = "401" ] && break
  sleep 2
done