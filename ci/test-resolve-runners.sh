#!/usr/bin/env bash
# Tests for ci/resolve-runners.sh, run by make check (the runner-policy-tests hook).
#   Part 1: the resolver's rules (precedence, fallbacks, refusals) on a fixture policy.
#   Part 2: the real ci/runner-policy.yaml against what ADR 0005 decided. These are the
#           specification of the policy: change them only with the ADR.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
resolver="$here/resolve-runners.sh"
real="$here/runner-policy.yaml"
lint="$here/../.github/actionlint.yaml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

bad() {
  fail=$((fail + 1))
  echo "FAIL: $*" >&2
}

# check <name> <expected exit> <expected JSON, or empty to skip> [VAR=value ...]
check() {
  local name=$1 want_exit=$2 want=$3 out rc
  shift 3
  out="$(env -u RUNNER_FLEET -u RUNNER_LABEL -u GITHUB_STEP_SUMMARY "$@" bash "$resolver" 2>"$tmp/err")"
  rc=$?
  if [ "$rc" != "$want_exit" ]; then
    bad "$name: exit $rc, want $want_exit ($(tail -n1 "$tmp/err"))"
  elif [ -n "$want" ] && [ "$(jq -cS . <<<"$out")" != "$(jq -cS . <<<"$want")" ]; then
    bad "$name: got $out, want $want"
  else
    pass=$((pass + 1))
  fi
}

# assert <name> <command...>: passes when the command succeeds
assert() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else bad "$name"; fi
}

# --- Part 1: the rules ---------------------------------------------------------------------------
cat >"$tmp/policy.yaml" <<'EOF'
fleets:
  github: {linux: gh-linux, windows: gh-windows, macos: gh-macos}
  incredibuild: {linux: ib-linux, windows: ib-windows}
classes:
  big: {linux: incredibuild, windows: github, macos: github}
  small: {linux: github}
EOF
P="RUNNER_POLICY=$tmp/policy.yaml"

check "unset RUNNER_FLEET uses the policy" 0 \
  '{"big":{"linux":"ib-linux","windows":"gh-windows","macos":"gh-macos"},"small":{"linux":"gh-linux"}}' "$P"
check "empty RUNNER_FLEET uses the policy" 0 \
  '{"big":{"linux":"ib-linux","windows":"gh-windows","macos":"gh-macos"},"small":{"linux":"gh-linux"}}' "$P" RUNNER_FLEET=
check "RUNNER_FLEET=policy uses the policy" 0 \
  '{"big":{"linux":"ib-linux","windows":"gh-windows","macos":"gh-macos"},"small":{"linux":"gh-linux"}}' "$P" RUNNER_FLEET=policy
check "RUNNER_FLEET=github moves every class and OS to github" 0 \
  '{"big":{"linux":"gh-linux","windows":"gh-windows","macos":"gh-macos"},"small":{"linux":"gh-linux"}}' "$P" RUNNER_FLEET=github
check "RUNNER_FLEET=incredibuild moves what it can, and macOS stays on github" 0 \
  '{"big":{"linux":"ib-linux","windows":"ib-windows","macos":"gh-macos"},"small":{"linux":"ib-linux"}}' "$P" RUNNER_FLEET=incredibuild
check "RUNNER_LABEL replaces every Linux label, and only Linux" 0 \
  '{"big":{"linux":"my-runner","windows":"gh-windows","macos":"gh-macos"},"small":{"linux":"my-runner"}}' "$P" RUNNER_LABEL=my-runner
check "RUNNER_LABEL wins over a forced fleet on Linux" 0 \
  '{"big":{"linux":"my-runner","windows":"gh-windows","macos":"gh-macos"},"small":{"linux":"my-runner"}}' "$P" RUNNER_FLEET=github RUNNER_LABEL=my-runner
check "refuses an unknown RUNNER_FLEET" 2 "" "$P" RUNNER_FLEET=GitHub
check "refuses a RUNNER_LABEL with a space" 2 "" "$P" "RUNNER_LABEL=ubuntu latest"
# shellcheck disable=SC2016 # a literal ${{ }} on purpose: a variable that holds an expression must be refused
check "refuses a RUNNER_LABEL with an expression" 2 "" "$P" 'RUNNER_LABEL=${{ github.actor }}'
check "refuses a missing policy file" 2 "" "RUNNER_POLICY=$tmp/none.yaml"

refuse() { # refuse <name> <policy YAML>
  printf '%s\n' "$2" >"$tmp/broken.yaml"
  check "$1" 2 "" "RUNNER_POLICY=$tmp/broken.yaml"
}
refuse "refuses a class that names an unknown fleet" \
  'fleets: {github: {linux: gh}}
classes: {a: {linux: someone-else}}'
refuse "refuses a fleet without a runner for the OS" \
  'fleets: {github: {linux: gh, macos: m}, incredibuild: {linux: ib}}
classes: {a: {macos: incredibuild}}'
refuse "refuses an OS name it doesn't know" \
  'fleets: {github: {linux: gh}}
classes: {a: {linux-arm: github}}'
refuse "refuses a policy without classes" \
  'fleets: {github: {linux: gh}}
classes: {}'
refuse "refuses a class without an OS" \
  'fleets: {github: {linux: gh}}
classes: {a: {}}'
refuse "refuses a policy without a github fleet" \
  'fleets: {incredibuild: {linux: ib}}
classes: {a: {linux: incredibuild}}'

# --- Part 2: the real policy (ADR 0005) ----------------------------------------------------------
q() { yq -o=json "$1" "$real"; }

check "the real policy resolves (policy)" 0 "" RUNNER_FLEET=policy
check "the real policy resolves (github)" 0 "" RUNNER_FLEET=github
check "the real policy resolves (incredibuild)" 0 "" RUNNER_FLEET=incredibuild

assert "the classes are heavy-build, docker, e2e, tf-plan and light" \
  test "$(q '.classes | keys | sort' | jq -c .)" = '["docker","e2e","heavy-build","light","tf-plan"]'
assert "every class runs on Linux" \
  test "$(q '[.classes[] | has("linux")] | all')" = true
assert "tf-plan runs on Linux only: Terraform plans are Linux jobs" \
  test "$(q '.classes["tf-plan"] | keys' | jq -c .)" = '["linux"]'
assert "docker runs on Linux only: the images are Linux images" \
  test "$(q '.classes.docker | keys' | jq -c .)" = '["linux"]'
assert "heavy-build on Linux goes to Incredibuild: about 1.9 times faster on CPU-bound builds" \
  test "$(q '.classes["heavy-build"].linux')" = '"incredibuild"'
assert "light goes to GitHub-hosted on every OS: a 2-3.5 minute start-up outweighs a light job" \
  test "$(q '[.classes.light[] | . == "github"] | all')" = true
assert "macOS goes to GitHub-hosted: Incredibuild has no macOS runner" \
  test "$(q '[.classes[] | select(has("macos")) | .macos == "github"] | all')" = true
assert "the kill switch leaves no Incredibuild label" \
  bash -c "test \"\$(env -u RUNNER_LABEL RUNNER_FLEET=github bash '$resolver' 2>/dev/null | jq '[.[][] | startswith(\"incredibuild\")] | any')\" = false"
for label in $(q '.fleets.incredibuild[]' | jq -r '.'); do
  assert "actionlint knows $label" grep -qx -- "    - $label" "$lint"
done

echo "runner policy tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
