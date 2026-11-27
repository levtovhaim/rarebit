#!/usr/bin/env bash
# Picks the CI checks a change needs, from ci/checks.yaml (ADR 0043).
#
#   changed-checks.sh <base>   the checks for the files that differ between <base> and HEAD
#   changed-checks.sh --all    every check
#
# Prints the checks as one line of JSON on stdout, ["<check>", ...] in the file's order, and a table of
# why on stderr (and in the job summary when GITHUB_STEP_SUMMARY is set). When GITHUB_OUTPUT is set,
# it also writes checks=<the same JSON> there.
#
# A path in the file that ends in / covers everything under it; any other path covers that one file.
# A check runs when a file it covers was added, changed or deleted. Renames count as a delete and an
# add, so moving a file out of a check's paths still runs that check. A change to a path under `all`
# runs every check.
#
# Inputs (environment): CI_CHECKS, the checks file (default: checks.yaml next to this script).
# Exits 2 on anything unexpected: an unknown base, a malformed file. In CI that fails the changes job,
# and ci-ok with it.
set -euo pipefail

die() {
  printf 'changed-checks: %s\n' "$*" >&2
  exit 2
}

here="$(cd "$(dirname "$0")" && pwd)"
file="${CI_CHECKS:-$here/checks.yaml}"

[ $# -eq 1 ] || die "usage: changed-checks.sh <base-commit> | --all"
yq --version 2>/dev/null | grep -qE 'version v?4\.' || die "needs mikefarah yq v4"
command -v jq >/dev/null || die "needs jq"
[ -f "$file" ] || die "no checks file at $(printf '%q' "$file")"

# One document, exactly the keys `all` and `checks`, check names a job can have, and plain relative
# paths: no globs (a * would match nothing and silently skip a check), no leading /, no `..`.
config="$(yq -o=json -I0 '.' "$file" | jq -cs '
  def path_ok: type == "string" and test("^[A-Za-z0-9_.-][A-Za-z0-9_./-]*$") and (test("(^|/)\\.\\.?(/|$)") | not);
  def paths_ok: type == "array" and length > 0 and all(.[]; path_ok);
  if length != 1 then error("the checks file has \(length) YAML documents: use one") else .[0] end
  | if type != "object" or (keys != ["all", "checks"]) then error("the checks file has exactly two keys, all and checks") else . end
  | if (.all | paths_ok) | not then error("all is a list of paths (relative, no globs, a trailing / for a directory)") else . end
  | if (.checks | type) != "object" or (.checks | length) == 0 then error("checks maps each check to its paths") else . end
  | if ([.checks | keys[] | test("^[a-z][a-z0-9-]*$")] | all) | not then error("a check name is lowercase letters, digits and -") else . end
  | if ([.checks[] | paths_ok] | all) | not then error("each check lists its paths (relative, no globs, a trailing / for a directory)") else . end
')" || die "invalid checks file $(printf '%q' "$file")"

if [ "$1" = --all ]; then
  mode="all"
  files='[]'
else
  mode="diff"
  git rev-parse --verify --quiet "$1^{commit}" >/dev/null || die "no commit $(printf '%q' "$1")"
  # --no-renames: a rename shows as both paths. --no-relative: paths from the root, whatever the local
  # config says. -z: no quoting of non-ASCII names (the Hebrew word lists), which --name-only would
  # otherwise wrap in quotes and escapes.
  files="$(git diff --no-renames --no-relative --no-ext-diff --name-only -z "$1" HEAD |
    jq -Rsc 'split("\u0000") | map(select(length > 0))')" || die "git diff $(printf '%q' "$1") HEAD failed"
fi

records="$(jq -c --arg mode "$mode" --argjson files "$files" '
  def covered($path): any(.[]; if endswith("/") then . as $dir | $path | startswith($dir) else . == $path end);
  def first_of($hits): "\($hits[0])\(if ($hits | length) > 1 then " and \($hits | length - 1) more" else "" end)";
  .all as $all
  | [$files[] | select(. as $f | $all | covered($f))] as $wiring
  | [ .checks | to_entries[] | .key as $check | .value as $paths
      | [$files[] | select(. as $f | $paths | covered($f))] as $hits
      | if $mode == "all" then {check: $check, run: true, why: "--all: every check"}
        elif ($wiring | length) > 0 then {check: $check, run: true, why: "\(first_of($wiring)) changed: every check"}
        elif ($hits | length) > 0 then {check: $check, run: true, why: "\(first_of($hits)) changed"}
        else {check: $check, run: false, why: "nothing it covers changed"}
        end ]
' <<<"$config")" || die "can't match the changed files"

checks="$(jq -c '[.[] | select(.run) | .check]' <<<"$records")"
printf '%s\n' "$checks"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'checks=%s\n' "$checks" >>"$GITHUB_OUTPUT"
fi

summary="$(jq -r --arg mode "$mode" --argjson files "$files" '
  (if $mode == "all" then "every check (--all)" else "\($files | length) changed files" end),
  "",
  "| check | runs | why |", "|---|---|---|",
  (.[] | "| \(.check) | \(if .run then "yes" else "no" end) | \(.why) |")
' <<<"$records")"
printf '%s\n' "$summary" >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '### Checks for this change\n\n%s\n' "$summary" >>"$GITHUB_STEP_SUMMARY"
fi
