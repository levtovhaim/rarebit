#!/usr/bin/env bash
# Decides ci-ok, the one check a pull request has to pass to merge (ADR 0043).
#
# ci-ok waits for every other job in ci.yml. Each of them is one of two kinds:
#   - a check from ci/checks.yaml (infra, native, ...): it runs only when the changes job picked it
#   - a job every run needs: the resolver (runners), the changes job, lint
#
# Inputs (environment):
#   NEEDS      the ci-ok job's toJSON(needs): {"<job>": {"result": "success", "outputs": {...}}, ...}
#   CHECKS     the changes job's output: the checks it picked, as a JSON list. Anything else (the
#              changes job failed, or its output went missing) counts as every check picked.
#   CI_CHECKS  the checks file (default: checks.yaml next to this script)
#
# Prints a table of each job's verdict on stdout (and in the job summary when GITHUB_STEP_SUMMARY is
# set). Exits 0 when the pull request may merge, 1 when it may not, 2 on bad input.
set -euo pipefail

die() {
  printf 'ci-ok: %s\n' "$*" >&2
  exit 2
}

here="$(cd "$(dirname "$0")" && pwd)"
file="${CI_CHECKS:-$here/checks.yaml}"

yq --version 2>/dev/null | grep -qE 'version v?4\.' || die "needs mikefarah yq v4"
command -v jq >/dev/null || die "needs jq"
[ -f "$file" ] || die "no checks file at $(printf '%q' "$file")"
jq -e 'type == "object" and length > 0 and all(.[]; type == "object" and (.result | type) == "string")' \
  <<<"${NEEDS:-}" >/dev/null 2>&1 || die "NEEDS isn't a job's toJSON(needs)"

mapfile -t checks < <(yq '.checks | keys | .[]' "$file")
[ "${#checks[@]}" -gt 0 ] || die "no checks in $(printf '%q' "$file")"

# The checks this run picked. When that's unknown, every check counts as picked, so each one must
# have passed: ci-ok fails closed.
if jq -e 'type == "array" and all(.[]; type == "string")' <<<"${CHECKS:-}" >/dev/null 2>&1; then
  mapfile -t picked < <(jq -r '.[]' <<<"$CHECKS")
else
  picked=("${checks[@]}")
fi

is_check() { [[ " ${checks[*]} " == *" $1 "* ]]; }
is_picked() { [[ " ${picked[*]-} " == *" $1 "* ]]; }

rows=()
fail=0

# Every check in the file, and every check the changes job picked, must be a job ci-ok waits for: one
# it can't see could fail, or never run, and nobody would notice.
while IFS= read -r c; do
  if ! jq -e --arg c "$c" 'has($c)' <<<"$NEEDS" >/dev/null; then
    rows+=("| $c | – | no | ci-ok doesn't wait for this check (add it to ci-ok's needs in ci.yml) |")
    fail=1
  fi
done < <(printf '%s\n' "${checks[@]}" "${picked[@]}" | sed '/^$/d' | sort -u)

while IFS=$'\t' read -r job result; do
  ok=no
  why=""
  if ! is_check "$job"; then
    [ "$result" = success ] && ok=yes
    why="every run needs it"
  elif is_picked "$job"; then
    [ "$result" = success ] && ok=yes
    why="picked for this change"
  else
    case "$result" in
      success | skipped) ok=yes ;;
    esac
    why="not needed for this change"
  fi

  rows+=("| $job | $result | $ok | $why |")
  [ "$ok" = yes ] || fail=1
done < <(jq -r 'to_entries[] | [.key, .value.result] | @tsv' <<<"$NEEDS")

table="$(printf '%s\n' "| job | result | ok | why |" "|---|---|---|---|" "${rows[@]}")"
printf '%s\n' "$table"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '### ci-ok: %s\n\n%s\n' "$([ "$fail" -eq 0 ] && echo "may merge" || echo "may not merge")" "$table" >>"$GITHUB_STEP_SUMMARY"
fi
exit "$fail"
