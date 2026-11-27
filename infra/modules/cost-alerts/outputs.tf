output "budget_names" {
  description = "Budget name by key, as AWS Budgets shows them."
  value       = { for key, b in aws_budgets_budget.this : key => b.name }
}

output "anomaly_monitor_arn" {
  description = "ARN of the anomaly monitor that watches the account."
  value       = aws_ce_anomaly_monitor.account.arn
}
