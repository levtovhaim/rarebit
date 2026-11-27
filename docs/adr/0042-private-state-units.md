# 0042. A unit whose state holds personal data is private: its value comes from the environment, and pull request plans can't read it

- **Status:** accepted; supersedes ADR 0038 in part (the plan role reads every unit's state)
- **Date:** 2026-11-27
- **Deciders:** platform owner

## Context

- The cost alerts (ADR 0041) email a personal address. The repository is public, and so are its Actions logs.
- `gha-tf-plan`, the pull request plan role, runs whatever code the pull request brings (ADR 0038). It reads every unit's state through `ReadOnlyAccess`.
- State holds every input in plain text, sensitive ones included. A `sensitive` variable only keeps the value out of plan output.
- The address is in AWS in more places than state:
  - the Budgets and Cost Explorer APIs, which the plan role is already denied (ADR 0038);
  - **CloudTrail's event history:** each `CreateAnomalySubscription` call records the subscriber's address in its parameters (checked on 2026-11-27: both such events in us-east-1 have it; the Budgets events redact theirs), and `ReadOnlyAccess` allows `cloudtrail:LookupEvents`. The history keeps 90 days and can't be deleted.

## Decision

- **The value comes from the environment:** `RAREBIT_ALERT_EMAIL` in `.mise.local.toml`, which git ignores, the way the account ID does (ADR 0035). The module marks it `sensitive`.
- **`private_state_units` in `infra/live/_global/shared.hcl` lists the units whose state holds such values** (today `_global/cost-alerts`). The github-oidc module turns the list into a `NoPrivateState` Deny of `s3:GetObject*` on those state keys, for the default workspace and any other (`env:/*/<unit>/*`).
- **The list can't go stale silently:**
  - the github-oidc unit refuses a listed path that isn't a unit;
  - a private unit refuses to run unless its own path is listed. So moving or renaming one can't leave its state readable.
- **The plan role can't read CloudTrail's event history** (`cloudtrail:LookupEvents`, `cloudtrail:GetQueryResults`, in its `NoDataReads`). A plan never needs it.
- **Pull request plans skip private units;** they're planned locally, and later by the apply workflow behind a protected environment (#62).
- **The order:** list a unit and apply github-oidc **before** the unit's first apply, so its state is never readable, not even for a moment.
- **A `make check` hook (`no-alert-address`)** fails when any file contains the value of `RAREBIT_ALERT_EMAIL`. gitleaks doesn't look for email addresses.

## Alternatives considered

| Option | Why not |
|---|---|
| The value in a variables file in git | The repository is public |
| Only `sensitive = true` | Hides the value in plans, not in state, CloudTrail or `-json` output |
| Alerts to an SNS topic, with the email subscribed outside Terraform | Keeps the address out of state too, but adds a topic, its policy and a hand-made subscription to remember. Worth it if more people get alerts |
| A separate state bucket for private units | A second bucket to bootstrap, guard and back up, for one unit. A Deny on its keys gives the same protection against the plan role |
| The plan role behind an environment with a required reviewer | Every pull request plan would wait for a click (ADR 0038); a private unit isn't planned by it anyway |

## Consequences

- **Good:**
  - the address is in no file in git and in nothing the plan role can read: state, the Budgets and Cost Explorer APIs, CloudTrail history;
  - the pattern works for the next unit with a secret or personal value: list it, apply github-oidc, then apply the unit.
- **Bad / risks:**
  - **State still holds the value in plain text.** People with access to the state bucket can read it, and so will the future apply role (it has to).
  - **Some commands print the value:** `terragrunt render --format json`, `plan -json` and `show -json`. Never paste their output anywhere, and the apply workflow mustn't upload plan JSON or run Infracost on a private unit (#62).
  - **The two `CreateAnomalySubscription` events stay in CloudTrail's history until about 2027-02-25,** readable by people with `LookupEvents`, not by the plan role.
  - **A private unit is invisible to pull request plans:** a change to it is reviewed from its code and planned by hand before merge.
  - **`RAREBIT_ALERT_EMAIL` unset** makes the cost-alerts unit's plan fail on the module's validation, by design; other units don't need it.
- **Follow-ups (#62):**
  - the plan workflow skips the units in `private_state_units`;
  - the apply workflow takes the address from a secret of its protected environment, never a repository variable: a provider error can echo a value Terraform marks sensitive, and only GitHub's secret masking covers that.

## How we'll know it was right

- IAM's policy simulator shows `gha-tf-plan` denied `s3:GetObject` on `_global/cost-alerts/terraform.tfstate` and `cloudtrail:LookupEvents`, and allowed on other units' state.
- The `no-alert-address` hook passes on every commit, and a file with the address in it fails it.
