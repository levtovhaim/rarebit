#!/usr/bin/env bash
# shellcheck disable=SC2086 # $ok and the job=result lists split into words on purpose
# Tests for ci/ci-ok.sh, run by make check (the ci-tests hook). They are the specification of the
# one check a pull request must pass to merge (ADR 0043): change them only with the ADR.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/ci-ok.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

bad() {
  fail=$((fail + 1))
  echo "FAIL: $*" >&2
}

cat >"$tmp/checks.yaml" <<'EOF'
all: [ci/]
checks:
  game: [apps/game/]
  web: [apps/web/]
EOF

# needs <job>=<result> ...: a toJSON(needs) like the ci-ok job sees
needs() {
  local pair json='{}'
  for pair in "$@"; do
    json="$(jq -c --arg job "${pair%%=*}" --arg result "${pair#*=}" '.[$job] = {result: $result, outputs: {}}' <<<"$json")"
  done
  printf '%s' "$json"
}

# verdict <name> <expected exit> <CHECKS> <job>=<result> ...
# The run is a pull request's unless EVENT says otherwise.
verdict() {
  local name=$1 want=$2 checks=$3 rc=0
  shift 3
  env -u GITHUB_STEP_SUMMARY CI_CHECKS="$tmp/checks.yaml" CHECKS="$checks" NEEDS="$(needs "$@")" \
    EVENT="${EVENT-pull_request}" bash "$script" >"$tmp/out" 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1))
  else
    bad "$name: exit $rc, want $want"
    sed 's/^/    /' "$tmp/out" >&2
  fi
}

ok="runners=success changes=success lint=success"

# Every run needs the resolver, the changes job and lint to succeed.
verdict "everything passed" 0 '["game","web"]' $ok game=success web=success
verdict "lint failed" 1 '["game","web"]' runners=success changes=success lint=failure game=success web=success
verdict "lint was skipped" 1 '[]' runners=success changes=success lint=skipped game=skipped web=skipped
verdict "lint was cancelled" 1 '[]' runners=success changes=success lint=cancelled game=skipped web=skipped
verdict "the resolver was cancelled" 1 '[]' runners=cancelled changes=skipped lint=skipped game=skipped web=skipped

# A picked check must succeed: skipped means it never ran.
verdict "a picked check passed, the other wasn't needed" 0 '["web"]' $ok game=skipped web=success
verdict "a picked check failed" 1 '["web"]' $ok game=skipped web=failure
verdict "a picked check was skipped" 1 '["web"]' $ok game=skipped web=skipped
verdict "a picked check was cancelled" 1 '["web"]' $ok game=skipped web=cancelled

# A check that wasn't picked may be skipped, or pass; a failure still counts.
verdict "no check was needed" 0 '[]' $ok game=skipped web=skipped
verdict "a check that wasn't picked passed anyway" 0 '["web"]' $ok game=success web=success
verdict "a check that wasn't picked failed" 1 '["web"]' $ok game=failure web=success
verdict "a check that wasn't picked was cancelled" 1 '["web"]' $ok game=cancelled web=success

# When the picked checks are unknown, every check must have passed.
verdict "the changes job failed" 1 '' runners=success changes=failure lint=success game=skipped web=skipped
verdict "the changes job's output went missing" 1 '' $ok game=skipped web=skipped
verdict "the changes job's output is missing, but every check passed" 0 '' $ok game=success web=success
verdict "the changes job's output isn't a list" 1 '{"web":true}' $ok game=skipped web=skipped

# Outside a pull request every check must have run, whatever the changes job says.
EVENT=push verdict "a push to main where every check passed" 0 '["game","web"]' $ok game=success web=success
EVENT=push verdict "a push to main where the changes job picked nothing" 1 '[]' $ok game=skipped web=skipped
EVENT=merge_group verdict "the merge queue with a check skipped" 1 '["web"]' $ok game=skipped web=success
EVENT=workflow_dispatch verdict "a manual run with a check skipped" 1 '["game"]' $ok game=success web=skipped
EVENT='' verdict "no event at all counts as not a pull request" 1 '[]' $ok game=skipped web=skipped

# Anything ci-ok doesn't know fails.
verdict "a result GitHub might add later" 1 '["web"]' $ok game=skipped web=neutral
verdict "a result GitHub might add later, on a check that wasn't picked" 1 '["web"]' $ok game=neutral web=success
verdict "a check ci-ok doesn't wait for" 1 '["web"]' $ok web=success
verdict "a picked check that isn't a job" 1 '["web","docs"]' $ok game=skipped web=success
verdict "another job every run needs failed" 1 '[]' $ok scan=failure game=skipped web=skipped
verdict "another job every run needs passed" 0 '[]' $ok scan=success game=skipped web=skipped

# Bad input exits 2.
rc=0
env -u GITHUB_STEP_SUMMARY CI_CHECKS="$tmp/checks.yaml" CHECKS='[]' NEEDS='not json' bash "$script" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ]; then pass=$((pass + 1)); else bad "NEEDS that isn't JSON: exit $rc, want 2"; fi
rc=0
env -u GITHUB_STEP_SUMMARY CI_CHECKS="$tmp/checks.yaml" CHECKS='[]' NEEDS='{}' bash "$script" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ]; then pass=$((pass + 1)); else bad "empty NEEDS: exit $rc, want 2"; fi

# The table names every job and says why, in the job summary too.
: >"$tmp/summary"
EVENT=pull_request GITHUB_STEP_SUMMARY="$tmp/summary" CI_CHECKS="$tmp/checks.yaml" CHECKS='["web"]' NEEDS="$(needs $ok game=skipped web=failure)" \
  bash "$script" >/dev/null 2>&1
if grep -qF '### ci-ok: may not merge' "$tmp/summary" && grep -qE '^\| web \| failure \| no \| .+ \|$' "$tmp/summary" &&
  grep -qE '^\| game \| skipped \| yes \| .+ \|$' "$tmp/summary"; then
  pass=$((pass + 1))
else
  bad "the summary: a heading and one row per job, each with a reason"
  sed 's/^/    /' "$tmp/summary" >&2
fi

echo "ci-ok tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
