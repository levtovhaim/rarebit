# 0041. The cost alerts are code, imported from the console, with the alert address kept out of git and out of pull request plans

- **Status:** accepted
- **Date:** 2026-11-27
- **Deciders:** platform owner

## Context

- The account runs on the Free plan's credits ($110, until 2027-02-26). Three cost budgets and a Cost Anomaly Detection monitor were made in the console on 2026-11-23/24, before any Terraform existed:
  - a monthly budget ($30), a daily budget ($4) and a credits budget ($110 over the plan's term), all counting usage before credits and refunds;
  - an anomaly monitor over the account, with a daily email subscription at 50% above expected spend.
- The console let one of them go wrong once: the credits budget was first made counting credits, so it read $0 while the credits drained and could never fire. Only reading it back through the API showed it.
- Their alerts go to a personal email address, and the repository is public.
- The pull request plan role, which anyone opening a pull request controls, reads every unit's state (ADR 0038). State holds variable values in plain text, sensitive ones included.

## Decision

- **A module, `infra/modules/cost-alerts`, and a unit, `infra/live/_global/cost-alerts`,** hold the budgets and the monitor. Every budget leaves out credits and refunds, in `UnblendedCost`; the module's tests check it. `prevent_destroy` on all of them (ADR 0037).
- **Import, don't recreate.** The unit's `import` blocks take over the console-made budgets, monitor and subscription, so their history and alert state stay. The blocks are generated at run time (their IDs contain the account ID, ADR 0035), and removed after the first apply. The import changes only what we chose:
  - default tags on all five;
  - the subscription's name, which was a person's IAM user name;
  - the anomaly threshold: at least 50% above expected **or** at least $5 in total, the design from 2026-11-23 that the console subscription lacked.
- **The alert address comes from the environment,** `RAREBIT_ALERT_EMAIL` in `.mise.local.toml` (git ignores it), as the account ID does. The module marks it sensitive, so plans print `(sensitive value)`.
- **Pull request plans can't read this unit's state.** `shared.hcl` lists `_global/cost-alerts` as a private state unit, and `gha-tf-plan` is denied `s3:GetObject*` on it. The role is already denied `budgets:*` and `ce:*` (ADR 0038), so it couldn't plan this unit anyway: it's planned locally, and later by the apply workflow (#62).
- **AWS's own `Default-Services-Monitor`** and its subscription (at least $100 and 40%) stay as AWS made them, outside Terraform.

## Alternatives considered

| Option | Why not |
|---|---|
| Leave the budgets in the console | The guardrail itself would drift unseen, as the credits budget did once |
| Recreate them in Terraform and delete the console ones | Loses their history and alert state, and leaves a window with no budget at all |
| `terraform import` on the command line | A state change outside review: an `import` block shows in the plan, as `will be imported`, before anything happens |
| The address in a variables file in git | The repository is public |
| Alerts to an SNS topic, with the email subscribed outside Terraform | Keeps the address out of state too, but adds a topic, its policy and a hand-made subscription to remember. Worth it if more people get alerts |
| Importing the default monitor too | Its threshold ($100 and 40%) can't fire at this account's spend. Ours covers the same spend; managing AWS's default adds a resource that does nothing |

## Consequences

- **Good:**
  - the budgets that guard the credits are reviewed code, and a budget that counts credits fails the tests;
  - the anomaly alert now fires on a $5 anomaly however small its percentage;
  - the alert address is in no file in git and no public log.
- **Bad / risks:**
  - **State holds the address in plain text.** People with access to the state bucket can read it; pull request plans can't. A future apply role reads it (it has to).
  - **A plan of this unit costs money:** it reads the monitor and subscription through Cost Explorer, $0.01 a request. A few cents a plan, so it isn't planned on every pull request.
  - **A unit listed as private state is invisible to pull request plans:** a change to it is reviewed from its code and planned by hand before merge.
  - **`RAREBIT_ALERT_EMAIL` unset** makes this unit's plan fail on the module's validation, by design; other units don't need it.
- **Follow-ups (#62):**
  - the plan workflow skips the units in `private_state_units`;
  - fire each alert once on purpose (the runbook's "Last fired on purpose").

## How we'll know it was right

- After the import, a plan of the unit shows `No changes`, and the budgets in AWS show their spend from before the import.
- IAM's policy simulator shows `gha-tf-plan` denied `s3:GetObject` on `_global/cost-alerts/terraform.tfstate` and allowed on other units' state.
- An alert email arrives when a budget or the anomaly threshold is crossed.
