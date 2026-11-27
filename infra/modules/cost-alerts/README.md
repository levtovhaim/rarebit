# cost-alerts

The account's cost guardrails (ADR 0041): cost budgets that email when spend passes a share of their limit, and one Cost Anomaly Detection monitor over the account with a daily email subscription.

Every budget:

- **counts usage before credits and refunds** (`filter_expression` not `RECORD_TYPE` Credit, Refund), in `UnblendedCost`. The account runs on credits: a budget that counted them would read about $0 while the credits drain, and never fire;
- **emails `alert_email`** at each notification's percentage of its limit, `ACTUAL` (spent so far) or `FORECASTED` (AWS's projection for the period);
- has **`prevent_destroy`**: a budget's history lives only in AWS, and a replaced one starts from nothing (ADR 0037).

The anomaly monitor has `prevent_destroy` too: its model of expected spend is built from history. The subscription that emails about it doesn't: it holds no history, and AWS replaces a subscription to rename it. It emails once a day about anomalies worth it: the threshold is in `main.tf`, and the tests say what it is.

**`alert_email` is personal data.** It's marked sensitive, so plans print `(sensitive value)`, but state holds it in plain text: whoever can read the unit's state can read the address. The live unit takes it from the environment and its state is closed to pull request plans (ADR 0041).

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
| budgets | The cost budgets, by key. Each counts usage before credits and refunds, in UnblendedCost, and emails alert\_email at each notification's percentage of its limit. | ```map(object({ name = string time_unit = string # DAILY, MONTHLY, QUARTERLY, ANNUALLY or CUSTOM limit_usd = number time_period_start = string # YYYY-MM-DD_hh:mm, UTC time_period_end = string # YYYY-MM-DD_hh:mm, UTC # The billing view the budget reads. The console names the account's primary view for some budgets # and none for others; set it exactly as AWS holds it, or an import plans a change. billing_view_arn = optional(string) notifications = list(object({ type = string # ACTUAL (spent so far) or FORECASTED (AWS's projection for the period) threshold = number # percent of limit_usd })) }))``` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| anomaly\_monitor\_arn | ARN of the anomaly monitor that watches the account. |
| budget\_names | Budget name by key, as AWS Budgets shows them. |
<!-- END_TF_DOCS -->
