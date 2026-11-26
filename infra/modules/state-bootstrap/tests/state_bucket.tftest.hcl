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
    condition     = contains(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).blocked_encryption_types, "SSE-C")
    error_message = "Uploads with a caller-supplied key (SSE-C) must be blocked."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement :
      s.Effect == "Deny" && s.Principal == "*" && !can(s.Condition) &&
      length(setsubtract(["s3:DeleteBucket", "s3:DeleteObjectVersion"], try(tolist(s.Action), [s.Action]))) == 0
    ])
    error_message = "The bucket policy must deny deleting the bucket and old versions to everyone, unconditionally."
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.state.rule[0].noncurrent_version_expiration).noncurrent_days == 90
    error_message = "Old state versions are kept 90 days by default."
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.state.rule[0].noncurrent_version_expiration).newer_noncurrent_versions == 20
    error_message = "The newest 20 old versions of each state file are kept by default, however old."
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.state.rule[0].expiration).expired_object_delete_marker == true
    error_message = "Delete markers with no versions behind them must be cleaned up."
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.state.rule[0].abort_incomplete_multipart_upload).days_after_initiation == 1
    error_message = "Incomplete uploads must be aborted after a day."
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

run "rejects_keeping_no_old_versions" {
  command = plan

  variables {
    noncurrent_versions_kept = 0
  }

  expect_failures = [var.noncurrent_versions_kept]
}

run "rejects_keeping_more_versions_than_s3_allows" {
  command = plan

  variables {
    noncurrent_versions_kept = 101
  }

  expect_failures = [var.noncurrent_versions_kept]
}
