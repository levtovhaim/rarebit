# The account's cost guardrails (ADR 0041): budgets that email when spend passes a share of their
# limit, and an anomaly monitor that emails when AWS sees spend it didn't expect. They were made in the
# console first, and the live unit imports them.

resource "aws_budgets_budget" "this" {
  for_each = var.budgets

  name              = each.value.name
  budget_type       = "COST"
  time_unit         = each.value.time_unit
  limit_amount      = tostring(each.value.limit_usd)
  limit_unit        = "USD"
  time_period_start = each.value.time_period_start
  time_period_end   = each.value.time_period_end
  billing_view_arn  = each.value.billing_view_arn

  # Usage before credits and refunds, in UnblendedCost. The account runs on credits, so a budget that
  # counted them would read about $0 while the credits drain, and never fire.
  metrics = ["UnblendedCost"]
  filter_expression {
    not {
      dimensions {
        key    = "RECORD_TYPE"
        values = ["Credit", "Refund"]
      }
    }
  }

  dynamic "notification" {
    for_each = each.value.notifications
    content {
      notification_type          = notification.value.type
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = [var.alert_email]
    }
  }

  # A budget's history lives only in AWS: a replaced budget starts from nothing (ADR 0037).
  lifecycle {
    prevent_destroy = true
  }
}

# Watches the account's spend as a whole (one dimension: the linked account, which is this account).
resource "aws_ce_anomaly_monitor" "account" {
  name              = var.anomaly_monitor_name
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "LINKED_ACCOUNT"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ce_anomaly_subscription" "account" {
  name             = var.anomaly_subscription_name
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.account.arn]

  subscriber {
    type    = "EMAIL"
    address = var.alert_email
  }

  threshold_expression {
    or {
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_PERCENTAGE"
        match_options = ["GREATER_THAN_OR_EQUAL"]
        values        = ["50"]
      }
    }
    or {
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
        match_options = ["GREATER_THAN_OR_EQUAL"]
        values        = ["5"]
      }
    }
  }

  # No prevent_destroy: a subscription holds no history (the anomalies belong to the monitor), so
  # replacing it loses nothing. AWS can't rename one in place: a new name replaces it.
}
