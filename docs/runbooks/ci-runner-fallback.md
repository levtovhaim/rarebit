# Runbook: CI jobs aren't picked up by their runner fleet

- **Alert(s):** none yet. The CI queue-time check comes with `plat bench` (Phase 2); until then this shows up as jobs that stay queued, or as a failed `runner policy` workflow.
- **Service:** CI's runner fleets, routed by `ci/runner-policy.yaml` (ADR 0005)
- **Severity:** same day: CI is blocked for the affected classes; running environments aren't touched
- **Last fired on purpose:** 2026-11-27, on the `runner policy` workflow's first run (45956498946). With `RUNNER_FLEET=policy`, `heavy-build` on Linux ran on `Incredibuild-run-140364128517` after a 41-second queue, and the other ten probes on `GitHub Actions <n>` runners. After `gh variable set RUNNER_FLEET … --body github` and a re-run of the same run, the resolver logged `RUNNER_FLEET=github` and all eleven ran on GitHub-hosted runners; then the variable went back to `policy`. A re-run reads the variables again, so step 3 below needs no new commit.

Each job takes its `runs-on` label from the resolver (`.github/workflows/_runners.yml`, `ci/resolve-runners.sh`), which reads the policy and two repository variables:

| Variable | Values | Effect |
|---|---|---|
| `RUNNER_FLEET` | `policy` (default, also when unset), `github`, `incredibuild` | `github` or `incredibuild` forces that fleet for every class, on every OS where it has a runner (macOS has only `github`) |
| `RUNNER_LABEL` | a runner label, or unset | replaces the label of every Linux job, whatever `RUNNER_FLEET` says |

## What it means

| Symptom | What's wrong |
|---|---|
| Jobs with an `incredibuild-*` label stay "Queued" / "Waiting for a runner to pick up this job" well past the usual 2–4 minutes | The Incredibuild fleet isn't taking jobs: a vendor outage, the trial ended, the GitHub App was uninstalled or lost access to this repository, or a label was renamed on their side |
| The `resolve runner labels` job fails with `resolve-runners: …` (exit 2) | A bad input, named in the message: `RUNNER_FLEET` isn't `policy`, `github` or `incredibuild`; `RUNNER_LABEL` isn't a label; or the policy names a fleet or OS without a runner |
| A `runner policy` probe fails with `ran on runner '…', not the expected fleet` | A label is served by a fleet other than the one the policy names (a label collision, or a vendor change) |
| Jobs on a label nobody serves stay queued forever, with no error | A typo in a label: the resolver checks the policy's structure, not that a runner exists. Only labels listed in `fleets` are ever used, and the Incredibuild ones must be in `.github/actionlint.yaml` |

## Impact on players

None: CI is blocked, running environments aren't touched.

## Diagnose (first 5 minutes)

All read-only.

1. **What's queued, and on which labels:**

   ```bash
   gh run list --repo levtovhaim/rarebit --status queued --limit 20
   gh api repos/levtovhaim/rarebit/actions/runs/<run-id>/jobs --jq '.jobs[] | [.name, .status, (.labels | join(",")), .runner_name] | @tsv'
   ```

2. **The variables in effect:** `gh variable list --repo levtovhaim/rarebit`
3. **The vendor:** the Incredibuild Console (runner status, the trial's end date), and whether the GitHub App is still installed for this repository (the organization's settings → GitHub Apps).
4. **What the resolver would pick,** locally: `RUNNER_FLEET=<value> bash ci/resolve-runners.sh` prints the labels and a table of why.

## Fix

**The vendor fleet isn't taking jobs: switch every class to GitHub-hosted runners.** These are state-changing: a human runs them, or approves the exact command (CLAUDE.md → Rules, rule 2).

1. Switch the fleet (or in the UI: Settings → Secrets and variables → Actions → Variables):

   ```bash
   gh variable set RUNNER_FLEET --repo levtovhaim/rarebit --body github
   ```

2. If `RUNNER_LABEL` names an Incredibuild label, remove it too, because it wins on Linux:

   ```bash
   gh variable delete RUNNER_LABEL --repo levtovhaim/rarebit
   ```

3. Cancel the runs stuck in the queue and start them again. A queued job keeps the label it was given, so it needs a new attempt; a re-run resolves the labels again with the new variables (seen on 2026-11-27):

   ```bash
   gh run cancel <run-id> --repo levtovhaim/rarebit
   gh run rerun <run-id> --repo levtovhaim/rarebit
   ```

A resolver error (exit 2) is fixed in its input: the variable, or the policy file in a PR.

## Verify

Run the `runner policy` workflow (Actions → runner policy → Run workflow). Every probe passes, and its summary shows each label on a `GitHub Actions <n>` runner.

## Roll back or escalate

- When the vendor is back, set `RUNNER_FLEET` to `policy` again (state-changing, rule 2), and run the `runner policy` workflow: the `heavy-build` Linux probe lands on an `Incredibuild-run-<id>` runner again.
- If the vendor stays down, or the trial ends, change the policy itself in a PR (every class to `github`) rather than leaving the switch on for good, and record it in a new ADR that supersedes ADR 0005.

## Prevention

- The queue-time check (`plat bench`, Phase 2) opens an issue when the CI queue-time p95 passes a threshold; it becomes an alert with the CI dashboard later.
- The Incredibuild trial started on 2026-11-23 and lasts 3 months: decide before it ends whether to keep the fleet.
- Only light jobs depend on a fleet that starts in seconds: the policy keeps them on GitHub-hosted runners, so a vendor problem slows heavy builds but doesn't stop the rest of CI.
