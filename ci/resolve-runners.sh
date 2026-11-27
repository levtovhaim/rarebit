#!/usr/bin/env bash
# Resolves ci/runner-policy.yaml into one runner label per job class and OS (ADR 0005).
#
# Prints the labels as one line of JSON on stdout, {"<class>":{"<os>":"<label>"}}, and a table of
# what it chose, and why, on stderr (and in the job summary when GITHUB_STEP_SUMMARY is set). When
# GITHUB_OUTPUT is set, it also writes four step outputs there, each one line of JSON:
#   labels  {"<class>":{"<os>":"<label>"}}
#   fleets  {"<class>":{"<os>":"<fleet>"}}   the fleet each job lands on
#   groups  {"<class>":{"<os>":"<group>"}}   the runner group GitHub must report for it (verify job)
#   pairs   [{"class":...,"os":...}]         every class and OS, for a matrix
#
# Inputs (environment):
#   RUNNER_FLEET   policy (also when unset or empty), github or incredibuild
#   RUNNER_LABEL   when set, the label for every Linux job: one of the Linux labels in `fleets`.
#                  With RUNNER_FLEET=github, only a github label applies (the kill switch wins).
#   RUNNER_POLICY  the policy file (default: runner-policy.yaml next to this script)
# Classes listed in `github_only` always run on github, whatever the two variables say.
#
# Exits 2 on anything unexpected: an unknown fleet, an unknown or malformed label, a class that names
# a fleet or an OS without a runner, a github_only class mapped elsewhere, more than one YAML document.
# A wrong label leaves a job queued with no error at all, so the resolver fails instead of guessing.
set -euo pipefail

die() {
  printf 'resolve-runners: %s\n' "$*" >&2
  exit 2
}

here="$(cd "$(dirname "$0")" && pwd)"
policy="${RUNNER_POLICY:-$here/runner-policy.yaml}"
fleet="${RUNNER_FLEET:-policy}"
override="${RUNNER_LABEL:-}"

yq_version="$(yq --version 2>/dev/null || true)"
grep -qE 'version v?4\.' <<<"$yq_version" || die "needs mikefarah yq v4"
command -v jq >/dev/null || die "needs jq"
jq_version="$(jq --version)"
[ -f "$policy" ] || die "no policy file at $(printf '%q' "$policy")"

case "$fleet" in
  policy | github | incredibuild) ;;
  *) die "RUNNER_FLEET is $(printf '%q' "$fleet"): use policy, github or incredibuild" ;;
esac
if [ -n "$override" ] && ! [[ "$override" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  die "RUNNER_LABEL $(printf '%q' "$override") isn't a runner label"
fi

# One document only: a second one would print a second line of JSON, and a malformed GITHUB_OUTPUT.
policy_json="$(yq -o=json -I0 '.' "$policy" | jq -cs '
  if length != 1 then error("the policy file has \(length) YAML documents: use one") else .[0] end
')" || die "can't read $(printf '%q' "$policy")"

# One record per class and OS: the fleet the policy names, the label and fleet the resolver picked,
# and why.
records="$(jq -c --arg fleet "$fleet" --arg override "$override" '
  def label_ok: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
  .fleets as $fleets
  | .runner_groups as $groups
  | (.github_only // []) as $github_only
  | if ($fleets | type) != "object" or ($fleets.github | type) != "object" then
      error("the policy has no fleets.github") else . end
  | if ([$fleets[] | type == "object"] | all) | not then error("every fleet maps OS to label") else . end
  | if ([$fleets[][] | label_ok] | all) | not then error("a label in fleets is not a runner label") else . end
  | if ($groups | type) != "object" or ([$fleets | keys[] as $f | $groups[$f] | type == "string"] | all | not) then
      error("runner_groups names no group for some fleet") else . end
  | if ($github_only | type) != "array" or ([$github_only[] | type == "string"] | all | not) then
      error("github_only is a list of class names") else . end
  | if (.classes | type) != "object" or (.classes | length) == 0 then
      error("the policy has no classes") else . end
  | if ($github_only - (.classes | keys)) != [] then
      error("github_only names a class that does not exist: \($github_only - (.classes | keys) | join(", "))") else . end
  | if $fleet != "policy" and ($fleets[$fleet] | type) != "object" then
      error("RUNNER_FLEET=\($fleet), but the policy has no fleet \($fleet)") else . end
  | ([$fleets | to_entries[] | select(.value.linux) | {key: .value.linux, value: .key}] | from_entries) as $linux_label_fleet
  | if $override != "" and ($linux_label_fleet[$override] == null) then
      error("RUNNER_LABEL \($override) is not a Linux label in fleets: use one of \($linux_label_fleet | keys | join(", "))") else . end
  | [ .classes | to_entries[] | .key as $class
      | if (.value | type) != "object" or (.value | length) == 0 then
          error("class \($class) names no OS") else . end
      | .value | to_entries[] | .key as $os | .value as $chosen
      | if ([$os] | inside(["linux", "windows", "macos"])) | not then
          error("class \($class) names OS \($os): use linux, windows or macos") else . end
      | if ($chosen | type) != "string" or ($fleets[$chosen] | type) != "object" then
          error("class \($class) on \($os) names fleet \($chosen), which isn'"'"'t in fleets") else . end
      | if ($fleets[$chosen][$os] | type) != "string" then
          error("fleet \($chosen) has no \($os) runner (class \($class))") else . end
      | if ($class | IN($github_only[])) and $chosen != "github" then
          error("class \($class) is github_only, but the policy sends it to \($chosen) on \($os)") else . end
      | ( if $class | IN($github_only[]) then
            {fleet: "github", why: (if $fleet != "policy" or ($override != "" and $os == "linux") then "github_only (overrides ignored)" else "github_only" end)}
          elif $override != "" and $os == "linux" and ($fleet != "github" or $linux_label_fleet[$override] == "github") then
            {fleet: $linux_label_fleet[$override], label: $override, why: "RUNNER_LABEL"}
          elif $fleet == "policy" then {fleet: $chosen, why: "policy"}
          elif $fleets[$fleet][$os] then
            {fleet: $fleet, why: (if $override != "" and $os == "linux" then "RUNNER_FLEET=github (RUNNER_LABEL ignored)" else "RUNNER_FLEET=\($fleet)" end)}
          else {fleet: "github", why: "RUNNER_FLEET=\($fleet), which has no \($os) runner: github"}
          end ) as $pick
      | {class: $class, os: $os, policy: $chosen, fleet: $pick.fleet,
         label: ($pick.label // $fleets[$pick.fleet][$os]), group: $groups[$pick.fleet], why: $pick.why} ]
' <<<"$policy_json")" || die "invalid policy $(printf '%q' "$policy")"

labels="$(jq -c 'reduce .[] as $r ({}; .[$r.class][$r.os] = $r.label)' <<<"$records")"
fleets="$(jq -c 'reduce .[] as $r ({}; .[$r.class][$r.os] = $r.fleet)' <<<"$records")"
groups="$(jq -c 'reduce .[] as $r ({}; .[$r.class][$r.os] = $r.group)' <<<"$records")"
pairs="$(jq -c '[.[] | {class, os}]' <<<"$records")"
for value in "$labels" "$fleets" "$groups" "$pairs"; do
  [[ "$value" != *$'\n'* ]] || die "an output spans more than one line"
done
printf '%s\n' "$labels"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'labels=%s\nfleets=%s\ngroups=%s\npairs=%s\n' "$labels" "$fleets" "$groups" "$pairs" >>"$GITHUB_OUTPUT"
fi

# Which tools ran: in CI, the runner image's yq and jq, not the .mise.toml pins make check uses.
pins="$here/../.mise.toml"
if [ -f "$pins" ]; then
  want_yq="$(grep -oE '^"aqua:mikefarah/yq" = "[^"]+"' "$pins" | grep -oE '[0-9][^"]*' || true)"
  want_jq="$(grep -oE '^jq = "[^"]+"' "$pins" | grep -oE '[0-9][^"]*' || true)"
  for tool in "yq|$yq_version|$want_yq" "jq|$jq_version|$want_jq"; do
    IFS='|' read -r name got want <<<"$tool"
    if [ -n "$want" ] && [[ "$got" != *"$want"* ]] && [ "${GITHUB_ACTIONS:-}" = true ]; then
      echo "::warning::resolve-runners ran with $name '$got', not the $want pinned in .mise.toml"
    fi
  done
fi

if jq -e 'any(.[]; .why | test("ignored"))' <<<"$records" >/dev/null; then
  msg="a RUNNER_FLEET or RUNNER_LABEL override was ignored for some jobs: see the table"
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::warning::$msg"; else echo "resolve-runners: $msg" >&2; fi
fi

table="$(jq -r '
  "| class | OS | policy fleet | runs on | runner label | why |", "|---|---|---|---|---|---|",
  (.[] | "| \(.class) | \(.os) | \(.policy) | \(.fleet) | `\(.label)` | \(.why) |")
' <<<"$records")"
printf 'RUNNER_FLEET=%s RUNNER_LABEL=%s | %s | %s\n%s\n' "$fleet" "${override:-(unset)}" "$yq_version" "$jq_version" "$table" >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # shellcheck disable=SC2016 # the backticks are Markdown code spans, not command substitution
  printf '### Runner labels\n\n`RUNNER_FLEET=%s`, `RUNNER_LABEL=%s`; %s, %s\n\n%s\n' "$fleet" "${override:-(unset)}" "$yq_version" "$jq_version" "$table" >>"$GITHUB_STEP_SUMMARY"
fi
