# Runbook: ci-ok fails, or a check didn't run

- **Alert(s):** none; a failed `ci-ok` on a pull request (`.github/workflows/ci.yml`). Once the `main` ruleset requires it, the merge is blocked too.
- **Service:** CI: the pull request checks (ADR 0043), run with the `.mise.toml` pins (ADR 0044)
- **Severity:** ticket (merges wait; running environments aren't touched)
- **Last fired on purpose:** not yet; the first deliberate failure is recorded here with its run.

`ci-ok` waits for every other job in the `ci` workflow and passes only when:
- the resolver (`runners`), `pick the checks` and `lint` succeeded;
- each check that `pick the checks` chose succeeded;
- each check it didn't choose was skipped, or passed.

The `ci-ok` job's summary has a table with every job's result and verdict, and the summary of `pick the checks` shows which checks ran and why.

## What it means

| Symptom | What's wrong |
|---|---|
| `ci-ok` fails, and a row in its table says `no` | That job failed or was cancelled, or a check was chosen but skipped because a job it needs failed. Open that job |
| `ci-ok` fails with an error evaluating `runs-on`, and its steps never ran | The resolver failed, so there's no runner label: `docs/runbooks/ci-runner-fallback.md` |
| A row says "ci-ok doesn't wait for this check" | A check in `ci/checks.yaml` (or one the picker chose) has no job in `ci-ok`'s `needs`. Fix `ci.yml` |
| `pick the checks` fails with `HEAD isn't GitHub's merge commit` | The pull request's checkout isn't GitHub's merge commit, so its changes are unknown. Usually a pull request with merge conflicts has no merge commit at all and no run; anything else is unexpected |
| `pick the checks` fails with `changed-checks: …` | `ci/checks.yaml` is malformed (the message says how), or the base commit is missing |
| A check didn't run, but the change needed it | The change touched a path no check covers in `ci/checks.yaml` |
| `make` fails with `command not found` | A tool the target needs isn't in that job's `tools` list in `ci.yml` |
| `Install the tools` fails | A download failed: GitHub's API limit (mise-action uses the run's token), or a tool's download host is down. The message names the tool |
| `tflint --init` fails with a rate limit | The lint job lost its `github-token: true` |

## Impact on players

None: merges wait; running environments aren't touched.

## Diagnose (first 5 minutes)

All read-only.

1. **The run's summaries:** `gh run view <run-id> --repo levtovhaim/rarebit`, then the `ci-ok` and `pick the checks` summaries in the web UI.
2. **The failed job's log:** `gh run view <run-id> --repo levtovhaim/rarebit --log-failed`.
3. **What a branch would pick,** locally, where `mise install` provides `yq` and `jq`: `bash ci/changed-checks.sh "$(git merge-base origin/main HEAD)"`.
4. **The check itself, locally:** each check is the `make` targets in its job's `targets` (CLAUDE.md → Commands).

## Fix

- **A check failed:** fix the code, push, and the pull request runs again.
- **A check didn't run when it should have:** add the path to that check in `ci/checks.yaml`, in the same pull request or a new one. A change to `ci/` runs every check, so that pull request proves the new line.
- **A missing tool:** add it to the job's `tools` in `ci.yml`, by its name in `.mise.toml`.
- **A flaky download or a cancelled job:** re-run the failed jobs. GitHub re-runs `ci-ok` with them. After a change to `RUNNER_FLEET` or `RUNNER_LABEL`, re-run all jobs instead (`docs/runbooks/ci-runner-fallback.md`).
- **`ci-ok` itself is wrong:** fix `ci/ci-ok.sh` and its specification `ci/test-ci-ok.sh` in a pull request. That pull request runs its own `ci-ok`, so the fix is checked as it lands.

Re-running a workflow is a change in GitHub (rule 2): a human runs it, or approves the exact command.

## Verify

`ci-ok` passes on the pull request, and its table shows `yes` on every row.

## Roll back or escalate

If `ci-ok` blocks merges that should pass, and the fix can't wait for a pull request, a repository admin can turn off the ruleset's required check for the time being (Settings → Rules → Rulesets → `main`). Turn it back on once the fix has merged, and record it in `docs/postmortems/`.

## Prevention

- `make check` runs `ci/test-changed-checks.sh` and `ci/test-ci-ok.sh`. They check the picker's rules, that every check is a job `ci-ok` waits for, that every path in `ci/checks.yaml` exists, and `ci-ok`'s decisions.
- Every push to `main` runs every check, so a path missing from `ci/checks.yaml` shows up there, after the merge. Once the merge queue is on (ruleset v2), it runs every check too, before the merge.
