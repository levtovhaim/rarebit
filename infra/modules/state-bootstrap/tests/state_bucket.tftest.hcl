# `terraform test` in the module directory (make infra). The AWS provider is mocked: nothing reaches
# AWS and no credentials are needed. The mock fills in computed values (the bucket ARN) during plan.

mock_provider "aws" {
  override_during = plan

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::test-tfstate-000000000000-eu-central-1"
    }
  }
}

variables {
  bucket_name = "test-tfstate-000000000000-eu-central-1"
}

run "bucket_is_locked_down" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning must be on: restoring an old version is how a bad state write is undone."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "All four public access block settings must be on."
  }

  assert {
    condition     = one(aws_s3_bucket_ownership_controls.state.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be off (BucketOwnerEnforced)."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "State must be encrypted at rest (SSE-S3)."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement :
      s.Effect == "Deny" && s.Action == "s3:*" && try(s.Condition.Bool["aws:SecureTransport"], "") == "false"
    ])
    error_message = "The bucket policy must deny every request that doesn't use TLS."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement :
      s.Effect == "Deny" && try(s.Condition.NumericLessThan["s3:TlsVersion"], "") == "1.2"
    ])
    error_message = "The bucket policy must deny TLS older than 1.2."
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.state.rule[0].noncurrent_version_expiration).noncurrent_days == 90
    error_message = "Old state versions are kept 90 days by default."
  }
}

run "rejects_a_bucket_name_s3_would_refuse" {
  command = plan

  variables {
    bucket_name = "Rarebit_State"
  }

  expect_failures = [var.bucket_name]
}

run "rejects_keeping_old_versions_less_than_a_week" {
  command = plan

  variables {
    noncurrent_version_days = 1
  }

  expect_failures = [var.noncurrent_version_days]
}
