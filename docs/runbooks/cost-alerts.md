# Runbook: a cost alert email arrived

- **Alert(s):** AWS Budgets emails ("AWS Budgets: … has exceeded your alert threshold") and Cost Anomaly Detection emails, both from `infra/live/_global/cost-alerts`
- **Service:** the AWS account's spend (ADR 0041)
- **Severity:** page for the daily budget, the credits budget at 90% and any anomaly; ticket for the monthly budget at 50%
- **Last fired on purpose:** not yet. The budgets and the monitor were imported on 2026-11-27 and read back; no alert has been triggered deliberately.

## What it means

| Alert | What it measures |
|---|---|
| `daily cost budget` > 100% | More than $4 of usage in one UTC day, before credits. The platform's peak mode is about $8 a day, so this fires on any day it ran long, and on anything left running overnight |
| `My Monthly Cost Budget` > 50% / 90% / 100%, or forecast > 100% | Usage this calendar month, before credits, against $30. The forecast alert fires before the money is spent |
| `Credit budget` > 50% / 90% | Usage from 2026-11-23 to the end of the Free plan (2027-02-26) against the $110 of credits. At 90%, about $11 is left: roughly 30 hours of the platform at peak |
| Anomaly alert | AWS's model saw spend it didn't expect: at least 50% above expected, or at least $5 |

Billing data lags by hours, and budgets are evaluated a few times a day. By the time an email arrives, the spend started earlier.

## Impact on players

None directly. The risk is the credits running out: the Free plan ends when they do.

## Diagnose (first 5 minutes)

All read-only. The first three are free; Cost Explorer bills $0.01 per request.

1. **Is the platform up?** `plat status`, or:

   ```bash
   aws eks list-clusters --profile rarebit --region eu-central-1
   aws ec2 describe-instances --profile rarebit --region eu-central-1 --filters Name=instance-state-name,Values=running,pending --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime]' --output table
   aws ec2 describe-nat-gateways --profile rarebit --region eu-central-1 --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
   ```

2. **What was created recently** (CloudTrail keeps 90 days of management events, free):

   ```bash
   aws cloudtrail lookup-events --profile rarebit --region eu-central-1 --max-results 20 \
     --query 'Events[?starts_with(EventName, `Create`) || starts_with(EventName, `Run`)].[EventTime,EventName,Username]' --output table
   ```

3. **Other regions:** the console can create things anywhere. Repeat step 1 with `--region us-east-1` and any region the bill names.
4. **What costs money, by usage type** (one Cost Explorer request, $0.01):

   ```bash
   aws ce get-cost-and-usage --profile rarebit --time-period Start=<yesterday>,End=<today> --granularity DAILY --metrics UnblendedCost \
     --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}' --group-by Type=DIMENSION,Key=USAGE_TYPE \
     --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount!=`"0"`].[Keys[0],Metrics.UnblendedCost.Amount]' --output table
   ```

   The usage type names the service and the region (`EUC1-Aurora:ServerlessV2Usage` is an Aurora database in eu-central-1).

## Fix

- **The platform is up and nobody is working:** take it down. **State-changing:** `plat env down` is run by a human, or approved as the exact command (CLAUDE.md → Rules, rule 2).
- **Something made in the console:** find what created it (step 2) and delete it with its role, policy and log group. **State-changing:** a human runs it (rule 2). Console experiments go in as `haim-admin`, never root.
- **A real cost increase we expect** (a new always-on resource): change the limit in `infra/live/_global/cost-alerts/terragrunt.hcl` in a PR, with the cost model in `docs/cost.md`.

## Verify

- The next day, Cost Explorer's usage for that day is back to the model in `docs/cost.md`.
- `aws budgets describe-budgets --profile rarebit --account-id <account> --query 'Budgets[].[BudgetName,CalculatedSpend.ActualSpend.Amount]'` shows the spend levelling off.

## Roll back or escalate

- If the credits budget passed 90%, stop all platform work until the remaining credits and the plan for them are written down in `docs/cost.md`.

## Prevention

- Nightly teardown of the platform unless `KEEP_ALIVE_UNTIL` is set; `plat env up` states the hourly cost.
- **A budget that can't fire is the real failure mode.** Every budget leaves out credits and refunds, and the module's tests check it: the console made a credits budget that counted them once, and it read $0 while the credits drained (found on 2026-11-23 by reading it back).
- Changes to the budgets go through `_global/cost-alerts`, planned locally: the pull request plan role can't read them (ADR 0041).
