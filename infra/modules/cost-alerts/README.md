# cost-alerts

The account's cost guardrails (ADR 0041): cost budgets that email when spend passes a share of their limit, and one Cost Anomaly Detection monitor over the account with a daily email subscription.

Every budget:

- **counts usage before credits and refunds** (`filter_expression` not `RECORD_TYPE` Credit, Refund), in `UnblendedCost`. The account runs on credits: a budget that counted them would read about $0 while the credits drain, and never fire;
- **emails `alert_email`** at each notification's percentage of its limit, `ACTUAL` (spent so far) or `FORECASTED` (AWS's projection for the period);
- has **`prevent_destroy`**: a budget's history lives only in AWS, and a replaced one starts from nothing (ADR 0037).

The anomaly monitor has `prevent_destroy` too: its model of expected spend is built from history. The subscription that emails about it doesn't: it holds no history. The AWS provider replaces a subscription to rename it, and `create_before_destroy` makes the new one exist before the old one goes. It emails once a day about anomalies worth it: the threshold is in `main.tf`, and the tests say what it is.

**`alert_email` is personal data** (ADR 0042):

- it's marked sensitive, so plans print `(sensitive value)`; that hides the budgets' `notification` blocks too, so the `notifications` output lists their types and thresholds in the clear, and a threshold change shows there;
- state holds it in plain text: whoever can read the unit's state can read the address. The live unit takes it from the environment, and its state is closed to pull request plans;
- `terragrunt render --format json`, `plan -json` and `show -json` print it: never paste their output anywhere.

It's applied from `infra/live/_global/cost-alerts`, which imported the budgets and the monitor that were made in the console.

## Usage

From a Terragrunt unit under `infra/live` (the real one is `_global/cost-alerts`):

```hcl
inputs = {
  alert_email = get_env("RAREBIT_ALERT_EMAIL", "")

  budgets = {
    monthly = {
      name              = "monthly"
      time_unit         = "MONTHLY"
      limit_usd         = 30
      time_period_start = "2026-12-01_00:00" # UTC
      time_period_end   = "2087-06-15_00:00"
      notifications = [
        { type = "ACTUAL", threshold = 90 },
        { type = "FORECASTED", threshold = 100 },
      ]
    }
  }

  anomaly_monitor_name      = "account"
  anomaly_subscription_name = "daily anomaly alerts"
}
```

[`examples/basic`](examples/basic) shows it with plain Terraform (plan only). `make infra` validates the module and runs its tests (`tests/`) against a mocked AWS provider, with no credentials.

A plan reads the monitor and the subscription through the Cost Explorer API, which bills $0.01 per request: a few cents per plan. Budgets without actions cost nothing.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.17 |
| aws | 6.73.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.73.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_budgets_budget.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/budgets_budget) | resource |
| [aws_ce_anomaly_monitor.account](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/ce_anomaly_monitor) | resource |
| [aws_ce_anomaly_subscription.account](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/ce_anomaly_subscription) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alert\_email | Where every budget alert and anomaly alert goes. Personal data: it comes from the environment, never from git, and is marked sensitive so plans don't print it. | `string` | n/a | yes |
| anomaly\_monitor\_name | Name of the cost anomaly monitor that watches the whole account. | `string` | n/a | yes |
| anomaly\_subscription\_name | Name of the daily anomaly alert subscription for that monitor. | `string` | n/a | yes |
| budgets | The cost budgets, by key. Each counts usage before credits and refunds, in UnblendedCost, and emails alert\_email at each notification's percentage of its limit. Fields: name (unique); time\_unit (DAILY, MONTHLY, QUARTERLY, ANNUALLY or CUSTOM); limit\_usd; time\_period\_start and time\_period\_end (YYYY-MM-DD\_hh:mm, UTC; the end after the start); billing\_view\_arn (the billing view the budget reads: the console names the account's primary view for some budgets and none for others, so set it exactly as AWS holds it, or an import plans a change); notifications (1 to 5, no duplicates: type ACTUAL for spent so far or FORECASTED for AWS's projection for the period, threshold in percent of limit\_usd). | ```map(object({ name = string time_unit = string limit_usd = number time_period_start = string time_period_end = string billing_view_arn = optional(string) notifications = list(object({ type = string threshold = number })) }))``` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| anomaly\_monitor\_arn | ARN of the anomaly monitor that watches the account. |
| budget\_names | Budget name by key, as AWS Budgets shows them. |
| notifications | Each budget's notifications (type and threshold), not sensitive: plans hide the notification blocks because they contain alert\_email, so a threshold change shows here instead. |
<!-- END_TF_DOCS -->
