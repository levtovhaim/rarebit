# Runbook: a cost alert email arrived

- **Alert(s):** AWS Budgets emails ("AWS Budgets: … has exceeded your alert threshold") and Cost Anomaly Detection emails, from `infra/live/_global/cost-alerts`. AWS's own `Default-Services-Subscription` (at least $100 and 40%) emails a different address, not the alert address; treat its alert the same way.
- **Service:** the AWS account's spend (ADR 0041)
- **Severity:** an email, no pager. Act the same day on the daily budget, the credits budget at 90%, the monthly budget at 90% or more and any anomaly; within the week on the rest (the table below).
- **Last fired on purpose:** not yet. The budgets and the monitor were imported on 2026-11-27 and read back; no alert has been triggered deliberately (#62).

## What it means

| Alert | What it measures | Act |
|---|---|---|
| `daily cost budget` > 100% | More than $4 of usage in one UTC day, before credits: a day the platform ran for most of the day, or something left running overnight | same day |
| `My Monthly Cost Budget` > 50% | Usage this calendar month, before credits, against $30 | within the week |
| `My Monthly Cost Budget` > 90% or > 100% | the same, close to or past the limit | same day |
| `My Monthly Cost Budget` forecast > 100% | AWS's projection for the month passes $30, before the money is spent. AWS forecasts only once it has enough usage history, so at near-zero spend this one may never fire | same day |
| `Credit budget` > 50% | Usage from 2026-11-23 to the end of the Free plan (2027-02-26) against the $110 of credits | within the week |
| `Credit budget` > 90% | the same: about $11 of credits left | same day |
| Anomaly alert | AWS's model saw spend it didn't expect: at least 50% above expected, or at least $5 | same day |

Billing data lags by hours, and budgets are evaluated a few times a day. By the time an email arrives, the spend started earlier.

## Impact on players

None directly. The risk is the credits running out: the Free plan ends when they do.

## Diagnose (first 5 minutes)

All read-only. The first three are free; Cost Explorer bills $0.01 per request.

1. **Is the platform up?** (`plat status` once the platform CLI exists):

   ```bash
   aws eks list-clusters --profile rarebit --region eu-central-1
   aws ec2 describe-instances --profile rarebit --region eu-central-1 --filters Name=instance-state-name,Values=running,pending --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime]' --output table
   aws ec2 describe-nat-gateways --profile rarebit --region eu-central-1 --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
   ```

2. **What was created or changed recently.** CloudTrail keeps 90 days of management events, free. Most events are reads, so ask for writes only. Run it in eu-central-1 and in us-east-1 (IAM, Budgets and Cost Explorer log there):

   ```bash
   for r in eu-central-1 us-east-1; do
     aws cloudtrail lookup-events --profile rarebit --region "$r" --max-results 50 \
       --lookup-attributes AttributeKey=ReadOnly,AttributeValue=false --start-time "$(date -u -d '-2 days' +%FT%TZ)" \
       --query 'Events[].[EventTime,EventName,Username]' --output table
   done
   ```

   An event's full record can hold the parameters of the call, an alert subscription's address among them: don't paste raw events anywhere (ADR 0042).
3. **Other regions:** the console can create things anywhere. Repeat step 1 with `--region us-east-1` and any region the bill names.
4. **What costs money, by usage type** (one Cost Explorer request, $0.01):

   ```bash
   aws ce get-cost-and-usage --profile rarebit --time-period Start=<yesterday>,End=<today> --granularity DAILY --metrics UnblendedCost \
     --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}' --group-by Type=DIMENSION,Key=USAGE_TYPE \
     --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount!=`"0"`].[Keys[0],Metrics.UnblendedCost.Amount]' --output table
   ```

   The usage type names the service and the region (`EUC1-Aurora:ServerlessV2Usage` is an Aurora database in eu-central-1).

## Fix

- **The platform is up and nobody is working:** take it down. **State-changing:** a human runs the teardown (`plat env down` once it exists), or approves the exact command (CLAUDE.md → Rules, rule 2).
- **Something made in the console:** find what created it (step 2) and delete it with its role, policy and log group. **State-changing:** a human runs it (rule 2). Console experiments go in as your own IAM user, with MFA (ADR 0002), never root.
- **A real cost increase we expect** (a new always-on resource): change the limit in `infra/live/_global/cost-alerts/terragrunt.hcl` in a PR, with the cost model in `docs/cost.md`. Edit the budgets only there, never in the console: a console edit drifts from the code, and the next plan would undo it or, for a field that forces a replacement, stop on `prevent_destroy`.
- **A plan of `_global/cost-alerts`:** run it locally only. `terragrunt render --format json`, `plan -json` and `show -json` print the alert address: don't paste their output anywhere (ADR 0042).

## Verify

- The next day, Cost Explorer's usage for that day is back to the model in `docs/cost.md`.
- `aws budgets describe-budgets --profile rarebit --account-id <account> --query 'Budgets[].[BudgetName,CalculatedSpend.ActualSpend.Amount]'` shows the spend levelling off.

## Roll back or escalate

- If the credits budget passed 90%, stop all platform work until the remaining credits and the plan for them are written down in `docs/cost.md`.
- **On 2027-02-26 the Free plan and the credits budget's period end.** After that the credits budget stops guarding, and usage bills the card unless the account is closed. Around 2027-02-19: decide to upgrade or close, retire the credits budget, and revisit the other limits (#62).

## Prevention

- The platform comes down when work ends (the nightly teardown arrives with the platform CLI, and `plat env up` will state the hourly cost).
- **A budget that can't fire is the real failure mode.** Every budget leaves out credits and refunds, and the module's tests check it: the console made a credits budget that counted them once, and it read $0 while the credits drained (found on 2026-11-23 by reading it back).
- Changes to the budgets go through `_global/cost-alerts`, planned locally: the pull request plan role can't read its state (ADR 0042).
- Fire each alert once on purpose, so this runbook's first real use isn't the first time anyone sees one (#62).
