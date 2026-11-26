#!/usr/bin/env bash
# Parity test: rarebit-cli's `check --json` against the running validator on thousands of answers
# generated from the word lists (tests/parity.mjs). Needs the local stack (make up) and the bots
# image (make bots-image): the comparison runs in it, for its Node, on the stack's network, so the
# validator needn't publish a port. The CLI binary runs inside that image too (Debian 13 glibc).
#
#   bash native/rarebit-cli/tests/parity.sh [path to rarebit-cli]      (from the repo root)
set -euo pipefail

cli="${1:-native/build/linux-gcc/rarebit-cli/rarebit-cli}"
image="${BOTS_IMAGE:-rarebit-bots:dev}"
here="$(cd "$(dirname "$0")" && pwd)"
[ -x "$cli" ] || {
  echo "no rarebit-cli at $cli: run make native first" >&2
  exit 2
}
docker network inspect rarebit_default >/dev/null 2>&1 || {
  echo "the local stack isn't up: run make up first" >&2
  exit 2
}
docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges --network rarebit_default \
  -v "$(realpath "$cli"):/cli/rarebit-cli:ro" \
  -v "$(realpath data/categories):/cli/data:ro" \
  -v "$here/parity.mjs:/cli/parity.mjs:ro" \
  --entrypoint /nodejs/bin/node "$image" /cli/parity.mjs
