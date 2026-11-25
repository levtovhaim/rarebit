#!/usr/bin/env bash
# Smoke test for the game image, run the way Kubernetes runs it: non-root, read-only root
# filesystem, no capabilities. Checks the image contract (apps/game/Dockerfile), then a bad
# config, the endpoints, one game action over Socket.IO and a SIGTERM drain against a throwaway
# Redis.
#
#   bash image-smoke.sh <image> <redis-image>      (make game-image-smoke)
#
# Needs Docker, curl, and Node with apps/game's dev dependencies installed (make game), for the
# Socket.IO client. Leaves no containers or networks behind.
set -euo pipefail

usage="usage: bash image-smoke.sh <image> <redis-image>"
image="${1:?$usage}"
redis="${2:?$usage}"
max_mb="${MAX_IMAGE_MB:-230}" # unpacked (apps/game/Dockerfile says why)
here="$(cd "$(dirname "$0")" && pwd)"
id="rarebit-game-smoke-$$"
hardened=(--read-only --cap-drop ALL --security-opt no-new-privileges)

cleanup() {
  docker rm -fv "${id}-files" "${id}-redis" "${id}-serve" "${id}-config" >/dev/null 2>&1 || true
  docker network rm "$id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
pass() { echo "ok    $*"; }
logs() { docker logs "${id}-serve" 2>&1 | tail -n 5; }

[ -d "$here/../node_modules/socket.io-client" ] || fail "apps/game/node_modules is missing: run make game first"

# The image itself.
user="$(docker image inspect -f '{{.Config.User}}' "$image")"
[[ "$user" =~ ^[1-9][0-9]*(:[0-9]+)?$ ]] ||
  fail "the image's user must be a numeric non-root uid (runAsNonRoot can't check a name): \"$user\""
pass "runs as user $user"
# The file listing, from an export: the same on every Docker storage backend, unlike the
# image's reported size (compressed on some, unpacked on others).
docker create --name "${id}-files" "$image" >/dev/null
listing="$(docker export "${id}-files" | tar -tv)"
docker rm -v "${id}-files" >/dev/null
size_mb="$(awk '{s += $3} END {printf "%d", s / 1000000}' <<<"$listing")"
[ "$size_mb" -le "$max_mb" ] || fail "the image is $size_mb MB unpacked, over the $max_mb MB limit"
pass "$size_mb MB unpacked (limit $max_mb MB)"
writable="$(awk '$1 ~ /^-.......w/ {print $NF}' <<<"$listing")"
[ -z "$writable" ] || fail "world-writable files: $writable"
privileged="$(awk '$1 ~ /^-..[sS]/ || $1 ~ /^-.....[sS]/ {print $NF}' <<<"$listing")"
[ -z "$privileged" ] || fail "setuid or setgid files: $privileged"
pass "no world-writable, setuid or setgid files"
for dev in typescript vitest socket.io-client; do
  ! grep -q "node_modules/$dev/package.json$" <<<"$listing" || fail "a dev dependency is in the image: $dev"
done
grep -q "node_modules/socket.io/package.json$" <<<"$listing" || fail "socket.io is missing from the image"
pass "production dependencies only"
if docker run --rm --entrypoint sh "$image" -c true >/dev/null 2>&1; then
  fail "the image has a shell"
fi
pass "no shell"
check_ready=(/nodejs/bin/node /app/dist/check-ready.js)
if docker run --rm "${hardened[@]}" --entrypoint "${check_ready[0]}" "$image" "${check_ready[1]}" >/dev/null 2>&1; then
  fail "check-ready succeeded with no server running"
fi
pass "check-ready fails when nothing is serving"

# A bad config: exit 1, the problem listed, the values never printed.
set +e
out="$(docker run --name "${id}-config" "${hardened[@]}" -e REDIS_URL='redis://user:s3cret-pw@nowhere:6379' \
  -e VALIDATOR_URL=http://127.0.0.1:1 "$image" 2>&1)"
code=$?
set -e
[ "$code" = 1 ] || fail "a missing ALLOWED_ORIGINS exited $code, not 1: $out"
grep -q '"msg":"invalid configuration"' <<<"$out" || fail "no invalid-configuration log line: $out"
grep -q 'ALLOWED_ORIGINS' <<<"$out" || fail "the log doesn't name ALLOWED_ORIGINS: $out"
! grep -q 's3cret-pw' <<<"$out" || fail "the log printed a value from the environment"
pass "a bad config exits 1, naming the setting and not its value"

# A throwaway Redis on a private network.
docker network create "$id" >/dev/null
docker run -d --name "${id}-redis" --network "$id" "$redis" >/dev/null
for _ in $(seq 30); do docker exec "${id}-redis" redis-cli ping 2>/dev/null | grep -q PONG && break; sleep 0.5; done

# Serve: ready, the endpoints, one game action, then SIGTERM.
docker run -d --name "${id}-serve" "${hardened[@]}" --network "$id" -p 127.0.0.1::8080 \
  -e REDIS_URL="redis://${id}-redis:6379" -e VALIDATOR_URL=http://127.0.0.1:1 -e ALLOWED_ORIGINS='*' \
  -e DRAIN_DELAY_SECONDS=1 "$image" >/dev/null
port="$(docker port "${id}-serve" 8080/tcp | head -n1 | sed 's/.*://')"
api="http://127.0.0.1:$port"
for _ in $(seq 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$api/readyz")" = 200 ] && break
  sleep 0.25
done
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$api/readyz")"
[ "$code" = 200 ] || fail "/readyz returned $code, never 200: $(logs)"
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$api/healthz")" = 200 ] || fail "/healthz isn't 200"
pass "ready (a write to Redis succeeds) and live"
revision="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")"
version="$(curl -s --max-time 2 "$api/version")"
case "$version" in
  *'"version":"unknown"'* | "") fail "/version: $version (is GIT_SHA set in the image?)" ;;
esac
grep -q "\"version\":\"$revision\"" <<<"$version" || fail "/version $version doesn't match the revision label \"$revision\""
pass "/version reports $revision, the same as the revision label"
curl -s --max-time 2 "$api/metrics" | grep -q '^game_draining 0' || fail "/metrics has no game_draining 0"
pass "/metrics"
action="$(cd "$here/.." && node test/smoke-client.ts "$api")" || fail "the game action failed: $(logs)"
pass "a room created and read back over Socket.IO: $action"
docker exec "${id}-serve" "${check_ready[@]}" || fail "check-ready inside the running container: $(logs)"
pass "check-ready succeeds inside the running container"
procs="$(docker top "${id}-serve" -o pid,args | tail -n +2)"
[ "$(wc -l <<<"$procs")" = 1 ] || fail "more than one process in the container: $procs"
grep -q 'node' <<<"$procs" || fail "the container's process isn't node: $procs"
pass "one process, node itself: $(awk '{$1=""; print substr($0, 2)}' <<<"$procs")"
started="$(date +%s)"
docker stop -t 30 "${id}-serve" >/dev/null
took=$(($(date +%s) - started))
code="$(docker inspect -f '{{.State.ExitCode}}' "${id}-serve")"
[ "$code" = 0 ] || fail "serve exited $code on SIGTERM: $(logs)"
docker logs "${id}-serve" 2>&1 | grep -q '"msg":"stopped"' || fail "no clean drain in the log"
[ "$took" -lt 10 ] || fail "the drain took ${took} s (expected about 2 s with a 1 s drain delay)"
nonjson="$(docker logs "${id}-serve" 2>&1 | grep -vc '^{' || true)"
[ "$nonjson" = 0 ] || fail "$nonjson log lines aren't JSON"
pass "SIGTERM: drained and exited 0 in ${took} s; every log line is JSON"
echo "image smoke test passed: $image"
