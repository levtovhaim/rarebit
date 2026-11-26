# The S3 bucket that every Terraform unit keeps its state in (ADR 0032). Locking uses S3
# conditional writes: a `<key>.tflock` object next to each state file, so there's no DynamoDB table.

# No S3 server access logs: they need a second bucket (which would need its own logging), and S3
# delivers them best-effort. Reads and writes of state will be audited with CloudTrail data events
# instead (issue #58); until then nothing records them. Changes to the bucket's own settings are
# already in CloudTrail's management events (ADR 0032).
#trivy:ignore:AWS-0089
resource "aws_s3_bucket" "state" {
  bucket = var.bucket_name

  # Losing this bucket loses the record of everything Terraform manages, so a plan that would
  # destroy it fails. Removing it on purpose means editing this line first, in a reviewed PR.
  lifecycle {
    prevent_destroy = true
  }
}

# ACLs off: only IAM policies and the bucket policy decide who can read state.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Every write keeps the previous version: a bad apply or a corrupted state is undone by restoring
# the version before it (docs/runbooks/terraform-state.md).
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }

  # Destroying this resource suspends versioning, and then a bad write can't be undone. That happens
  # by accident when the resource is renamed without a `moved` block, so a plan that would do it fails.
  lifecycle {
    prevent_destroy = true
  }
}

# SSE-S3 (AES256): S3 holds the key, at no cost. A customer-managed KMS key would cost $1/month and
# add a key policy to get right, and IAM policies already decide who reads state (ADR 0032).
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    # No uploads encrypted with a key the caller supplies (SSE-C): whoever holds that key could
    # overwrite state with versions nobody else can read. S3 blocks SSE-C on new buckets by default;
    # this keeps it blocked whatever the default becomes.
    blocked_encryption_types = ["SSE-C"]
  }
}

# Versioning keeps every old state and every lock object forever unless something expires them.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = var.noncurrent_version_days
      newer_noncurrent_versions = var.noncurrent_versions_kept
    }

    # A released lock leaves a delete marker. S3 removes a marker only once no older versions remain
    # behind it, and the newest noncurrent_versions_kept of every key always stay, so each lock key
    # keeps about that many old lock objects and markers: a few kilobytes.
    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  # S3 rejects noncurrent-version rules until versioning is on.
  depends_on = [aws_s3_bucket_versioning.state]
}

# TLS only, TLS 1.2 or later, and nobody deletes the bucket or its history. State files hold resource
# IDs, and sometimes secrets in outputs.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyOutdatedTls"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
        Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
      },
      # Old state versions are the only way back from a bad write, so no person, role or tool may
      # delete them, or the bucket. Lifecycle expiry still works: S3 doesn't check bucket policies
      # for lifecycle actions. Terraform releases a lock with a plain DeleteObject (a delete marker),
      # which this doesn't block. To delete the bucket on purpose, remove this statement first, in a
      # reviewed PR; the account's root user can always remove the policy.
      {
        Sid       = "DenyDeletingTheBucketOrItsHistory"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:DeleteBucket", "s3:DeleteObjectVersion"]
        Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      },
    ]
  })

  # Applied after the public access block, so the bucket is never briefly without either.
  depends_on = [aws_s3_bucket_public_access_block.state]

  # Destroying the policy would drop the TLS and delete guards along with it.
  lifecycle {
    prevent_destroy = true
  }
}
