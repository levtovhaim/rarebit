#!/usr/bin/env bash
# Smoke test for the validator image, run the way Kubernetes runs it: non-root, read-only root
# filesystem, no capabilities. Checks the image contract (apps/validator/Dockerfile), then
# migrate, serve, one validation, check-ready and a SIGTERM drain against a throwaway Postgres.
#
#   bash image-smoke.sh <image> <postgres-image>      (make validator-image-smoke)
#
# Needs Docker and curl. Leaves no containers or networks behind.
set -euo pipefail

usage="usage: bash image-smoke.sh <image> <postgres-image>"
image="${1:?$usage}"
postgres="${2:?$usage}"
max_mb="${MAX_IMAGE_MB:-45}" # unpacked
id="rarebit-smoke-$$"
hardened=(--read-only --cap-drop ALL --security-opt no-new-privileges)
# shellcheck source=apps/validator/test/pg.sh
. "$(dirname "$0")/pg.sh"

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
logs() { docker logs "${id}-serve" 2>&1 | tail -n 5; }

# The image itself.
user="$(docker image inspect -f '{{.Config.User}}' "$image")"
[[ "$user" =~ ^[1-9][0-9]*(:[0-9]+)?$ ]] ||
  fail "the image's user must be a numeric non-root uid (runAsNonRoot can't check a name): \"$user\""
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
privileged="$(awk '$1 ~ /^-..[sS]/ || $1 ~ /^-.....[sS]/ {print $NF}' <<<"$listing")"
[ -z "$privileged" ] || fail "setuid or setgid files: $privileged"
pass "no world-writable, setuid or setgid files"
if docker run --rm --entrypoint sh "$image" -c true >/dev/null 2>&1; then
  fail "the image has a shell"
fi
pass "no shell"
version="$(docker run --rm "${hardened[@]}" "$image" version)"
revision="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")"
case "$version" in
  "" | unknown) fail "version printed \"$version\": is GIT_SHA wired to -X main.version?" ;;
esac
[ "$version" = "$revision" ] || fail "version $version doesn't match the image's revision label \"$revision\""
pass "version $version, the same as the revision label"
if docker run --rm "${hardened[@]}" "$image" check-ready >/dev/null 2>&1; then
  fail "check-ready succeeded with no server running"
fi
pass "check-ready fails when nothing is serving"

# A throwaway Postgres on a private network. The URL holds the password, so it goes to the
# containers by name (-e DATABASE_URL), not on docker's command line.
docker network create "$id" >/dev/null
pg_start "${id}-db" "$postgres" "$id" || fail "Postgres didn't start"
export DATABASE_URL="postgres://postgres:${PG_PASSWORD}@${id}-db:5432/postgres?sslmode=disable"

# migrate, twice: the word lists come from the image.
run=(docker run --rm "${hardened[@]}" --network "$id" -e DATABASE_URL "$image")
first="$("${run[@]}" migrate)"
grep -q '"content_changed":true' <<<"$first" || fail "first migrate: $first"
second="$("${run[@]}" migrate)"
grep -q '"migrations_applied":0,"content_changed":false' <<<"$second" || fail "second migrate: $second"
pass "migrate loads the word lists from the image; a rerun changes nothing"

# serve, one answer, check-ready, then SIGTERM.
docker run -d --name "${id}-serve" "${hardened[@]}" --network "$id" -p 127.0.0.1::8080 \
  -e DATABASE_URL -e VALIDATOR_DRAIN_DELAY=1s "$image" serve >/dev/null
port="$(docker port "${id}-serve" 8080/tcp | head -n1 | sed 's/.*://')"
api="http://127.0.0.1:$port"
for _ in $(seq 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$api/readyz")" = 200 ] && break
  sleep 0.25
done
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$api/readyz")"
[ "$code" = 200 ] || fail "/readyz returned $code, never 200: $(logs)"
# The body goes in as bytes on stdin: on Windows, an argument with Hebrew in it gets re-encoded.
body='{"category":"country","letter":"י","answer":"ישראל"}'
answer="$(printf '%s' "$body" | curl -s --max-time 5 -w '\n%{http_code}' -H 'Content-Type: application/json' \
  --data-binary @- "$api/v1/validate")"
if [ "${answer##*$'\n'}" != 200 ] || ! grep -q '"result":"valid"' <<<"$answer"; then
  fail "validate: $answer"
fi
pass "serve is ready and validates an answer"
docker exec "${id}-serve" /validator check-ready || fail "check-ready inside the container: $(logs)"
pass "check-ready succeeds inside the running container"
docker stop -t 30 "${id}-serve" >/dev/null
code="$(docker inspect -f '{{.State.ExitCode}}' "${id}-serve")"
[ "$code" = 0 ] || fail "serve exited $code on SIGTERM: $(logs)"
docker logs "${id}-serve" 2>&1 | grep -q '"msg":"stopped"' || fail "no clean drain in the log"
pass "SIGTERM: drained and exited 0"
echo "image smoke test passed: $image"
