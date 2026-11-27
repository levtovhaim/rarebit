#!/usr/bin/env bash
# Tests for ci/resolve-runners.sh, run by make check (the ci-tests hook) and, on the runner
# image itself, by the runner policy workflow.
#   Part 1: the resolver's rules (precedence, fallbacks, refusals, outputs) on a fixture policy.
#   Part 2: the workflows: no runs-on label outside the resolver.
#   Part 3: the real ci/runner-policy.yaml against what ADR 0005 decided. These are the
#           specification of the policy: change them only with the ADR.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
resolver="$here/resolve-runners.sh"
real="$here/runner-policy.yaml"
lint="$here/../.github/actionlint.yaml"
workflows="$here/../.github/workflows"
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
  out="$(env -u RUNNER_FLEET -u RUNNER_LABEL -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT -u GITHUB_ACTIONS "$@" bash "$resolver" 2>"$tmp/err")"
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
runner_groups: {github: GH, incredibuild: IB}
github_only: [secret]
classes:
  big: {linux: incredibuild, windows: github, macos: github}
  small: {linux: github}
  secret: {linux: github}
EOF
P="RUNNER_POLICY=$tmp/policy.yaml"
by_policy='{"big":{"linux":"ib-linux","windows":"gh-windows","macos":"gh-macos"},"small":{"linux":"gh-linux"},"secret":{"linux":"gh-linux"}}'
all_github='{"big":{"linux":"gh-linux","windows":"gh-windows","macos":"gh-macos"},"small":{"linux":"gh-linux"},"secret":{"linux":"gh-linux"}}'

check "unset RUNNER_FLEET uses the policy" 0 "$by_policy" "$P"
check "empty RUNNER_FLEET uses the policy" 0 "$by_policy" "$P" RUNNER_FLEET=
check "RUNNER_FLEET=policy uses the policy" 0 "$by_policy" "$P" RUNNER_FLEET=policy
check "RUNNER_FLEET=github moves every class and OS to github" 0 "$all_github" "$P" RUNNER_FLEET=github
check "RUNNER_FLEET=incredibuild moves what it can; macOS and github_only stay on github" 0 \
  '{"big":{"linux":"ib-linux","windows":"ib-windows","macos":"gh-macos"},"small":{"linux":"ib-linux"},"secret":{"linux":"gh-linux"}}' "$P" RUNNER_FLEET=incredibuild
check "RUNNER_LABEL replaces the Linux labels, except github_only" 0 \
  '{"big":{"linux":"ib-linux","windows":"gh-windows","macos":"gh-macos"},"small":{"linux":"ib-linux"},"secret":{"linux":"gh-linux"}}' "$P" RUNNER_LABEL=ib-linux
check "RUNNER_LABEL can be a github Linux label" 0 \
  '{"big":{"linux":"gh-linux","windows":"gh-windows","macos":"gh-macos"},"small":{"linux":"gh-linux"},"secret":{"linux":"gh-linux"}}' "$P" RUNNER_LABEL=gh-linux
check "the kill switch wins over a vendor RUNNER_LABEL" 0 "$all_github" "$P" RUNNER_FLEET=github RUNNER_LABEL=ib-linux
check "a github RUNNER_LABEL still applies with RUNNER_FLEET=github" 0 "$all_github" "$P" RUNNER_FLEET=github RUNNER_LABEL=gh-linux
check "RUNNER_LABEL wins over RUNNER_FLEET=incredibuild on Linux" 0 \
  '{"big":{"linux":"gh-linux","windows":"ib-windows","macos":"gh-macos"},"small":{"linux":"gh-linux"},"secret":{"linux":"gh-linux"}}' "$P" RUNNER_FLEET=incredibuild RUNNER_LABEL=gh-linux
check "refuses an unknown RUNNER_FLEET" 2 "" "$P" RUNNER_FLEET=GitHub
check "refuses a RUNNER_LABEL with a space" 2 "" "$P" "RUNNER_LABEL=ubuntu latest"
# shellcheck disable=SC2016 # a literal ${{ }} on purpose: a variable that holds an expression must be refused
check "refuses a RUNNER_LABEL with an expression" 2 "" "$P" 'RUNNER_LABEL=${{ github.actor }}'
check "refuses a RUNNER_LABEL that isn't in fleets (self-hosted matches any runner)" 2 "" "$P" RUNNER_LABEL=self-hosted
assert "and says which labels it takes" grep -q 'RUNNER_LABEL self-hosted is not a Linux label in fleets: use one of gh-linux, ib-linux' "$tmp/err"
check "refuses a RUNNER_LABEL that isn't a Linux label" 2 "" "$P" RUNNER_LABEL=gh-windows
check "refuses a missing policy file" 2 "" "RUNNER_POLICY=$tmp/none.yaml"

refuse() { # refuse <name> <policy YAML> [VAR=value ...]
  local name=$1 yaml=$2
  shift 2
  printf '%s\n' "$yaml" >"$tmp/broken.yaml"
  check "$name" 2 "" "RUNNER_POLICY=$tmp/broken.yaml" "$@"
}
G='runner_groups: {github: GH, incredibuild: IB}'
refuse "refuses a class that names an unknown fleet" \
  "fleets: {github: {linux: gh}}
$G
classes: {a: {linux: someone-else}}"
refuse "refuses a fleet without a runner for the OS" \
  "fleets: {github: {linux: gh, macos: m}, incredibuild: {linux: ib}}
$G
classes: {a: {macos: incredibuild}}"
refuse "refuses an OS name it doesn't know" \
  "fleets: {github: {linux: gh}}
$G
classes: {a: {linux-arm: github}}"
refuse "refuses a policy without classes" \
  "fleets: {github: {linux: gh}}
$G
classes: {}"
refuse "refuses a class without an OS" \
  "fleets: {github: {linux: gh}}
$G
classes: {a: {}}"
refuse "refuses a policy without a github fleet" \
  "fleets: {incredibuild: {linux: ib}}
$G
classes: {a: {linux: incredibuild}}"
refuse "refuses a fleet label that isn't a runner label" \
  "fleets: {github: {linux: 'ubuntu 24.04'}}
$G
classes: {a: {linux: github}}"
refuse "refuses a fleet without a runner group" \
  "fleets: {github: {linux: gh}, incredibuild: {linux: ib}}
runner_groups: {github: GH}
classes: {a: {linux: github}}"
refuse "refuses a github_only class that the policy sends elsewhere" \
  "fleets: {github: {linux: gh}, incredibuild: {linux: ib}}
$G
github_only: [a]
classes: {a: {linux: incredibuild}}"
refuse "refuses a github_only entry that isn't a class" \
  "fleets: {github: {linux: gh}}
$G
github_only: [nobody]
classes: {a: {linux: github}}"
refuse "refuses a policy file with two YAML documents" \
  "fleets: {github: {linux: gh}}
$G
classes: {a: {linux: github}}
---
classes: {b: {linux: github}}"
refuse "refuses RUNNER_FLEET=incredibuild when the policy has no such fleet" \
  "fleets: {github: {linux: gh}}
$G
classes: {a: {linux: github}}" RUNNER_FLEET=incredibuild

# The step outputs: four lines, each name=<one line of JSON>.
env -u RUNNER_FLEET -u RUNNER_LABEL -u GITHUB_ACTIONS GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/summary" \
  RUNNER_POLICY="$tmp/policy.yaml" bash "$resolver" >/dev/null 2>&1
assert "GITHUB_OUTPUT gets labels, fleets, groups and pairs, one line each" \
  test "$(cut -d= -f1 "$tmp/out" | paste -sd, -)" = labels,fleets,groups,pairs
assert "the fleets output names the fleet each job lands on" \
  test "$(sed -n 's/^fleets=//p' "$tmp/out" | jq -r '.big.linux + "," + .big.windows + "," + .secret.linux')" = incredibuild,github,github
assert "the groups output names the runner group each job must report" \
  test "$(sed -n 's/^groups=//p' "$tmp/out" | jq -r '.big.linux + "," + .small.linux')" = IB,GH
assert "the pairs output lists every class and OS" \
  test "$(sed -n 's/^pairs=//p' "$tmp/out" | jq -c 'map(.class + "/" + .os) | sort')" = '["big/linux","big/macos","big/windows","secret/linux","small/linux"]'
# shellcheck disable=SC2016 # the backticks are the table's Markdown, matched literally
assert "the job summary has the table" grep -q '| big | linux | incredibuild | incredibuild | `ib-linux` | policy |' "$tmp/summary"

# --- Part 2: the workflows -----------------------------------------------------------------------
# Every runs-on is an expression from the resolver's outputs, except the resolver's own job and the
# runner measurements, which name labels on purpose (ADR 0005).
literal="$(grep -nE '^[[:space:]]*runs-on:[[:space:]]*[^$[:space:]]' "$workflows"/*.yml |
  grep -vE '/(_runners|spike-runner)\.yml:' || true)"
assert "no workflow names a runner label outside _runners.yml and spike-runner.yml" test -z "$literal"
[ -z "$literal" ] || echo "  literal runs-on: $literal" >&2

# --- Part 3: the real policy (ADR 0005) ----------------------------------------------------------
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
assert "light goes to GitHub-hosted on every OS: the start-up outweighs a light job" \
  test "$(q '[.classes.light[] | . == "github"] | all')" = true
assert "macOS goes to GitHub-hosted: Incredibuild has no macOS runner" \
  test "$(q '[.classes[] | select(has("macos")) | .macos == "github"] | all')" = true
assert "docker and tf-plan are github_only: they will take AWS roles, and a token minted on the vendor's machine works as well as one minted on GitHub's (ADR 0038)" \
  test "$(q '[(.github_only // [])[] | select(. == "docker" or . == "tf-plan")] | length')" = 2
assert "the github fleet's labels are GitHub-hosted labels" \
  test "$(q '[.fleets.github[] | test("^(ubuntu|windows|macos)-[0-9]")] | all')" = true
assert "every fleet has a runner group" \
  test "$(q '[.fleets | keys[]] - (.runner_groups | keys) | length')" = 0
assert "the kill switch leaves no Incredibuild label, even with a vendor RUNNER_LABEL set" \
  bash -c "test \"\$(RUNNER_FLEET=github RUNNER_LABEL=incredibuild-ubuntu-2404 bash '$resolver' 2>/dev/null | jq '[.[][] | startswith(\"incredibuild\")] | any')\" = false"
for label in $(q '.fleets.incredibuild[]' | jq -r '.'); do
  assert "actionlint knows $label" grep -qx -- "    - $label" "$lint"
done

echo "runner policy tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
