#!/usr/bin/env bash
# Tests for ci/changed-checks.sh and ci/checks.yaml, run by make check (the ci-tests hook).
#   Part 1: the picker's rules on a fixture file, in throwaway git repositories.
#   Part 2: the real ci/checks.yaml against .github/workflows/ci.yml and the repository: every check
#           is a job that runs only when picked, ci-ok waits for every job, and every path exists.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
picker="$here/changed-checks.sh"
real="$here/checks.yaml"
root="$(cd "$here/.." && pwd)"
ci="$root/.github/workflows/ci.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

bad() {
  fail=$((fail + 1))
  echo "FAIL: $*" >&2
}

# assert <name> <command...>: passes when the command succeeds
assert() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else bad "$name"; fi
}

# git with no system or user config, so the tests don't depend on the machine they run on
: >"$tmp/gitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

cat >"$tmp/checks.yaml" <<'EOF'
all:
  - ci/
  - Makefile
checks:
  game: [apps/game/]
  bots: [apps/bots/, apps/game/, data/categories/]
  web: [apps/web/]
  docs: [README.md]
EOF
every='["game","bots","web","docs"]'

# A repository with one commit holding a file under each path. Its config turns on what the picker
# must override: rename detection, quoted non-ASCII names, paths relative to the current directory.
new_repo() {
  rm -rf "$tmp/repo"
  git init -q -b main "$tmp/repo"
  git -C "$tmp/repo" config diff.renames true
  git -C "$tmp/repo" config core.quotePath true
  git -C "$tmp/repo" config diff.relative true
  local f
  for f in apps/game/a.ts apps/bots/b.ts apps/web/w.ts data/categories/x.json README.md Makefile ci/x.sh docs/d.md; do
    mkdir -p "$tmp/repo/$(dirname "$f")"
    echo 1 >"$tmp/repo/$f"
  done
  git -C "$tmp/repo" add -A
  git -C "$tmp/repo" commit -qm base
}

# run <args...>: the picker in the repository, with the fixture file
run() {
  (cd "$tmp/repo" && env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CI_CHECKS="${FILE:-$tmp/checks.yaml}" bash "$picker" "$@" 2>"$tmp/err")
}

# pick <name> <expected exit> <expected JSON, or empty to skip> <commands that change the repository>
# The change is committed on top of the base commit, and the picker compares HEAD~1 with HEAD.
pick() {
  local name=$1 want_exit=$2 want=$3 change=$4 out rc
  new_repo
  if ! (cd "$tmp/repo" && eval "$change" && git add -A && git commit -q --allow-empty -m change); then
    bad "$name: the change didn't apply"
    return
  fi
  out="$(run HEAD~1)"
  rc=$?
  if [ "$rc" != "$want_exit" ]; then
    bad "$name: exit $rc, want $want_exit ($(tail -n1 "$tmp/err"))"
  elif [ -n "$want" ] && [ "$out" != "$want" ]; then
    bad "$name: got $out, want $want"
  else
    pass=$((pass + 1))
  fi
}

# --- Part 1: the rules ---------------------------------------------------------------------------
pick "a changed file runs its check" 0 '["web"]' 'echo 2 >apps/web/w.ts'
pick "a path two checks cover runs both, in the file's order" 0 '["game","bots"]' 'echo 2 >apps/game/a.ts'
pick "a new file runs its check" 0 '["web"]' 'mkdir -p apps/web/new && echo n >apps/web/new/f.ts'
pick "a deleted file runs its check" 0 '["web"]' 'git rm -q apps/web/w.ts'
pick "a rename out of a check's paths still runs it" 0 '["game","bots"]' 'git mv apps/game/a.ts docs/a.ts'
pick "a rename into a check's paths runs it" 0 '["web"]' 'git mv docs/d.md apps/web/d.md'
pick "a Hebrew file name is matched (no quoting)" 0 '["bots"]' "echo '{}' >'data/categories/ערים.json'"
pick "a file name with spaces is matched" 0 '["web"]' "echo 1 >'apps/web/a b.ts'"
pick "an exact path covers that file" 0 '["docs"]' 'echo 2 >README.md'
pick "an exact path doesn't cover a longer name" 0 '[]' 'echo 1 >README.md.bak'
pick "a directory path doesn't cover a longer directory name" 0 '[]' 'mkdir -p apps/webapp && echo 1 >apps/webapp/f'
pick "a change nothing covers runs no check" 0 '[]' 'echo 2 >docs/d.md'
pick "an empty commit runs no check" 0 '[]' 'true'
pick "a change under all runs every check" 0 "$every" 'echo 2 >ci/x.sh'
pick "an exact path under all runs every check" 0 "$every" 'echo 2 >Makefile'

new_repo
(cd "$tmp/repo" && echo 2 >apps/web/w.ts && git commit -qam change)
out="$(cd "$tmp/repo/docs" && CI_CHECKS="$tmp/checks.yaml" bash "$picker" HEAD~1 2>/dev/null)"
assert "paths are from the root, even from a subdirectory with diff.relative set" test "$out" = '["web"]'

# A pull request's merge commit: its first parent is the base branch. Only the branch's own changes
# count, not what landed on the base branch meanwhile.
new_repo
(
  cd "$tmp/repo" &&
    git checkout -q -b feature && echo 2 >apps/game/a.ts && git commit -qam feature &&
    git checkout -q - && echo 2 >apps/web/w.ts && git commit -qam base-moved &&
    git merge -q --no-ff --no-edit feature
) || bad "merge commit: setup failed"
out="$(run HEAD^1)"
assert "a merge commit against its first parent picks only the branch's changes" test "$out" = '["game","bots"]'

new_repo
out="$(run --all)"
assert "--all runs every check" test "$out" = "$every"
rc=0
run deadbeef >/dev/null || rc=$?
assert "an unknown base exits 2" test "$rc" = 2
rc=0
run >/dev/null || rc=$?
assert "no argument exits 2" test "$rc" = 2
rc=0
run HEAD HEAD >/dev/null || rc=$?
assert "two arguments exit 2" test "$rc" = 2

# A malformed file exits 2: a check that matches nothing would be skipped without a word.
refuse() {
  local name=$1 rc=0
  printf '%s\n' "$2" >"$tmp/bad.yaml"
  FILE="$tmp/bad.yaml" run HEAD >/dev/null || rc=$?
  assert "refuses $name" test "$rc" = 2
}
refuse "two documents" $'all: [ci/]\nchecks: {web: [apps/web/]}\n---\nall: [ci/]'
refuse "an unknown key" $'all: [ci/]\nchecks: {web: [apps/web/]}\nextra: 1'
refuse "no all" 'checks: {web: [apps/web/]}'
refuse "an empty all" $'all: []\nchecks: {web: [apps/web/]}'
refuse "no checks" $'all: [ci/]\nchecks: {}'
refuse "a check with no paths" $'all: [ci/]\nchecks: {web: []}'
refuse "a glob" $'all: [ci/]\nchecks: {web: ["apps/*"]}'
refuse "an absolute path" $'all: [ci/]\nchecks: {web: [/apps/web/]}'
refuse "a .. segment" $'all: [ci/]\nchecks: {web: [apps/../web/]}'
refuse "a ./ prefix" $'all: [ci/]\nchecks: {web: [./apps/web/]}'
refuse "a check name a job can't have" $'all: [ci/]\nchecks: {Web_UI: [apps/web/]}'
refuse "a path that isn't a string" $'all: [ci/]\nchecks: {web: [1]}'

new_repo
(cd "$tmp/repo" && echo 2 >apps/web/w.ts && git commit -qam change)
: >"$tmp/out"
: >"$tmp/summary"
(cd "$tmp/repo" && GITHUB_OUTPUT="$tmp/out" GITHUB_STEP_SUMMARY="$tmp/summary" CI_CHECKS="$tmp/checks.yaml" bash "$picker" HEAD~1 >/dev/null 2>&1)
assert "GITHUB_OUTPUT gets one checks= line" test "$(cat "$tmp/out")" = 'checks=["web"]'
# shellcheck disable=SC2016 # the table's Markdown, matched literally
assert "the summary says why" grep -qF '| web | yes | apps/web/w.ts changed |' "$tmp/summary"
assert "the summary says what didn't run" grep -qF '| game | no | nothing it covers changed |' "$tmp/summary"

# --- Part 2: the real file, the workflow and the repository --------------------------------------
mapfile -t checks < <(yq '.checks | keys | .[]' "$real")
assert "the real file is valid" bash -c "cd '$root' && bash '$picker' --all"
assert "ci.yml exists" test -f "$ci"
for c in "${checks[@]}"; do
  # shellcheck disable=SC2016 # the expression is matched literally
  want="contains(fromJSON(needs.changes.outputs.checks), '$c')"
  assert "check $c: a job in ci.yml" test "$(yq ".jobs | has(\"$c\")" "$ci")" = true
  assert "check $c: runs only when picked" test "$(yq ".jobs[\"$c\"].if" "$ci")" = "$want"
  assert "check $c: needs the changes job" test "$(yq ".jobs[\"$c\"].needs | contains([\"changes\"])" "$ci")" = true
done
jobs="$(yq -o=json -I0 '.jobs | keys | map(select(. != "ci-ok")) | sort' "$ci")"
needs="$(yq -o=json -I0 '.jobs["ci-ok"].needs | sort' "$ci")"
assert "ci-ok waits for every other job" test "$jobs" = "$needs"
[ "$jobs" = "$needs" ] || echo "  jobs: $jobs, ci-ok needs: $needs" >&2
# always(), not !cancelled(): a cancelled run must still fail ci-ok. A skipped required check counts
# as passed, so ci-ok must never be the job that's skipped.
assert "ci-ok runs even when the run is cancelled" test "$(yq '.jobs["ci-ok"].if' "$ci")" = 'always()'
for p in $(yq '.all[], .checks[][]' "$real"); do
  assert "path $p exists" test -e "$root/$p"
  case "$p" in */) assert "path $p is a directory" test -d "$root/$p" ;; *) assert "path $p is a file" test -f "$root/$p" ;; esac
done

# The dependencies between areas that tests are known to have: a change on the right runs the check
# on the left. Add a row whenever a test starts reading another area's files.
covers() {
  yq -o=json -I0 ".checks[\"$1\"]" "$real" |
    jq -e --arg p "$2" 'any(.[]; if endswith("/") then . as $d | $p | startswith($d) else . == $p end)' >/dev/null
}
while read -r c p why; do
  assert "$c covers $p ($why)" covers "$c" "$p"
done <<'EOF'
native data/categories/x.json rarebit-cli's tests load the real word lists
validator native/hebrew-normalize/x.cc cgo links the library
validator data/categories/x.json the content tests read the word lists
web apps/game/README.md a web test checks the UI text for every error code listed there
bots apps/game/src/x.ts the integration tests run the real game servers
bots data/categories/x.json the scripted bots answer from the word lists
deploy catalog/game.yaml the chart's owner and tier labels come from the catalog
EOF

# Every workflow ci.yml runs, directly or through another one, is wiring: a change to it runs every
# check. Found from the jobs' own `uses:` (not comments), so a new reusable workflow can't be left out.
wiring=(.github/workflows/ci.yml)
todo=("$ci")
while [ "${#todo[@]}" -gt 0 ]; do
  f="${todo[0]}"
  todo=("${todo[@]:1}")
  while IFS= read -r w; do
    [[ " ${wiring[*]} " == *" $w "* ]] && continue
    wiring+=("$w")
    todo+=("$root/$w")
  done < <(yq '.jobs[] | select(has("uses")) | .uses | select(test("^\./\.github/workflows/")) | sub("^\./"; "")' "$f")
done
under_all() {
  yq -o=json -I0 '.all' "$real" |
    jq -e --arg p "$1" 'any(.[]; if endswith("/") then . as $d | $p | startswith($d) else . == $p end)' >/dev/null
}
assert "ci.yml's wiring was found (_make.yml and _runners.yml among it)" \
  test "$(printf '%s\n' "${wiring[@]}" | grep -cE '/_(make|runners)\.yml$')" = 2
for p in "${wiring[@]}" ci/checks.yaml ci/changed-checks.sh ci/ci-ok.sh ci/runner-policy.yaml .mise.toml Makefile; do
  assert "a change to $p runs every check" under_all "$p"
done

# The gate: the jobs that pick the checks and decide ci-ok never run on a vendor's runner (ADR 0043).
# shellcheck disable=SC2016 # the expression is matched literally
gate='${{ fromJSON(needs.runners.outputs.labels).gate.linux }}'
for j in changes gate-tests ci-ok; do
  assert "$j runs in class gate" test "$(yq ".jobs[\"$j\"].\"runs-on\"" "$ci")" = "$gate"
done
# Only this ci-ok can satisfy the required check: GitHub matches a check by its name, from any workflow.
assert "ci.yml has one job called ci-ok" \
  test "$(yq '[.jobs | to_entries[] | select(.key == "ci-ok" or .value.name == "ci-ok")] | length' "$ci")" = 1
for f in "$root"/.github/workflows/*.yml; do
  [ "$f" = "$ci" ] && continue
  assert "$(basename "$f") has no job called ci-ok" \
    test "$(yq '[(.jobs // {}) | to_entries[] | select(.key == "ci-ok" or .value.name == "ci-ok")] | length' "$f")" = 0
done
# A step or job that may fail without failing its job would let ci-ok pass over a failed check.
for w in "${wiring[@]}"; do
  assert "$w has no continue-on-error" test "$(grep -c 'continue-on-error' "$root/$w")" = 0
done
# A vendor runner can write Actions cache entries whatever a workflow says, so no job restores one
# (ADR 0044). The runner measurements (spike-runner.yml) keep their own, read only by themselves.
cachers="$(grep -lE 'uses:[[:space:]]*(actions/cache|jdx/mise-action|actions/setup-)' "$root"/.github/workflows/*.yml |
  grep -v '/spike-runner\.yml$' || true)"
assert "no workflow but the runner measurements restores a cache" test -z "$cachers"
[ -z "$cachers" ] || echo "  restores a cache: $cachers" >&2
assert "_make.yml never gets an OIDC token" \
  test "$(yq '[.permissions, .jobs[].permissions] | map((. // {}) | has("id-token")) | any' "$root/.github/workflows/_make.yml")" = false

echo "changed-checks tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
