#!/usr/bin/env bash
# Smoke test for the validator image, run the way Kubernetes runs it: non-root, read-only root
# filesystem, no capabilities. Checks the image contract (apps/validator/Dockerfile), then
# migrate, serve, one validation and a SIGTERM drain against a throwaway Postgres.
#
#   image-smoke.sh <image> <postgres-image>      (make validator-image-smoke)
#
# Needs Docker and curl. Leaves no containers or networks behind.
set -euo pipefail

image="$1"
postgres="$2"
max_mb="${MAX_IMAGE_MB:-45}" # unpacked
id="rarebit-smoke-$$"
pw="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
url="postgres://postgres:${pw}@${id}-db:5432/postgres?sslmode=disable"
hardened=(--read-only --cap-drop ALL --security-opt no-new-privileges)

cleanup() {
  docker rm -f "${id}-files" "${id}-db" "${id}-serve" >/dev/null 2>&1 || true
  docker network rm "$id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
pass() { echo "ok    $*"; }

# The image itself.
user="$(docker image inspect -f '{{.Config.User}}' "$image")"
case "$user" in
  "" | 0 | 0:* | root | root:*) fail "the image runs as root (User=\"$user\")" ;;
esac
pass "runs as user $user"
# The file listing, from an export: the same on every Docker storage backend, unlike the
# image's reported size (compressed on some, unpacked on others).
docker create --name "${id}-files" "$image" >/dev/null
listing="$(docker export "${id}-files" | tar -tv)"
docker rm "${id}-files" >/dev/null
size_mb="$(awk '{s += $3} END {printf "%d", s / 1000000}' <<<"$listing")"
[ "$size_mb" -le "$max_mb" ] || fail "the image is $size_mb MB unpacked, over the $max_mb MB limit"
pass "$size_mb MB unpacked (limit $max_mb MB)"
writable="$(awk '$1 ~ /^-.......w/ {print $NF}' <<<"$listing")"
[ -z "$writable" ] || fail "world-writable files: $writable"
pass "no world-writable files"
if docker run --rm --entrypoint sh "$image" -c true >/dev/null 2>&1; then
  fail "the image has a shell"
fi
pass "no shell"
version="$(docker run --rm "${hardened[@]}" "$image" version)"
case "$version" in
  "" | unknown) fail "version printed \"$version\": is GIT_SHA wired to -X main.version?" ;;
esac
pass "version $version"

# A throwaway Postgres on a private network.
docker network create "$id" >/dev/null
docker run -d --name "${id}-db" --network "$id" -e POSTGRES_PASSWORD="$pw" "$postgres" >/dev/null
for _ in $(seq 60); do
  docker exec "${id}-db" pg_isready -q -h 127.0.0.1 -U postgres && break
  sleep 1
done
docker exec "${id}-db" pg_isready -q -h 127.0.0.1 -U postgres || fail "Postgres didn't start"

# migrate, twice: the word lists come from the image.
run=(docker run --rm "${hardened[@]}" --network "$id" -e DATABASE_URL="$url" "$image")
first="$("${run[@]}" migrate)"
grep -q '"content_changed":true' <<<"$first" || fail "first migrate: $first"
second="$("${run[@]}" migrate)"
grep -q '"migrations_applied":0,"content_changed":false' <<<"$second" || fail "second migrate: $second"
pass "migrate loads the word lists from the image; a rerun changes nothing"

# serve, one answer, then SIGTERM.
docker run -d --name "${id}-serve" "${hardened[@]}" --network "$id" -p 127.0.0.1::8080 \
  -e DATABASE_URL="$url" -e VALIDATOR_DRAIN_DELAY=1s "$image" serve >/dev/null
port="$(docker port "${id}-serve" 8080/tcp | head -n1 | sed 's/.*://')"
api="http://127.0.0.1:$port"
for _ in $(seq 40); do
  curl -fsS "$api/readyz" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fsS "$api/readyz" >/dev/null 2>&1 || fail "/readyz never returned 200: $(docker logs "${id}-serve" 2>&1 | tail -n 5)"
answer="$(curl -fsS -X POST "$api/v1/validate" -d '{"category":"country","letter":"י","answer":"ישראל"}')"
grep -q '"result":"valid"' <<<"$answer" || fail "validate: $answer"
pass "serve is ready and validates an answer"
docker stop -t 30 "${id}-serve" >/dev/null
code="$(docker inspect -f '{{.State.ExitCode}}' "${id}-serve")"
[ "$code" = 0 ] || fail "serve exited $code on SIGTERM: $(docker logs "${id}-serve" 2>&1 | tail -n 5)"
docker logs "${id}-serve" 2>&1 | grep -q '"msg":"stopped"' || fail "no clean drain in the log"
pass "SIGTERM: drained and exited 0"
echo "image smoke test passed: $image"
