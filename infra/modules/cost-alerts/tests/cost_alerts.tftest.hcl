# `terraform test` in the module directory (make infra). The AWS provider is mocked: nothing reaches
# AWS and no credentials are needed. The assertions are the specification of when the account emails:
# what each budget counts, and which anomalies are worth an alert.

mock_provider "aws" {
  override_during = plan

  mock_resource "aws_ce_anomaly_monitor" {
    defaults = {
      arn = "arn:aws:ce::000000000000:anomalymonitor/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  alert_email = "alerts@example.com"
  budgets = {
    monthly = {
      name              = "example monthly"
      time_unit         = "MONTHLY"
      limit_usd         = 30
      time_period_start = "2026-08-01_00:00"
      time_period_end   = "2087-06-15_00:00"
      notifications = [
        { type = "ACTUAL", threshold = 50 },
        { type = "FORECASTED", threshold = 100 },
      ]
    }
    credits = {
      name              = "example credits"
      time_unit         = "CUSTOM"
      limit_usd         = 110
      time_period_start = "2026-11-23_00:00"
      time_period_end   = "2027-02-26_23:59"
      billing_view_arn  = "arn:aws:billing::000000000000:billingview/primary"
      notifications     = [{ type = "ACTUAL", threshold = 90 }]
    }
  }
  anomaly_monitor_name      = "example monitor"
  anomaly_subscription_name = "example subscription"
}

run "every_budget_counts_usage_before_credits" {
  command = plan

  assert {
    condition = alltrue([
      for b in aws_budgets_budget.this :
      b.filter_expression[0].not[0].dimensions[0].key == "RECORD_TYPE" &&
      toset(b.filter_expression[0].not[0].dimensions[0].values) == toset(["Credit", "Refund"])
    ])
    error_message = "Every budget leaves out credits and refunds: on a credits plan, a budget that counts them reads $0 and never fires."
  }
}

run "budgets_are_built_as_given" {
  command = plan

  assert {
    condition     = alltrue([for b in aws_budgets_budget.this : b.metrics == tolist(["UnblendedCost"]) && b.budget_type == "COST" && b.limit_unit == "USD"])
    error_message = "Every budget is a COST budget in USD, measured in UnblendedCost."
  }

  assert {
    condition     = aws_budgets_budget.this["monthly"].limit_amount == "30" && aws_budgets_budget.this["credits"].time_unit == "CUSTOM"
    error_message = "Each budget gets its own limit and period."
  }

  assert {
    condition     = aws_budgets_budget.this["credits"].billing_view_arn == "arn:aws:billing::000000000000:billingview/primary" && aws_budgets_budget.this["monthly"].billing_view_arn == null
    error_message = "A budget names a billing view only when given one, so an imported budget keeps the view AWS holds."
  }
}

run "every_alert_goes_to_the_alert_email" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for b in aws_budgets_budget.this : [
        for n in b.notification :
        n.subscriber_email_addresses == toset(["alerts@example.com"]) && n.comparison_operator == "GREATER_THAN" && n.threshold_type == "PERCENTAGE"
      ]
    ]))
    error_message = "Every budget notification emails alert_email, at a percentage of the limit."
  }

  assert {
    condition     = [for s in aws_ce_anomaly_subscription.account.subscriber : s.address] == ["alerts@example.com"]
    error_message = "The anomaly subscription emails alert_email."
  }
}

run "each_budget_has_exactly_its_notifications" {
  command = plan

  assert {
    condition = (
      length(aws_budgets_budget.this["monthly"].notification) == 2 &&
      anytrue([for n in aws_budgets_budget.this["monthly"].notification : n.notification_type == "FORECASTED" && n.threshold == 100])
    )
    error_message = "A budget has exactly the notifications it was given, forecasts included."
  }

  assert {
    condition     = output.notifications == { monthly = ["ACTUAL > 50%", "FORECASTED > 100%"], credits = ["ACTUAL > 90%"] }
    error_message = "The notifications output lists each budget's notifications in the clear, since plans hide the blocks that hold the address."
  }
}

run "the_subscription_listens_to_its_monitor_daily" {
  command = plan

  assert {
    condition     = aws_ce_anomaly_subscription.account.monitor_arn_list == tolist(["arn:aws:ce::000000000000:anomalymonitor/00000000-0000-0000-0000-000000000000"]) && aws_ce_anomaly_subscription.account.frequency == "DAILY"
    error_message = "The subscription listens to this module's monitor only, once a day."
  }
}

run "the_monitor_watches_the_whole_account" {
  command = plan

  assert {
    condition     = aws_ce_anomaly_monitor.account.monitor_type == "DIMENSIONAL" && aws_ce_anomaly_monitor.account.monitor_dimension == "LINKED_ACCOUNT"
    error_message = "One monitor over the account's total spend (dimension LINKED_ACCOUNT)."
  }
}

# The alert condition: an anomaly is worth an email when it's at least 50% above what AWS expected,
# or at least $5 in total, whichever comes first. At today's near-zero spend the percentage fires on
# almost anything; once the platform runs, the $5 catches a big anomaly on a big day.
run "an_anomaly_is_worth_an_email_at_50_percent_or_5_dollars" {
  command = plan

  assert {
    condition     = length(aws_ce_anomaly_subscription.account.threshold_expression) == 1
    error_message = "The subscription has a threshold_expression."
  }

  assert {
    condition = (
      length(try(aws_ce_anomaly_subscription.account.threshold_expression[0].or, [])) == 2 &&
      length(try(aws_ce_anomaly_subscription.account.threshold_expression[0].and, [])) == 0
    )
    error_message = "Two conditions joined by or (either one alerts), not and (both needed)."
  }

  assert {
    condition = anytrue([
      for c in try(aws_ce_anomaly_subscription.account.threshold_expression[0].or, []) :
      try(c.dimension[0].key, "") == "ANOMALY_TOTAL_IMPACT_PERCENTAGE" &&
      toset(try(c.dimension[0].match_options, [])) == toset(["GREATER_THAN_OR_EQUAL"]) &&
      toset(try(c.dimension[0].values, [])) == toset(["50"])
    ])
    error_message = "One condition: total impact at least 50% of the expected spend (ANOMALY_TOTAL_IMPACT_PERCENTAGE, GREATER_THAN_OR_EQUAL, \"50\")."
  }

  assert {
    condition = anytrue([
      for c in try(aws_ce_anomaly_subscription.account.threshold_expression[0].or, []) :
      try(c.dimension[0].key, "") == "ANOMALY_TOTAL_IMPACT_ABSOLUTE" &&
      toset(try(c.dimension[0].match_options, [])) == toset(["GREATER_THAN_OR_EQUAL"]) &&
      toset(try(c.dimension[0].values, [])) == toset(["5"])
    ])
    error_message = "The other condition: total impact at least $5 (ANOMALY_TOTAL_IMPACT_ABSOLUTE, GREATER_THAN_OR_EQUAL, \"5\")."
  }
}

run "rejects_a_missing_email" {
  command = plan

  variables {
    alert_email = ""
  }

  expect_failures = [var.alert_email]
}

run "rejects_a_budget_without_notifications" {
  command = plan

  variables {
    budgets = {
      silent = {
        name              = "silent"
        time_unit         = "MONTHLY"
        limit_usd         = 10
        time_period_start = "2026-08-01_00:00"
        time_period_end   = "2087-06-15_00:00"
        notifications     = []
      }
    }
  }

  expect_failures = [var.budgets]
}

run "rejects_a_zero_limit" {
  command = plan

  variables {
    budgets = {
      zero = {
        name              = "zero"
        time_unit         = "MONTHLY"
        limit_usd         = 0
        time_period_start = "2026-08-01_00:00"
        time_period_end   = "2087-06-15_00:00"
        notifications     = [{ type = "ACTUAL", threshold = 100 }]
      }
    }
  }

  expect_failures = [var.budgets]
}

run "rejects_a_badly_written_period" {
  command = plan

  variables {
    budgets = {
      dated = {
        name              = "dated"
        time_unit         = "MONTHLY"
        limit_usd         = 10
        time_period_start = "2026-08-01"
        time_period_end   = "2087-06-15_00:00"
        notifications     = [{ type = "ACTUAL", threshold = 100 }]
      }
    }
  }

  expect_failures = [var.budgets]
}

run "rejects_a_period_that_ends_before_it_starts" {
  command = plan

  variables {
    budgets = {
      backwards = {
        name              = "backwards"
        time_unit         = "CUSTOM"
        limit_usd         = 10
        time_period_start = "2027-02-26_00:00"
        time_period_end   = "2026-11-23_00:00"
        notifications     = [{ type = "ACTUAL", threshold = 100 }]
      }
    }
  }

  expect_failures = [var.budgets]
}

run "rejects_an_unknown_time_unit" {
  command = plan

  variables {
    budgets = {
      weekly = {
        name              = "weekly"
        time_unit         = "WEEKLY"
        limit_usd         = 10
        time_period_start = "2026-08-01_00:00"
        time_period_end   = "2087-06-15_00:00"
        notifications     = [{ type = "ACTUAL", threshold = 100 }]
      }
    }
  }

  expect_failures = [var.budgets]
}

run "rejects_an_unknown_notification_type" {
  command = plan

  variables {
    budgets = {
      odd = {
        name              = "odd"
        time_unit         = "MONTHLY"
        limit_usd         = 10
        time_period_start = "2026-08-01_00:00"
        time_period_end   = "2087-06-15_00:00"
        notifications     = [{ type = "EXPECTED", threshold = 100 }]
      }
    }
  }

  expect_failures = [var.budgets]
}

run "rejects_more_than_five_notifications" {
  command = plan

  variables {
    budgets = {
      noisy = {
        name              = "noisy"
        time_unit         = "MONTHLY"
        limit_usd         = 10
        time_period_start = "2026-08-01_00:00"
        time_period_end   = "2087-06-15_00:00"
        notifications     = [for t in [10, 20, 30, 40, 50, 60] : { type = "ACTUAL", threshold = t }]
      }
    }
  }

  expect_failures = [var.budgets]
}

run "rejects_a_repeated_notification" {
  command = plan

  variables {
    budgets = {
      twice = {
        name              = "twice"
        time_unit         = "MONTHLY"
        limit_usd         = 10
        time_period_start = "2026-08-01_00:00"
        time_period_end   = "2087-06-15_00:00"
        notifications     = [{ type = "ACTUAL", threshold = 90 }, { type = "ACTUAL", threshold = 90 }]
      }
    }
  }

  expect_failures = [var.budgets]
}

run "rejects_two_budgets_with_one_name" {
  command = plan

  variables {
    budgets = {
      a = {
        name              = "same"
        time_unit         = "MONTHLY"
        limit_usd         = 10
        time_period_start = "2026-08-01_00:00"
        time_period_end   = "2087-06-15_00:00"
        notifications     = [{ type = "ACTUAL", threshold = 90 }]
      }
      b = {
        name              = "same"
        time_unit         = "DAILY"
        limit_usd         = 1
        time_period_start = "2026-08-01_00:00"
        time_period_end   = "2087-06-15_00:00"
        notifications     = [{ type = "ACTUAL", threshold = 100 }]
      }
    }
  }

  expect_failures = [var.budgets]
}
