variable "alert_email" {
  description = "Where every budget alert and anomaly alert goes. Personal data: it comes from the environment, never from git, and is marked sensitive so plans don't print it."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[A-Za-z]{2,}$", var.alert_email))
    error_message = "Set an email address (RAREBIT_ALERT_EMAIL in .mise.local.toml for the live unit)."
  }
}

variable "budgets" {
  description = <<-EOT
    The cost budgets, by key. Each counts usage before credits and refunds, in UnblendedCost, and emails alert_email at each notification's percentage of its limit.
    Fields: name (unique); time_unit (DAILY, MONTHLY, QUARTERLY, ANNUALLY or CUSTOM); limit_usd; time_period_start and time_period_end (YYYY-MM-DD_hh:mm, UTC; the end after the start); billing_view_arn (the billing view the budget reads: the console names the account's primary view for some budgets and none for others, so set it exactly as AWS holds it, or an import plans a change); notifications (1 to 5, no duplicates: type ACTUAL for spent so far or FORECASTED for AWS's projection for the period, threshold in percent of limit_usd).
  EOT
  type = map(object({
    name              = string
    time_unit         = string
    limit_usd         = number
    time_period_start = string
    time_period_end   = string
    billing_view_arn  = optional(string)
    notifications = list(object({
      type      = string
      threshold = number
    }))
  }))

  validation {
    condition     = alltrue([for b in var.budgets : contains(["DAILY", "MONTHLY", "QUARTERLY", "ANNUALLY", "CUSTOM"], b.time_unit)])
    error_message = "time_unit is DAILY, MONTHLY, QUARTERLY, ANNUALLY or CUSTOM."
  }

  validation {
    condition     = alltrue([for b in var.budgets : b.limit_usd > 0])
    error_message = "A budget's limit is more than $0: a $0 limit makes every percentage alert fire on the first cent."
  }

  validation {
    condition     = alltrue([for b in var.budgets : length(b.notifications) > 0])
    error_message = "Every budget has at least one notification: a budget that tells nobody is no guardrail."
  }

  validation {
    condition     = alltrue([for b in var.budgets : length(b.notifications) <= 5 && length(distinct(b.notifications)) == length(b.notifications)])
    error_message = "A budget has at most 5 notifications (AWS's limit), none repeated: a repeated one would merge into one silently."
  }

  validation {
    condition     = length(distinct([for b in var.budgets : b.name])) == length(var.budgets)
    error_message = "Budget names are unique: AWS identifies a budget by its name."
  }

  validation {
    condition = alltrue([for b in var.budgets : try(timecmp(
      "${replace(b.time_period_start, "_", "T")}:00Z",
      "${replace(b.time_period_end, "_", "T")}:00Z"
    ) < 0, false)])
    error_message = "A budget's period ends after it starts."
  }

  validation {
    condition     = alltrue(flatten([for b in var.budgets : [for n in b.notifications : contains(["ACTUAL", "FORECASTED"], n.type) && n.threshold > 0]]))
    error_message = "A notification is ACTUAL or FORECASTED, at a threshold above 0 percent."
  }

  validation {
    condition = alltrue([for b in var.budgets : alltrue([
      for t in [b.time_period_start, b.time_period_end] : can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}:[0-9]{2}$", t))
    ])])
    error_message = "Write time periods as YYYY-MM-DD_hh:mm (UTC), the format AWS Budgets uses."
  }
}

variable "anomaly_monitor_name" {
  description = "Name of the cost anomaly monitor that watches the whole account."
  type        = string
}

variable "anomaly_subscription_name" {
  description = "Name of the daily anomaly alert subscription for that monitor."
  type        = string
}
