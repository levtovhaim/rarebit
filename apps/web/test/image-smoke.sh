#!/usr/bin/env bash
# Smoke test for the web UI image, run the way Kubernetes runs it: non-root, read-only root
# filesystem with a tmpfs on /tmp, no capabilities. Checks the image contract (apps/web/Dockerfile):
# the files and their permissions, the runtime contract endpoints, the page and its assets at /
# and under a path prefix, caching and security headers, compression, JSON logs, and a graceful
# stop with a download in flight.
#
#   bash image-smoke.sh <image>      (make web-image-smoke)
#
# Needs Docker and curl. Leaves no containers behind.
set -euo pipefail

image="${1:?usage: bash image-smoke.sh <image>}"
max_mb="${MAX_IMAGE_MB:-64}" # unpacked: the base is 54.5 MB, the UI's files 2.5 MB
id="rarebit-web-smoke-$$"
year=31536000
download=""
slow_conf=""

cleanup() {
  docker rm -fv "${id}-files" "$id" "${id}-slow" >/dev/null 2>&1 || true
  [ -z "$download" ] || rm -f "$download"
  [ -z "$slow_conf" ] || rm -f "$slow_conf"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
pass() { echo "ok    $*"; }

# The image itself.
user="$(docker image inspect -f '{{.Config.User}}' "$image")"
[[ "$user" =~ ^[1-9][0-9]*(:[0-9]+)?$ ]] ||
  fail "the image's user must be a numeric non-root uid (runAsNonRoot can't check a name): \"$user\""
pass "runs as user $user"
stop_signal="$(docker image inspect -f '{{.Config.StopSignal}}' "$image")"
[ "$stop_signal" = SIGQUIT ] || fail "the stop signal is \"$stop_signal\", not SIGQUIT (nginx's graceful stop)"
entrypoint="$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")"
[ "$entrypoint" = '["nginx","-g","daemon off;"]' ] || fail "the entrypoint isn't nginx itself: $entrypoint"
pass "entrypoint nginx (no entrypoint scripts), stop signal SIGQUIT"
docker create --name "${id}-files" "$image" >/dev/null
listing="$(docker export "${id}-files" | tar -tv)"
docker rm -v "${id}-files" >/dev/null
size_mb="$(awk '{s += $3} END {printf "%.1f", s / 1000000}' <<<"$listing")"
awk -v s="$size_mb" -v m="$max_mb" 'BEGIN {exit !(s <= m)}' ||
  fail "the image is $size_mb MB unpacked, over the $max_mb MB limit"
pass "$size_mb MB unpacked (limit $max_mb MB)"
writable="$(awk '$1 ~ /^-.......w/ {print $NF}' <<<"$listing")"
[ -z "$writable" ] || fail "world-writable files: $writable"
privileged="$(awk '$1 ~ /^-..[sS]/ || $1 ~ /^-.....[sS]/ {print $NF}' <<<"$listing")"
[ -z "$privileged" ] || fail "setuid or setgid files: $privileged"
pass "no world-writable, setuid or setgid files in the image"
# The configuration and the UI's files, directories included: root's, and writable by no one else.
served="$(awk '$NF ~ /^(etc\/nginx|srv\/web)(\/|$)/' <<<"$listing")"
[ -n "$served" ] || fail "no etc/nginx or srv/web in the image"
not_root="$(awk '$2 !~ /^(root|0)\/(root|0)$/ {print $2, $NF}' <<<"$served")"
[ -z "$not_root" ] || fail "not owned by root: $not_root"
open="$(awk '$1 ~ /^.....w/ || $1 ~ /^........w/ {print $1, $NF}' <<<"$served")"
[ -z "$open" ] || fail "writable by group or others: $open"
pass "/etc/nginx and /srv/web: root's, writable by no one else ($(wc -l <<<"$served") entries)"
grep -q ' srv/web/index\.html$' <<<"$listing" || fail "no /srv/web/index.html"
grep -q ' srv/web/index\.html\.gz$' <<<"$listing" || fail "index.html isn't precompressed"
! grep -qE ' srv/web/(src/|.*\.tsx?$)' <<<"$listing" || fail "sources in /srv/web"
! grep -qE '(^| )(usr/local/bin/node|opt/yarn)' <<<"$listing" || fail "Node is in the image"
pass "the built files only, precompressed; no sources, no Node"

# Run it, hardened.
revision="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")"
docker run -d --name "$id" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1::8080 -p 127.0.0.1::9113 "$image" >/dev/null
base="http://127.0.0.1:$(docker port "$id" 8080/tcp | head -n1 | sed 's/.*://')"
metrics="http://127.0.0.1:$(docker port "$id" 9113/tcp | head -n1 | sed 's/.*://')"
up=""
for _ in $(seq 50); do
  if curl -fsS --max-time 2 -o /dev/null "$base/healthz" 2>/dev/null; then
    up=1
    break
  fi
  sleep 0.2
done
[ -n "$up" ] || fail "no answer on /healthz after 10 s: $(docker logs "$id" 2>&1 | tail -n 5)"

status="" headers="" body=""
fetch_url() { # fetch_url <url> [curl options]: sets status, headers (lowercase names) and body
  local url="$1" out
  shift
  out="$(mktemp)"
  headers="$(curl -sS --max-time 5 -D - -o "$out" "$@" "$url" | tr -d '\r')" || fail "GET $url: no answer"
  status="$(head -n1 <<<"$headers" | awk '{print $2}')"
  headers="$(tail -n +2 <<<"$headers" | awk -F': ' 'NF > 1 {printf "%s: %s\n", tolower($1), substr($0, length($1) + 3)}')"
  body="$(tr -d '\0' <"$out")" # compared as text only; a gzip body has NUL bytes
  rm -f "$out"
}
fetch() { fetch_url "$base$1" "${@:2}"; } # fetch <path> [curl options], on the UI's port
header() { awk -F': ' -v n="$1" '$1 == n {print substr($0, length($1) + 3)}' <<<"$headers"; }
expect_status() { [ "$status" = "$1" ] || fail "GET $2: status $status, not $1"; }
expect_security_headers() { # on every response from the UI's port, errors and redirects too
  local what="$1" name
  for name in content-security-policy x-content-type-options referrer-policy; do
    [ -n "$(header "$name")" ] || fail "$what has no $name header"
  done
  grep -q "default-src 'none'" <<<"$(header content-security-policy)" || fail "$what: CSP isn't default-src 'none'"
}
max_age() { header cache-control | grep -oE 'max-age=[0-9]+' | cut -d= -f2; }

# The runtime contract.
fetch /healthz
expect_status 200 /healthz
fetch /readyz
expect_status 200 /readyz
pass "/healthz and /readyz: 200"
fetch /version
expect_status 200 /version
grep -q "\"version\":\"$revision\"" <<<"$body" || fail "/version isn't the revision label \"$revision\": $body"
expect_security_headers /version
pass "/version: $body"
fetch_url "$metrics/metrics"
expect_status 200 "/metrics on the metrics port"
grep -q '^text/plain; version=0.0.4' <<<"$(header content-type)" || fail "/metrics content type: $(header content-type)"
grep -qE '^nginx_connections_active [0-9]+$' <<<"$body" || fail "/metrics has no nginx_connections_active: $body"
fetch /metrics
expect_status 404 "/metrics on the UI's port"
fetch_url "$metrics/"
expect_status 404 "/ on the metrics port"
pass "/metrics: Prometheus text on port 9113 only (404 on the UI's port; nothing else on 9113)"

# The page.
fetch /
expect_status 200 /
grep -q '^text/html; charset=utf-8$' <<<"$(header content-type)" || fail "/ content type: $(header content-type)"
grep -q '<div id="root">' <<<"$body" || fail "/ isn't the UI's index.html"
page="$body"
expect_security_headers "/"
page_cache="$(header cache-control)"
grep -qE '(^|[ ,])no-cache([ ,]|$)|max-age=0([ ,]|$)' <<<"$page_cache" ||
  fail "index.html must be revalidated on every load (no-cache), so a new build shows up at once; Cache-Control: \"$page_cache\""
pass "/: index.html, utf-8, security headers, Cache-Control: $page_cache"
etag="$(header etag)"
[ -n "$etag" ] || fail "/ has no ETag to revalidate with"
fetch / -H "If-None-Match: $etag"
expect_status 304 "/ with If-None-Match"
[ -z "$body" ] || fail "the 304 for / has a body"
pass "/ revalidates: If-None-Match $etag gives 304, no body"

asset="$(grep -oE 'assets/index-[A-Za-z0-9_-]+\.js' <<<"$page" | head -n1)"
[ -n "$asset" ] || fail "no assets/index-*.js in index.html"
fetch "/$asset"
expect_status 200 "/$asset"
grep -q '^\(application\|text\)/javascript' <<<"$(header content-type)" || fail "/$asset content type: $(header content-type)"
expect_security_headers "/$asset"
age="$(max_age)"
[ -n "$age" ] && [ "$age" -ge "$year" ] ||
  fail "hashed assets must be cached for at least a year; Cache-Control: \"$(header cache-control)\""
pass "/$asset: javascript, security headers, Cache-Control: $(header cache-control)"
fetch "/$asset" -H 'Accept-Encoding: gzip'
[ "$(header content-encoding)" = gzip ] || fail "/$asset with Accept-Encoding: gzip isn't gzip-encoded"
grep -qi 'accept-encoding' <<<"$(header vary)" || fail "/$asset has no Vary: Accept-Encoding"
pass "/$asset: the precompressed file for gzip clients, Vary: Accept-Encoding"
css="$(grep -oE 'assets/index-[A-Za-z0-9_-]+\.css' <<<"$page" | head -n1)"
[ -n "$css" ] || fail "no assets/index-*.css in index.html"
fetch "/$css"
expect_status 200 "/$css"
! grep -q 'data:font' <<<"$body" || fail "/$css inlines fonts as data: URLs, which the CSP (font-src 'self') blocks"
pass "/$css: no fonts inlined as data: URLs (the CSP allows font files from the page's origin only)"

# Under a path prefix, the same files.
fetch /pr-12/
expect_status 200 /pr-12/
[ "$body" = "$page" ] || fail "/pr-12/ isn't the same page as /"
fetch "/pr-12/$asset"
expect_status 200 "/pr-12/$asset"
fetch /pr-12
expect_status 301 /pr-12
[ "$(header location)" = /pr-12/ ] || fail "/pr-12 redirects to \"$(header location)\", not /pr-12/"
expect_security_headers "the 301 for /pr-12"
pass "/pr-12/ and /pr-12/$asset: the same files; /pr-12 redirects to /pr-12/, with the security headers"

# Nothing else: 404, never cached, with the security headers.
for path in /nope.txt /assets/nope.js /src/main.tsx /index.html.gz /favicon.ico; do
  fetch "$path"
  expect_status 404 "$path"
  [ -z "$(header cache-control)" ] || fail "the 404 for $path has Cache-Control: $(header cache-control)"
  expect_security_headers "the 404 for $path"
done
pass "404 for unknown files, sources and /index.html.gz, uncached, with the security headers"

# Logs: requests as JSON lines with the version, the path without its query string (join links
# carry the room code), and no errors from the read-only filesystem.
fetch "/?room=QRCODE7"
expect_status 200 "/?room=QRCODE7"
logs="$(docker logs "$id" 2>&1)"
grep -q "\"service\":\"web\",\"version\":\"$revision\"" <<<"$logs" || fail "no JSON access log line with the version: $(tail -n 3 <<<"$logs")"
grep -q '"method":"GET","path":"/"' <<<"$logs" || fail "no log line with the path of /?room=…: $(tail -n 3 <<<"$logs")"
! grep -q 'QRCODE7' <<<"$logs" || fail "the room code from the query string is in the log"
! grep -qE '\[(emerg|alert|crit|error)\]|Read-only file system' <<<"$logs" || fail "errors in the log: $(grep -E 'emerg|alert|crit|error|Read-only' <<<"$logs")"
pass "JSON access logs with the version, paths without query strings; no errors"

# nginx is PID 1, a master and one worker, and docker stop ends it with exit 0, well before the
# grace period would kill it (exit 137).
procs="$(docker top "$id" -o pid,args | tail -n +2)"
grep -q 'nginx: master process nginx -g daemon off;' <<<"$procs" || fail "no nginx master process: $procs"
! grep -q 'docker-entrypoint' <<<"$procs" || fail "the entrypoint scripts are running: $procs"
[ "$(grep -c 'nginx: worker process' <<<"$procs")" = 1 ] || fail "not exactly one worker: $procs"
docker stop -t 30 "$id" >/dev/null
code="$(docker inspect -f '{{.State.ExitCode}}' "$id")"
[ "$code" = 0 ] || fail "nginx exited $code on docker stop, not 0"
pass "nginx master + 1 worker; docker stop: exit 0"

# The graceful stop, with a download in flight. docker stop sends the image's stop signal
# (SIGQUIT): nginx must refuse new connections at once and finish the download. nginx exits 0
# after a fast stop (SIGTERM) too, so only the bytes tell the two apart. A slow client can't show
# it either: Docker's port forwarding takes the whole response the moment nginx writes it (a
# 1.4 MB file arrived in full after SIGTERM). So this container runs a copy of the image's
# nginx.conf with `limit_rate 100k`, which keeps the transfer inside nginx (about 3 s for the
# bundle) when the signal arrives.
slow_conf="$(mktemp)"
docker run --rm --entrypoint cat "$image" /etc/nginx/nginx.conf |
  sed 's/^http {$/http {\n  limit_rate 100k;/' >"$slow_conf"
chmod 644 "$slow_conf"
grep -q '^  limit_rate 100k;$' "$slow_conf" || fail "couldn't add limit_rate to the test copy of nginx.conf"
docker run -d --name "${id}-slow" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -v "$slow_conf:/etc/nginx/nginx.conf:ro" -p 127.0.0.1::8080 "$image" >/dev/null
slow="http://127.0.0.1:$(docker port "${id}-slow" 8080/tcp | head -n1 | sed 's/.*://')"
up=""
for _ in $(seq 50); do
  if curl -fsS --max-time 2 -o /dev/null "$slow/healthz" 2>/dev/null; then
    up=1
    break
  fi
  sleep 0.2
done
[ -n "$up" ] || fail "the rate-limited container didn't answer: $(docker logs "${id}-slow" 2>&1 | tail -n 5)"
full="$(curl -sSI --max-time 5 "$slow/$asset" | tr -d '\r' | awk -F': ' 'tolower($1) == "content-length" {print $2}')"
download="$(mktemp)"
curl -sS --max-time 20 -o "$download" "$slow/$asset" &
download_pid=$!
sleep 0.5
started="$(date +%s.%N)"
docker stop -t 30 "${id}-slow" >/dev/null &
stop_pid=$!
sleep 0.5
if curl -fsS --max-time 2 -o /dev/null "$slow/readyz" 2>/dev/null; then
  fail "/readyz still answers while nginx drains"
fi
wait "$stop_pid"
took="$(awk -v a="$started" -v b="$(date +%s.%N)" 'BEGIN {printf "%.1f", b - a}')"
wait "$download_pid" || fail "the download in flight failed during the stop"
got="$(wc -c <"$download")"
[ "$got" = "$full" ] || fail "the download in flight got $got of $full bytes: the stop cut it off"
awk -v t="$took" 'BEGIN {exit !(t >= 1 && t < 15)}' ||
  fail "the stop took ${took} s: nginx didn't wait for the download, or waited too long"
pass "graceful stop: new connections refused at once, the download in flight finished ($got bytes), nginx stopped after ${took} s"
echo "image smoke test passed: $image"
