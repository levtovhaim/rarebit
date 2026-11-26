# Private ECR repositories for the service images (ADR 0036). CI pushes `pr-<number>-<sha7>` and
# `main-<sha7>` tags here (CLAUDE.md → Conventions); the cluster pulls from here.

# Encrypted with the AES256 key ECR manages, at no cost. A customer-managed KMS key would add $1/month
# and a key policy, and who may pull or push is decided by IAM on the CI and node roles (ADR 0036).
#trivy:ignore:AWS-0033
resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name = each.value

  # A tag names one image forever: `main-<sha7>` can't be pushed twice with different content, so a
  # deployed tag always means the image that was tested. A rebuild of the same commit fails to push.
  image_tag_mutability = "IMMUTABLE"

  # Basic scanning (free) on every push; findings show in the console and the API.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # A repository that still holds images can't be deleted by Terraform: delete them first, on purpose.
  force_delete = false
}

# Which images ECR deletes by itself, so the registry doesn't grow forever. The same rules for every
# repository: each service gets the same kind of tags from CI.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy     = local.lifecycle_policy
}

locals {
  # TODO(human): the lifecycle rules. They decide which images ECR deletes, and an image a running
  # environment still uses must never be one of them. tests/ecr_repositories.tftest.hcl says what the
  # rules must do; `make infra` passes when they do.
  lifecycle_policy = jsonencode({
    rules = []
  })
}
