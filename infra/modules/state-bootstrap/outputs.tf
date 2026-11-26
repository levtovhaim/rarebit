output "bucket_name" {
  description = "Name of the state bucket, for the backend configuration of every other unit."
  value       = aws_s3_bucket.state.id
}

output "bucket_arn" {
  description = "ARN of the state bucket, for IAM policies that read or write state (the CI plan and apply roles)."
  value       = aws_s3_bucket.state.arn
}
