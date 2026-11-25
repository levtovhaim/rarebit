#!/usr/bin/env bash
# Smoke test for the bots image, run the way Kubernetes runs it: non-root, read-only root
# filesystem, no capabilities. Checks the image contract (apps/bots/Dockerfile), the word lists,
# the default command and the SIGTERM handling. A real game against the image is `make smoke`,
# on the local stack.
#
#   bash image-smoke.sh <image>      (make bots-image-smoke)
#
# Needs Docker. Leaves no containers behind.
set -euo pipefail

image="${1:?usage: bash image-smoke.sh <image>}"
max_mb="${MAX_IMAGE_MB:-200}" # unpacked
id="rarebit-bots-smoke-$$"
hardened=(--read-only --cap-drop ALL --security-opt no-new-privileges)
# Nothing answers there: a connection attempt waits for its timeout, so a run stays busy.
nowhere="http://10.255.255.1:8080"

cleanup() {
  docker rm -fv "${id}-files" "${id}-stop" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
pass() { echo "ok    $*"; }
run() { # runs the image, hardened; prints its output and returns its exit code
  local code=0
  docker run --rm "${hardened[@]}" "$@" 2>&1 || code=$?
  return "$code"
}

# The image itself.
user="$(docker image inspect -f '{{.Config.User}}' "$image")"
[[ "$user" =~ ^[1-9][0-9]*(:[0-9]+)?$ ]] ||
  fail "the image's user must be a numeric non-root uid (runAsNonRoot can't check a name): \"$user\""
pass "runs as user $user"
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
for dev in typescript vitest; do
  ! grep -q "node_modules/$dev/package.json$" <<<"$listing" || fail "a dev dependency is in the image: $dev"
done
grep -q "node_modules/socket.io-client/package.json$" <<<"$listing" || fail "socket.io-client is missing from the image"
pass "production dependencies only"
lists="$(grep -c 'data/categories/[a-z_-]*\.json$' <<<"$listing" || true)"
[ "$lists" -ge 1 ] || fail "no word lists in /data/categories"
pass "$lists word lists in /data/categories"
if docker run --rm --entrypoint sh "$image" -c true >/dev/null 2>&1; then
  fail "the image has a shell"
fi
pass "no shell"

# The default command is synthetic, and the options are checked before anything connects.
revision="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")"
set +e
out="$(run "$image")"
code=$?
set -e
[ "$code" = 2 ] || fail "the image with no options exited $code, not 2: $out"
grep -q -- '--url: required' <<<"$out" || fail "no '--url: required' in: $out"
grep -q "\"version\":\"$revision\"" <<<"$out" || fail "the log's version isn't the revision label \"$revision\": $out"
pass "no options: exit 2, '--url: required', version $revision in the log"

# The word lists load: a game against nothing fails as a game (1), not as unreadable lists (2).
set +e
out="$(run "$image" synthetic --url "$nowhere" --reconnect-give-up 1)"
code=$?
set -e
[ "$code" = 1 ] || fail "synthetic against nothing exited $code, not 1: $(tail -n 3 <<<"$out")"
grep -q '"msg":"summary"' <<<"$out" || fail "no summary line: $(tail -n 3 <<<"$out")"
pass "the word lists load: a game against nothing fails as a game (exit 1, with a summary)"
set +e
out="$(run -e BOTS_WORDS_DIR=/nowhere "$image" synthetic --url "$nowhere")"
code=$?
set -e
[ "$code" = 2 ] || fail "with no word lists the bots exited $code, not 2: $out"
grep -q "can't read the word lists" <<<"$out" || fail "no word-list error in: $out"
pass "without the word lists: exit 2, \"can't read the word lists\""

# SIGTERM: one process, node itself; it stops starting games, prints its summary and exits on its
# own, well before docker stop's grace period would kill it (exit 137).
docker run -d --name "${id}-stop" "${hardened[@]}" "$image" observe --url "$nowhere" --duration 600 >/dev/null
sleep 2
procs="$(docker top "${id}-stop" -o pid,args | tail -n +2)"
if [ "$(wc -l <<<"$procs")" != 1 ] || ! grep -q node <<<"$procs"; then
  fail "not a single node process: $procs"
fi
started="$(date +%s)"
docker stop -t 30 "${id}-stop" >/dev/null
took=$(($(date +%s) - started))
code="$(docker inspect -f '{{.State.ExitCode}}' "${id}-stop")"
logs="$(docker logs "${id}-stop" 2>&1)"
[ "$code" != 137 ] || fail "the bots were killed at the end of the grace period: SIGTERM didn't reach them"
grep -q '"msg":"stopping: no new games"' <<<"$logs" || fail "no 'stopping' line after SIGTERM"
grep -q '"msg":"summary"' <<<"$logs" || fail "no summary after SIGTERM"
[ "$took" -lt 15 ] || fail "stopping took ${took} s"
pass "SIGTERM: one node process; it stopped, printed its summary and exited $code in ${took} s"
echo "image smoke test passed: $image"
