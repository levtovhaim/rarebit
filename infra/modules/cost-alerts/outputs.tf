output "budget_names" {
  description = "Budget name by key, as AWS Budgets shows them."
  value       = { for key, b in aws_budgets_budget.this : key => b.name }
}

output "notifications" {
  description = "Each budget's notifications (type and threshold), not sensitive: plans hide the notification blocks because they contain alert_email, so a threshold change shows here instead."
  value       = { for key, b in var.budgets : key => [for n in b.notifications : "${n.type} > ${n.threshold}%"] }
}

output "anomaly_monitor_arn" {
  description = "ARN of the anomaly monitor that watches the account."
  value       = aws_ce_anomaly_monitor.account.arn
}
