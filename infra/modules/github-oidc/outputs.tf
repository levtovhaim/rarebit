output "role_arns" {
  description = "Role ARN by key (pr, main, tf_plan): the role-to-assume of each workflow job."
  value       = { for key, role in aws_iam_role.this : key => role.arn }
}

output "provider_arn" {
  description = "ARN of the IAM OIDC provider for GitHub Actions."
  value       = aws_iam_openid_connect_provider.github.arn
}
