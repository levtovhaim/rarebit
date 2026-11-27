# 0041. The cost budgets and anomaly monitor are Terraform, imported from the console, not recreated

- **Status:** accepted
- **Date:** 2026-11-27
- **Deciders:** platform owner

## Context

- The account runs on the Free plan's credits ($110, until 2027-02-26). Three cost budgets and a Cost Anomaly Detection monitor were made or last changed in the console on 2026-11-23/24, before any Terraform existed:
  - a monthly budget ($30), a daily budget ($4) and a credits budget ($110 over the plan's term), all counting usage before credits and refunds;
  - an anomaly monitor over the account, with a daily email subscription at 50% above expected spend.
- The console let one of them go wrong once: the credits budget was first made counting credits, so it read $0 while the credits drained and could never fire. Only reading it back through the API showed it.
- Their alerts go to a personal email address, and the repository is public. How that address is kept out of git and out of pull request plans is ADR 0042.

## Decision

- **A module, `infra/modules/cost-alerts`, and a unit, `infra/live/_global/cost-alerts`,** hold the budgets and the monitor.
  - Every budget leaves out credits and refunds, in `UnblendedCost`; the module's tests check it.
  - `prevent_destroy` on the budgets and the monitor, which hold history (ADR 0037). Not on the subscription, which doesn't.
- **Import, don't recreate.** The unit's `import` blocks take over the console-made budgets, monitor and subscription, so their history and alert state stay. The blocks are generated at run time (their IDs contain the account ID, ADR 0035) and removed after the first apply.
- **The import changes only what we chose:**
  - default tags on all five;
  - the subscription's name, which was a person's IAM user name. The AWS provider replaces a subscription to rename it (the API itself could rename it), so the import replaced it: the plan's one destroy. Nothing is lost: the anomalies belong to the monitor. `create_before_destroy` makes a future replacement create the new subscription first;
  - the anomaly threshold: at least 50% above expected **or** at least $5 in total. That was the design on 2026-11-23, but the console subscription had only the percentage.
- **The budgets are edited only through this unit,** never in the console. A console edit drifts from the code, and the next plan would try to undo it.
- **AWS's own `Default-Services-Monitor`** and its subscription (at least $100 and 40%) stay as AWS made them, outside Terraform.

## Alternatives considered

| Option | Why not |
|---|---|
| Leave the budgets in the console | The guardrail itself would drift unseen, as the credits budget did once |
| Recreate them in Terraform and delete the console ones | Loses their history and alert state, and leaves a window with no budget at all |
| `terraform import` on the command line | A state change outside review: an `import` block shows in the plan, as `will be imported`, before anything happens |
| Keep the subscription's console name | No replacement, but a person's IAM user name in a public repository |
| Importing the default monitor too | Its threshold ($100 and 40%) can't fire at this account's spend. Ours covers the same spend; managing AWS's default adds a resource that does nothing |

## Consequences

- **Good:**
  - the budgets that guard the credits are reviewed code, and a budget that counts credits fails the tests;
  - the anomaly alert now fires on a $5 anomaly however small its percentage;
  - a threshold change shows in the plan's outputs (`notifications`), although the notification blocks themselves are hidden because they hold the address.
- **Bad / risks:**
  - **A plan of this unit costs money:** it reads the monitor and subscription through Cost Explorer, $0.01 a request, a few cents a plan. So it isn't planned on every pull request, and never on a schedule.
  - **The forecast alert needs usage history:** AWS forecasts only once it has enough, so at today's near-zero spend it may stay silent.
  - **The credits budget ends with the Free plan on 2027-02-26:** after that it stops guarding while still planning `No changes`. Retiring it means lifting `prevent_destroy` for that budget in a reviewed change.
  - **AWS's default subscription emails a different address,** not the alert address, and fires only at $100 and 40%.
- **Follow-ups (#62):**
  - fire each alert once on purpose (the runbook's "Last fired on purpose");
  - around 2027-02-19: upgrade or close the account, retire the credits budget, revisit the other limits.

## How we'll know it was right

- The first apply imports five, replaces the subscription and changes only tags and the threshold. After it, a plan of the unit shows `No changes`, and the budgets in AWS show their spend from before the import.
- An alert email arrives when a budget or the anomaly threshold is crossed.
