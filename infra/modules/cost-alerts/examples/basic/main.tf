# Plain Terraform, no Terragrunt: `terraform init && terraform plan` in this directory, with AWS
# credentials. It shows the module on its own; the real budgets come from infra/live/_global/cost-alerts.
# Plan, don't apply: an apply would create real budgets and an anomaly monitor that email the address
# below.

provider "aws" {
  region = "eu-central-1"

  # Every AWS resource is tagged through default_tags (CLAUDE.md → Rules, rule 6), examples too.
  default_tags {
    tags = {
      Project   = "rarebit"
      Env       = "example"
      ManagedBy = "terraform"
      Source    = "infra/modules/cost-alerts/examples/basic"
    }
  }
}

module "cost_alerts" {
  source = "../.."

  alert_email = "alerts@example.com"

  budgets = {
    monthly = {
      name              = "example monthly budget"
      time_unit         = "MONTHLY"
      limit_usd         = 30
      time_period_start = "2026-12-01_00:00"
      time_period_end   = "2087-06-15_00:00"
      notifications = [
        { type = "ACTUAL", threshold = 50 },
        { type = "ACTUAL", threshold = 90 },
        { type = "FORECASTED", threshold = 100 },
      ]
    }
  }

  anomaly_monitor_name      = "example account monitor"
  anomaly_subscription_name = "example daily alerts"
}
