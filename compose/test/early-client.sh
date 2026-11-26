#!/usr/bin/env bash
# Drill: a client that connects while the stack is still starting (a browser tab left open across
# `make down` / `make up` reconnects by itself). The moment nginx answers, one WebSocket goes to
# /socket.io/ while the game replicas aren't listening yet, so both refuse it. Once the stack is
# healthy, `make smoke` must still pass: nginx must not hold that early refusal against the
# replicas (compose/README.md → Drills).
#
#   bash compose/test/early-client.sh      (from the repo root, with the tools on PATH: mise)
#
# Recreates the stack (make down, make up), and removes it at the end (make down).
set -euo pipefail

port="${RAREBIT_PORT:-8080}"
log="$(mktemp)"
cleanup() {
  make down >/dev/null 2>&1 || true
  rm -f "$log"
}
trap cleanup EXIT

# Start from nothing. With no stack (and no compose/.env) make down fails; that's fine here.
make down >/dev/null 2>&1 || true
make up >"$log" 2>&1 &
up_pid=$!

early=""
for _ in $(seq 1500); do # up to 150 s for the images and nginx
  if curl -fs --max-time 1 -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null; then
    # The handshake's nonce: 16 random bytes, base64 (RFC 6455).
    nonce="$(head -c 16 /dev/urandom | base64)"
    early="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
      -H "Sec-WebSocket-Key: $nonce" -H "Origin: http://127.0.0.1:$port" \
      "http://127.0.0.1:$port/socket.io/?EIO=4&transport=websocket" || true)"
    break
  fi
  sleep 0.1
done
wait "$up_pid" || {
  echo "FAIL: make up: $(tail -n 5 "$log")" >&2
  exit 1
}
[ -n "$early" ] || {
  echo "FAIL: nginx never answered during make up" >&2
  exit 1
}
# 502: both replicas refused it, which is the case this drill is about. 101: a replica was already
# listening, so the drill didn't test anything this time; say so rather than pass silently.
if [ "$early" != 502 ]; then
  echo "INCONCLUSIVE: the early WebSocket got $early, not 502 (a replica was already listening)" >&2
  exit 2
fi
echo "ok    the early WebSocket got 502: both replicas refused it while starting"
make smoke
echo "drill passed: make smoke after a client connected during startup"
