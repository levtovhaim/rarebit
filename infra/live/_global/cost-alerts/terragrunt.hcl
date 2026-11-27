# The account's cost guardrails (ADR 0041): three budgets and an anomaly monitor, made in the console
# on 2026-11-23/24 and imported here unchanged, except for tags and the anomaly alert's threshold.
#
# The alert address is personal data: it comes from RAREBIT_ALERT_EMAIL in .mise.local.toml (git
# ignores it), the module marks it sensitive, and this unit's state, which holds it, is the one state
# the pull request plan role may not read (ADR 0041). Pull request plans skip this unit: plan it
# locally (#62).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/infra/modules//cost-alerts"
}

locals {
  account_id = include.root.locals.account_id
}

inputs = {
  # Empty when unset: the module refuses it at plan, and other units don't need it.
  alert_email = get_env("RAREBIT_ALERT_EMAIL", "")

  # Times are UTC, as AWS Budgets holds them.
  budgets = {
    monthly = {
      name              = "My Monthly Cost Budget"
      time_unit         = "MONTHLY"
      limit_usd         = 30
      time_period_start = "2026-08-01_00:00"
      time_period_end   = "2087-06-15_00:00"
      billing_view_arn  = "arn:aws:billing::${local.account_id}:billingview/primary"
      notifications = [
        { type = "ACTUAL", threshold = 50 },
        { type = "ACTUAL", threshold = 90 },
        { type = "ACTUAL", threshold = 100 },
        { type = "FORECASTED", threshold = 100 },
      ]
    }
    daily = {
      name              = "daily cost budget"
      time_unit         = "DAILY"
      limit_usd         = 4
      time_period_start = "2026-11-24_00:00"
      time_period_end   = "2087-06-15_00:00"
      notifications     = [{ type = "ACTUAL", threshold = 100 }]
    }
    # The Free plan's credits, over the plan's whole term (it ends 2027-02-26).
    credits = {
      name              = "Credit budget"
      time_unit         = "CUSTOM"
      limit_usd         = 110
      time_period_start = "2026-11-23_00:00"
      time_period_end   = "2027-02-26_23:59"
      billing_view_arn  = "arn:aws:billing::${local.account_id}:billingview/primary"
      notifications = [
        { type = "ACTUAL", threshold = 50 },
        { type = "ACTUAL", threshold = 90 },
      ]
    }
  }

  anomaly_monitor_name = "anomaly monitor rarebit"
  # Renamed from the console's name, which was a person's IAM user name.
  anomaly_subscription_name = "rarebit daily anomaly alerts"
}

# The import, once: the console-made budgets, monitor and subscription become this unit's resources
# instead of new ones. The IDs contain the account ID, so they're written at run time, not in git.
# Remove this block after the first apply (ADR 0041).
generate "imports" {
  path      = "imports.generated.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    import {
      to = aws_budgets_budget.this["monthly"]
      id = "${local.account_id}:My Monthly Cost Budget"
    }
    import {
      to = aws_budgets_budget.this["daily"]
      id = "${local.account_id}:daily cost budget"
    }
    import {
      to = aws_budgets_budget.this["credits"]
      id = "${local.account_id}:Credit budget"
    }
    import {
      to = aws_ce_anomaly_monitor.account
      id = "arn:aws:ce::${local.account_id}:anomalymonitor/fd506b51-6ee5-4e80-972a-12a916e5960e"
    }
    import {
      to = aws_ce_anomaly_subscription.account
      id = "arn:aws:ce::${local.account_id}:anomalysubscription/11db9351-955a-424c-820b-e043d8911311"
    }
  EOF
}
