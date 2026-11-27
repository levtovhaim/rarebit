#!/usr/bin/env bash
# Resolves ci/runner-policy.yaml into one runner label per job class and OS (ADR 0005).
#
# Prints the labels as one line of JSON on stdout, {"<class>":{"<os>":"<label>"}}, and a table of
# what it chose, and why, on stderr (and in the job summary when GITHUB_STEP_SUMMARY is set).
#
# Inputs (environment):
#   RUNNER_FLEET   policy (also when unset or empty), github or incredibuild
#   RUNNER_LABEL   when set, the label for every Linux job, whatever the fleet
#   RUNNER_POLICY  the policy file (default: runner-policy.yaml next to this script)
#
# Exits 2 on anything unexpected: an unknown fleet, a malformed label, a class that names a fleet or an
# OS without a label. A wrong label leaves a job queued with no error at all, so the resolver fails
# instead of guessing.
set -euo pipefail

die() {
  echo "resolve-runners: $*" >&2
  exit 2
}

policy="${RUNNER_POLICY:-$(dirname "$0")/runner-policy.yaml}"
fleet="${RUNNER_FLEET:-policy}"
override="${RUNNER_LABEL:-}"

yq --version 2>/dev/null | grep -qE 'version v?4\.' || die "needs mikefarah yq v4"
command -v jq >/dev/null || die "needs jq"
[ -f "$policy" ] || die "no policy file at $policy"

case "$fleet" in
  policy | github | incredibuild) ;;
  *) die "RUNNER_FLEET is '$fleet': use policy, github or incredibuild" ;;
esac
if [ -n "$override" ] && ! [[ "$override" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  die "RUNNER_LABEL '$override' isn't a runner label"
fi

policy_json="$(yq -o=json '.' "$policy")" || die "can't parse $policy"

# One record per class and OS: the fleet the policy names, the label the resolver picked, and why.
records="$(jq -c --arg fleet "$fleet" --arg override "$override" '
  .fleets as $fleets
  | if ($fleets | type) != "object" or ($fleets.github | type) != "object" then
      error("the policy has no fleets.github") else . end
  | if (.classes | type) != "object" or (.classes | length) == 0 then
      error("the policy has no classes") else . end
  | [ .classes | to_entries[] | .key as $class
      | if (.value | type) != "object" or (.value | length) == 0 then
          error("class \($class) names no OS") else . end
      | .value | to_entries[] | .key as $os | .value as $chosen
      | if ([$os] | inside(["linux", "windows", "macos"])) | not then
          error("class \($class) names OS \($os): use linux, windows or macos") else . end
      | if ($fleets[$chosen] | type) != "object" then
          error("class \($class) on \($os) names fleet \($chosen), which isn'"'"'t in fleets") else . end
      | ($fleets[$chosen][$os] // error("fleet \($chosen) has no \($os) runner (class \($class))")) as $from_policy
      | ( if $override != "" and $os == "linux" then {label: $override, why: "RUNNER_LABEL"}
          elif $fleet == "policy" then {label: $from_policy, why: "policy"}
          elif $fleets[$fleet][$os] then {label: $fleets[$fleet][$os], why: "RUNNER_FLEET=\($fleet)"}
          else {label: $fleets.github[$os], why: "RUNNER_FLEET=\($fleet), which has no \($os) runner: github"}
          end ) as $pick
      | if ($pick.label | type) != "string" then error("no runner for class \($class) on \($os)") else . end
      | {class: $class, os: $os, policy: $chosen, label: $pick.label, why: $pick.why} ]
' <<<"$policy_json")" || die "invalid policy $policy"

jq -c 'reduce .[] as $r ({}; .[$r.class][$r.os] = $r.label)' <<<"$records"

table="$(jq -r '
  "| class | OS | policy fleet | runner label | why |", "|---|---|---|---|---|",
  (.[] | "| \(.class) | \(.os) | \(.policy) | `\(.label)` | \(.why) |")
' <<<"$records")"
printf 'RUNNER_FLEET=%s RUNNER_LABEL=%s\n%s\n' "$fleet" "${override:-(unset)}" "$table" >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # shellcheck disable=SC2016 # the backticks are Markdown code spans, not command substitution
  printf '### Runner labels\n\n`RUNNER_FLEET=%s`, `RUNNER_LABEL=%s`\n\n%s\n' "$fleet" "${override:-(unset)}" "$table" >>"$GITHUB_STEP_SUMMARY"
fi
