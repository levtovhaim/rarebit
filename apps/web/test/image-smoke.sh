#!/usr/bin/env bash
# Smoke test for the web UI image, run the way Kubernetes runs it: non-root, read-only root
# filesystem with a tmpfs on /tmp, no capabilities. Checks the image contract (apps/web/Dockerfile):
# the files, the runtime contract endpoints, the page and its assets at / and under a path prefix,
# caching and security headers, compression, JSON logs and the graceful stop.
#
#   bash image-smoke.sh <image>      (make web-image-smoke)
#
# Needs Docker and curl. Leaves no containers behind.
set -euo pipefail

image="${1:?usage: bash image-smoke.sh <image>}"
max_mb="${MAX_IMAGE_MB:-64}" # unpacked: the base is 54.5 MB, the UI's files 2.5 MB
id="rarebit-web-smoke-$$"
year=31536000

cleanup() {
  docker rm -fv "${id}-files" "$id" >/dev/null 2>&1 || true
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
size_mb="$(awk '{s += $3} END {printf "%d", s / 1000000}' <<<"$listing")"
[ "$size_mb" -le "$max_mb" ] || fail "the image is $size_mb MB unpacked, over the $max_mb MB limit"
pass "$size_mb MB unpacked (limit $max_mb MB)"
ours="$(grep -E ' (srv/web/|etc/nginx/nginx\.conf$|etc/nginx/rarebit-version\.conf$)' <<<"$listing")"
writable="$(awk '$1 ~ /^.......w/ {print $NF}' <<<"$ours")"
[ -z "$writable" ] || fail "world-writable files we added: $writable"
not_root="$(awk '$2 !~ /^(root|0)\/(root|0)$/ {print $NF}' <<<"$ours")"
[ -z "$not_root" ] || fail "files we added that root doesn't own: $not_root"
pass "the files we added are root's and not world-writable"
grep -q ' srv/web/index\.html$' <<<"$listing" || fail "no /srv/web/index.html"
grep -q ' srv/web/index\.html\.gz$' <<<"$listing" || fail "index.html isn't precompressed"
! grep -qE ' srv/web/(src/|.*\.tsx?$)' <<<"$listing" || fail "sources in /srv/web"
! grep -qE '(^| )(usr/local/bin/node|opt/yarn)' <<<"$listing" || fail "Node is in the image"
pass "the built files only, precompressed; no sources, no Node"

# Run it, hardened.
revision="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")"
docker run -d --name "$id" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1::8080 "$image" >/dev/null
port="$(docker port "$id" 8080/tcp | head -n1 | sed 's/.*://')"
base="http://127.0.0.1:$port"
for _ in $(seq 50); do
  curl -fsS -o /dev/null "$base/healthz" 2>/dev/null && break
  sleep 0.2
done

status="" headers="" body=""
fetch() { # fetch <path> [curl options]: sets status, headers (lowercase names) and body
  local path="$1" out
  shift
  out="$(mktemp)"
  headers="$(curl -sS -D - -o "$out" "$@" "$base$path" | tr -d '\r')" || fail "GET $path: no answer"
  status="$(head -n1 <<<"$headers" | awk '{print $2}')"
  headers="$(tail -n +2 <<<"$headers" | awk -F': ' 'NF > 1 {printf "%s: %s\n", tolower($1), substr($0, length($1) + 3)}')"
  body="$(tr -d '\0' <"$out")" # compared as text only; a gzip body has NUL bytes
  rm -f "$out"
}
header() { awk -F': ' -v n="$1" '$1 == n {print substr($0, length($1) + 3)}' <<<"$headers"; }
expect_status() { [ "$status" = "$1" ] || fail "GET $2: status $status, not $1"; }
expect_security_headers() { # on every page and asset response
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
pass "/version: $body"
fetch /metrics
expect_status 200 /metrics
grep -q '^text/plain; version=0.0.4' <<<"$(header content-type)" || fail "/metrics content type: $(header content-type)"
grep -qE '^nginx_connections_active [0-9]+$' <<<"$body" || fail "/metrics has no nginx_connections_active: $body"
fetch /metrics -H 'X-Forwarded-For: 203.0.113.7'
expect_status 404 "/metrics through a proxy"
pass "/metrics: Prometheus text, and 404 through a proxy (X-Forwarded-For)"

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
pass "/pr-12/ and /pr-12/$asset: the same files; /pr-12 redirects to /pr-12/"

# Nothing else.
for path in /nope.txt /assets/nope.js /src/main.tsx /index.html.gz /favicon.ico; do
  fetch "$path"
  expect_status 404 "$path"
  [ -z "$(header cache-control)" ] || fail "the 404 for $path has Cache-Control: $(header cache-control)"
done
pass "404 for unknown files, sources and the .gz files themselves, with no Cache-Control"

# Logs: requests as JSON lines with the version; no errors from the read-only filesystem.
logs="$(docker logs "$id" 2>&1)"
grep -q "\"service\":\"web\",\"version\":\"$revision\"" <<<"$logs" || fail "no JSON access log line with the version: $(tail -n 3 <<<"$logs")"
! grep -qE '\[(emerg|alert|crit|error)\]|Read-only file system' <<<"$logs" || fail "errors in the log: $(grep -E 'emerg|alert|crit|error|Read-only' <<<"$logs")"
pass "JSON access logs with the version; no errors"

# Graceful stop: nginx is PID 1 (master and one worker), and docker stop's SIGQUIT ends it cleanly,
# well before the grace period would kill it (exit 137).
procs="$(docker top "$id" -o pid,args | tail -n +2)"
grep -q 'nginx: master process nginx -g daemon off;' <<<"$procs" || fail "no nginx master process: $procs"
! grep -q 'docker-entrypoint' <<<"$procs" || fail "the entrypoint scripts are running: $procs"
[ "$(grep -c 'nginx: worker process' <<<"$procs")" = 1 ] || fail "not exactly one worker: $procs"
started="$(date +%s)"
docker stop -t 30 "$id" >/dev/null
took=$(($(date +%s) - started))
code="$(docker inspect -f '{{.State.ExitCode}}' "$id")"
[ "$code" = 0 ] || fail "nginx exited $code on docker stop, not 0"
[ "$took" -lt 10 ] || fail "stopping took ${took} s"
pass "nginx master + 1 worker; docker stop (SIGQUIT): exit 0 in ${took} s"
echo "image smoke test passed: $image"
