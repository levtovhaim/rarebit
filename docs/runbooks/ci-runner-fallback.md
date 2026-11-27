# Runbook: CI jobs aren't picked up by their runner fleet

- **Alert(s):** none yet; the CI queue-time check is planned (#67). Until then this shows up as jobs that stay queued, or as a failed `verify where the probes ran` job in the `runner policy` workflow, which also runs every Monday as a canary.
- **Service:** CI's runner fleets, routed by `ci/runner-policy.yaml` (ADR 0005)
- **Severity:** ticket (CI is blocked for the affected classes; running environments aren't touched)
- **Last fired on purpose:** 2026-11-27, on the `runner policy` workflow's first run (45956498946). With `RUNNER_FLEET=policy`, `heavy-build` on Linux ran in the `incredibuild` runner group (`Incredibuild-run-140364128517`) after a 41-second queue, and the other ten probes in `GitHub Actions`. After `gh variable set RUNNER_FLEET … --body github` and a full re-run of the same run, the resolver logged `RUNNER_FLEET=github` and all eleven ran in `GitHub Actions`; then the variable went back to `policy`. A full re-run reads the variables again, so the fix below needs no new commit.

Each job takes its `runs-on` label from the resolver (`.github/workflows/_runners.yml`, `ci/resolve-runners.sh`), which reads the policy and two repository variables:

| Variable | Values | Effect |
|---|---|---|
| `RUNNER_FLEET` | `policy` (default, also when unset), `github`, `incredibuild` | `github` or `incredibuild` forces that fleet for every class, on every OS where it has a runner (macOS has only `github`) |
| `RUNNER_LABEL` | one of the Linux labels in `fleets`, or unset | replaces the label of every Linux job; with `RUNNER_FLEET=github`, only a GitHub-hosted label applies |

Classes in the policy's `github_only` list (`docker`, `tf-plan`: they hold AWS credentials; `gate`: it decides which checks run and whether a pull request may merge, ADR 0043) stay on GitHub-hosted runners whatever the variables say. The runner measurements (`spike-runner.yml`) name their labels on purpose, so the switch doesn't move them: don't run them during a vendor outage.

## What it means

| Symptom | What's wrong |
|---|---|
| Jobs with an `incredibuild-*` label stay "Queued" / "Waiting for a runner to pick up this job" well past the usual start-up (about 2.5–3.5 minutes in the spike, under a minute in the policy's first runs) | The Incredibuild fleet isn't taking jobs: a vendor outage, the trial ended, the GitHub App was uninstalled or lost access to this repository, its runner group no longer allows this repository, or a label was renamed on their side |
| The `resolve runner labels` job fails with `resolve-runners: …` (exit 2) | A bad input, named in the message: `RUNNER_FLEET` isn't `policy`, `github` or `incredibuild`; `RUNNER_LABEL` isn't one of the Linux labels in `fleets`; or the policy is broken (a fleet or OS without a runner, a `github_only` class sent elsewhere) |
| `verify where the probes ran` fails with `still queued after 10 minutes` | The probes' fleet isn't taking jobs: the case above |
| `verify where the probes ran` fails with `in runner group '…', expected '…'` | A job ran in a fleet other than the one the policy names: a label collision, or a runner registered under a label it shouldn't have. Find out who registered it before anything else |
| Jobs on a label nobody serves stay queued for up to a day, with no error | A label in `fleets` that no runner serves. The resolver checks a label's form and, for `RUNNER_LABEL`, that it's listed, not that a runner serves it. Check `RUNNER_LABEL` first, then the policy's latest change |

## Impact on players

None: CI is blocked, running environments aren't touched.

## Diagnose (first 5 minutes)

All read-only.

1. **Which jobs are waiting, and on which labels.** A run whose resolver finished shows as `in_progress` even while its jobs wait for a runner, so look at the jobs:

   ```bash
   for run in $(gh run list --repo levtovhaim/rarebit --status in_progress --limit 50 --json databaseId --jq '.[].databaseId'); do
     gh api "repos/levtovhaim/rarebit/actions/runs/$run/jobs?per_page=100" \
       --jq ".jobs[] | select(.status == \"queued\") | [\"$run\", .name, (.labels | join(\",\")), .created_at] | @tsv"
   done
   ```

2. **The variables in effect:** `gh variable list --repo levtovhaim/rarebit`
3. **The vendor:** the Incredibuild Console (runner status, the trial's end date), whether the GitHub App is still installed for this repository, and whether the `incredibuild` runner group still allows it (the organization's settings → Actions → Runner groups).
4. **What the resolver would pick,** locally in WSL, where `mise install` provides `yq` and `jq`: `RUNNER_FLEET=<value> bash ci/resolve-runners.sh` prints the labels and a table of why.

## Fix

**The vendor fleet isn't taking jobs: switch every class to GitHub-hosted runners.** These change GitHub settings or start runs: a human runs them, or approves the exact command (CLAUDE.md → Rules, rule 2; they're ask rules in `.claude/settings.json` too).

1. Switch the fleet (or in the UI: Settings → Secrets and variables → Actions → Variables). With `RUNNER_FLEET=github`, a `RUNNER_LABEL` that names an Incredibuild label is ignored, so this one variable is enough:

   ```bash
   gh variable set RUNNER_FLEET --repo levtovhaim/rarebit --body github
   ```

2. Cancel every run with a waiting job (the run IDs from Diagnose step 1), wait until each is `completed`, and **re-run all its jobs**. Never "Re-run failed jobs" (or `gh run rerun --failed`): that keeps the resolver's old output, and the jobs go back to the same Incredibuild label.

   ```bash
   for run in <run-id> <run-id>; do
     gh run cancel "$run" --repo levtovhaim/rarebit
     until [ "$(gh run view "$run" --repo levtovhaim/rarebit --json status --jq .status)" = completed ]; do sleep 5; done
     gh run rerun "$run" --repo levtovhaim/rarebit
   done
   ```

A resolver error (exit 2) is fixed in its input: the variable, or the policy file in a PR.

**The vendor itself might be compromised** (unexpected runners, settings or statuses): set `RUNNER_FLEET=github` as above, then suspend the Incredibuild app's installation (the organization's settings → GitHub Apps → Suspend). Check what its permissions could have changed: the rulesets, webhooks, registered runners, repository variables and recent commit statuses. Treat it as an incident (`docs/postmortems/`).

## Verify

Run the `runner policy` workflow: Actions → runner policy → Run workflow, or `gh workflow run "runner policy" --repo levtovhaim/rarebit --ref main` (it starts runs: rule 2). Every job passes, and the `verify where the probes ran` summary shows every probe in the `GitHub Actions` runner group.

## Roll back or escalate

- When the vendor is back, set `RUNNER_FLEET` to `policy` again (rule 2), and run the `runner policy` workflow: the `heavy-build` Linux probe lands in the `incredibuild` group again.
- If the vendor stays down, or the trial ends, change the policy itself in a PR (every class to `github`) rather than leaving the switch on for good, and record it in a new ADR that supersedes ADR 0005.

## Prevention

- The queue-time check is planned to open an issue when the CI queue-time p95 passes a threshold, and later to be an alert on the CI dashboard (#67). Until then, the weekly `runner policy` run is the canary.
- The Incredibuild trial started on 2026-11-23 and lasts 3 months: decide before it ends whether to keep the fleet.
- Only `heavy-build` on Linux uses the vendor; every other class and OS runs on GitHub-hosted runners. A vendor outage blocks Linux heavy builds until `RUNNER_FLEET=github` is set, and the rest of CI keeps running.
