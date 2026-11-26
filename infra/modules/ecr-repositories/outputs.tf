output "repository_urls" {
  description = "Repository URL by name (<account>.dkr.ecr.<region>.amazonaws.com/<name>), for CI to push to and deploy values to pull from."
  value       = { for name, r in aws_ecr_repository.this : name => r.repository_url }
}

output "repository_arns" {
  description = "Repository ARN by name, for the IAM policies of the roles that push (CI) and pull (the cluster's nodes)."
  value       = { for name, r in aws_ecr_repository.this : name => r.arn }
}
