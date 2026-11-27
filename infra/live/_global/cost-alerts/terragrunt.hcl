# The account's cost guardrails (ADR 0041): three budgets and an anomaly monitor, made or last changed
# in the console on 2026-11-23/24 and imported on 2026-11-27, with tags added. The anomaly
# subscription was replaced then, because the AWS provider replaces a subscription to rename it.
#
# The alert address is personal data (ADR 0042): it comes from RAREBIT_ALERT_EMAIL in .mise.local.toml
# (git ignores it), the module marks it sensitive, and this unit's state, which holds it, is listed in
# private_state_units, so the pull request plan role may not read it. Plan this unit locally; the
# plan workflow must skip it (#62). Edit these budgets only here, never in the console.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/infra/modules//cost-alerts"
}

locals {
  account_id = include.root.locals.account_id

  # This unit's state holds the alert address: it runs only while it's listed as private, so moving
  # or renaming it can't leave its state readable by pull request plans (ADR 0042).
  listed_private = regex("^listed$", contains(
    read_terragrunt_config(find_in_parent_folders("shared.hcl")).locals.private_state_units,
    path_relative_to_include("root")
  ) ? "listed" : "${path_relative_to_include("root")} is not in private_state_units")
}

inputs = {
  # Empty when unset: the module refuses it at plan, and other units don't need it.
  alert_email = local.listed_private == "listed" ? get_env("RAREBIT_ALERT_EMAIL", "") : ""

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
