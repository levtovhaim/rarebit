# Private ECR repositories for the service images (ADR 0036), in two kinds:
# - "main": `main-<sha7>` images built from main. Only main's CI role and people may push here (the
#   repository policy below, ADR 0040).
# - "pr": `pr-<number>-<sha7>` images built for pull requests, in rarebit/pr/<service>.
# IAM can limit pushes by repository but not by tag, so the two kinds live in separate repositories:
# a pull request's job can never put a `main-` tag where deployments pull from.

# Encrypted with the AES256 key ECR manages, at no cost. A customer-managed KMS key would add $1/month
# and a key policy, and who may pull or push is decided by IAM and the repository policies, not by the
# key (ADRs 0036, 0040).
#trivy:ignore:AWS-0033
resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name = each.key

  # No tag can be overwritten. A deployment still pins the digest too (ADR 0036): a tag whose image
  # was deleted or expired could be pushed again with different content.
  image_tag_mutability = "IMMUTABLE"

  # Basic scanning (free) on every push. The registry-level configuration below is the one in effect;
  # this repository-level setting keeps a scan if that configuration is ever removed.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # A repository that still holds images can't be deleted by Terraform: delete them first, on purpose.
  force_delete = false

  # And a plan that would delete a repository fails, even an empty one: a name removed from the list,
  # `apply -destroy`, or a change that forces a replacement. The _global destroy guard (ADR 0037) only
  # stops the destroy command.
  lifecycle {
    prevent_destroy = true
  }
}

# Which images ECR deletes by itself, so the registry doesn't grow forever: one rule set per kind.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy     = local.lifecycle_policies[var.repositories[each.key]]
}

# Who may push and who may delete, per kind, enforced on the repository itself (ADR 0040): a principal
# whose IAM policy allows more (a broad CI role, say) still can't push a main image. Deny only, so the
# IAM policies still decide who gets in at all. The Null condition keeps the statements to requests
# made by a principal: ECR's own lifecycle expiry is never blocked by them. The policy doesn't protect
# itself: whoever may call ecr:SetRepositoryPolicy (people today, an apply role later) can replace it.
resource "aws_ecr_repository_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "OnlyTheseMayPush"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart"]
        Condition = {
          ArnNotLike = { "aws:PrincipalArn" = var.push_principals[var.repositories[each.key]] }
          Null       = { "aws:PrincipalArn" = "false" }
        }
      },
      {
        Sid       = "OnlyTheseMayDelete"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["ecr:BatchDeleteImage"]
        Condition = {
          ArnNotLike = { "aws:PrincipalArn" = var.delete_principals[var.repositories[each.key]] }
          Null       = { "aws:PrincipalArn" = "false" }
        }
      },
    ]
  })
}

# Scan every image pushed to this account's registry in this region, whatever a repository's own
# setting says. Registry-level, so one per account and region: use this module once (in _global/ecr).
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"

    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

locals {
  # Untagged images: leftovers of failed or replaced pushes. Whether ECR also counts the untagged
  # children of a multi-arch index or an attestation here is checked with the first CI push (#62).
  untagged_rule = {
    description = "untagged images: 1 day after the push"
    selection = {
      tagStatus   = "untagged"
      countType   = "sinceImagePushed"
      countUnit   = "days"
      countNumber = 1
    }
    action = { type = "expire" }
  }

  lifecycle_policies = {
    # Keep the newest 50 main images. With 10 to 20 merges a day, that's several days of history for
    # an environment that falls behind or a rollback. An environment must not fall further behind
    # than that, or its image expires (ADR 0036).
    main = jsonencode({
      rules = [
        {
          rulePriority = 1
          description  = "main images: keep the newest 50"
          selection = {
            tagStatus     = "tagged"
            tagPrefixList = ["main-"]
            countType     = "imageCountMoreThan"
            countNumber   = 50
          }
          action = { type = "expire" }
        },
        merge(local.untagged_rule, { rulePriority = 2 }),
      ]
    })

    # PR images go 7 days after the push: long enough for a preview to survive a weekend of nightly
    # teardowns, short enough that abandoned PRs don't pile up.
    pr = jsonencode({
      rules = [
        {
          rulePriority = 1
          description  = "PR images: 7 days after the push"
          selection = {
            tagStatus     = "tagged"
            tagPrefixList = ["pr-"]
            countType     = "sinceImagePushed"
            countUnit     = "days"
            countNumber   = 7
          }
          action = { type = "expire" }
        },
        merge(local.untagged_rule, { rulePriority = 2 }),
      ]
    })
  }
}
