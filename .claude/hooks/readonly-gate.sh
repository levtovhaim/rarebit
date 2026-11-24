#!/usr/bin/env bash
# PreToolUse hook (registered in .claude/settings.json) for Bash and PowerShell calls
# that mention `aws` or `gh`:
#   - one plain, read-only `aws` or `gh api` call       -> allow (no prompt)
#   - any other command that runs `aws` or `gh api`      -> ask
#   - commands that don't mention them                   -> no decision (normal rules)
#
# It is an allowlist, so it fails closed: whatever it can't parse asks. A plain call may
# pipe into a text filter (jq, head, tail, wc, grep, tr, cut, column); anything that could
# chain, substitute, redirect or splat (; & $ ` < > ( ) @, newlines, || ) asks.
#
# This gate stops honest mistakes; it is not a security boundary. The boundary is what the
# session's AWS role and GitHub token are allowed to do.
#
# Input: the PreToolUse JSON on stdin. Output: a permission decision as JSON on stdout.
# Portable to bash 3.2 (macOS): no ${x,,}, no empty arrays under set -u.
set -eo pipefail

# The AWS CLI profile this repository's account is reached through (CLAUDE.md, .mise.toml).
project_profile=rarebit

decide() { # decide <allow|ask> <reason>
  jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}' |
    tr -d '\r'
  exit 0
}

# ---------------------------------------------------------------------------------------
# Read-only policy for aws.
#   $1 = service (e.g. ec2)   $2 = operation (e.g. describe-instances)
#   $3... = the arguments after the operation (global options can appear here too)
# Everything arrives lowercased, with '...' literals emptied to ''.
# Return 0 to run without a prompt, 1 to ask. Reads run without a prompt, except the ones
# that print secrets or create credentials, cost money, or write local files.
aws_read_only() {
  local service="$1" op="$2" a
  shift 2
  # Decrypting a parameter prints its secret, whatever the operation is called.
  for a in "$@"; do
    case "$a" in --with-decryption | --with-decryption=*) return 1 ;; esac
  done
  case "$service" in
    ce) return 1 ;;        # Cost Explorer bills $0.01 per request
    configure) return 1 ;; # prints and edits local credentials
  esac
  case "$op" in
    # Reads that print a secret or create credentials.
    get-*secret* | get-*password* | get-*token* | get-*credential* | get-*access-details*) return 1 ;;
    # Reads that write a local file.
    get-object | get-object-torrent) return 1 ;;
  esac
  case "$op" in
    describe-* | list-* | get-*) return 0 ;;
  esac
  [[ "$service $op" == "s3 ls" ]] && return 0
  return 1
}
# ---------------------------------------------------------------------------------------

check_aws() { # arguments after `aws`
  local service="" op="" t profile=""
  local -a rest=()
  if [[ $# -eq 1 && "$1" == --version ]]; then decide allow "aws --version"; fi
  while (($#)); do
    t="$1"
    shift
    case "$t" in
      --endpoint-url | --endpoint-url=* | --ca-bundle | --ca-bundle=* | --no-verify-ssl)
        decide ask "aws: $t changes where or how requests are sent"
        ;;
      --profile) profile="${1:-}" ;; # may come before or after the operation
      --profile=*) profile="${t#--profile=}" ;;
    esac
    if [[ -n "$op" ]]; then
      rest+=("$t")
      continue
    fi
    case "$t" in
      --profile | --region | --output | --query | --color | --cli-read-timeout | --cli-connect-timeout)
        (($#)) || decide ask "aws: $t needs a value"
        shift
        continue
        ;;
      --profile=* | --region=* | --output=* | --query=* | --color=* | --cli-read-timeout=* | \
        --cli-connect-timeout=* | --debug | --no-paginate | --no-cli-pager)
        continue
        ;;
      -*) decide ask "aws: global option $t is not on the gate's list" ;;
    esac
    if [[ -z "$service" ]]; then service="$t"; else op="$t"; fi
  done
  [[ -n "$op" ]] || decide ask "aws: no service and operation found"
  # A read against the wrong account is still a mistake: only the project profile auto-runs.
  profile="${profile:-$(tr '[:upper:]' '[:lower:]' <<<"${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-default}}")}"
  [[ "$profile" == "$project_profile" ]] ||
    decide ask "aws: profile '$profile' is not the project profile '$project_profile'"
  if aws_read_only "$service" "$op" ${rest[@]+"${rest[@]}"}; then
    decide allow "read-only aws call: $service $op"
  fi
  decide ask "aws $service $op is not on the read-only list"
}

check_gh_api() { # arguments after `gh api`
  local t
  while (($#)); do
    t="$1"
    shift
    case "$t" in
      --cache | --hostname | -q | --jq | -p | --preview | -t | --template)
        (($#)) || decide ask "gh api: $t needs a value"
        shift
        ;;
      --cache=* | --hostname=* | --jq=* | --preview=* | --template=* | -i | --include | \
        --paginate | --silent | --slurp | --verbose) ;;
      -*) decide ask "gh api: $t can change the method, headers or body" ;;
    esac
  done
  decide allow "read-only gh api call (GET)"
}

input="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$input" | tr -d '\r')"
[[ -n "$cmd" ]] || exit 0

# 1. Does the command mention aws or gh api as a word? Lowercase first: PowerShell is
#    case-insensitive, and grep -i is unreliable in the C locale hooks run with.
lc="$(tr '[:upper:]' '[:lower:]' <<<"$cmd")"
lead=$'(^|[[:space:];&|(){}`"\'=/\\\\])'
trail=$'([[:space:];&|(){}`"\'.]|$)'
mentions=0
grep -Eq "${lead}aws${trail}" <<<"$lc" && mentions=1
grep -Eq "${lead}gh(\\.exe)?[[:space:]]+api${trail}" <<<"$lc" && mentions=1
((mentions)) || exit 0

# 2. Is it one plain command, optionally piped into text filters? Empty the '...' literals
#    first: neither bash nor PowerShell expands anything inside single quotes.
[[ "$cmd" != *$'\n'* ]] || decide ask "multi-line command runs aws or gh api"
# shellcheck disable=SC2001 # needs a regex (every '...' literal), not a fixed string
bare="$(sed "s/'[^']*'/''/g" <<<"$lc")"
case "$bare" in
  *'||'* | *[\;\&\$\`\<\>\(\)@]*) decide ask "command chains, substitutes or redirects around aws or gh api" ;;
esac
stripped="${bare//\'\'/}"
case "$stripped" in
  *\'*) decide ask "unbalanced quote around aws or gh api" ;;
esac
IFS='|' read -ra segments <<<"$bare"
for seg in ${segments[@]+"${segments[@]:1}"}; do
  read -ra words <<<"$seg"
  case "${words[0]:-}" in
    jq | head | tail | wc | grep | tr | cut | column) ;;
    *) decide ask "aws or gh api output is piped into '${words[0]:-}'" ;;
  esac
done

# 3. The first command must be aws itself or gh api itself.
read -ra words <<<"${segments[0]:-}"
case "${words[0]:-}" in
  aws | aws.exe) check_aws ${words[@]+"${words[@]:1}"} ;;
  gh | gh.exe)
    if [[ "${words[1]:-}" == api ]]; then check_gh_api ${words[@]+"${words[@]:2}"}; fi
    ;;
esac
decide ask "aws or gh api runs inside another command"
