# `terraform test` in the module directory (make infra). The AWS provider is mocked: nothing reaches
# AWS and no credentials are needed. The lifecycle assertions are the specification of the rules.

mock_provider "aws" {}

variables {
  repositories = ["rarebit/game", "rarebit/web"]
}

run "repositories_are_locked_down" {
  command = plan

  assert {
    condition     = length(aws_ecr_repository.this) == 2 && length(aws_ecr_lifecycle_policy.this) == 2
    error_message = "One repository and one lifecycle policy per name."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.image_tag_mutability == "IMMUTABLE"])
    error_message = "Tags must be immutable: a deployed tag must always mean the image that was tested."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : one(r.image_scanning_configuration).scan_on_push])
    error_message = "Every push must be scanned."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : one(r.encryption_configuration).encryption_type == "AES256"])
    error_message = "Images must be encrypted at rest (AES256)."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.force_delete == false])
    error_message = "Terraform must not delete a repository that still holds images."
  }
}

run "lifecycle_rules_expire_only_what_no_environment_uses" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_ecr_lifecycle_policy.this["rarebit/game"].policy).rules) == 3
    error_message = "Three rules: PR images, main images, untagged images."
  }

  assert {
    condition = length(distinct([
      for r in jsondecode(aws_ecr_lifecycle_policy.this["rarebit/game"].policy).rules : r.rulePriority
    ])) == 3
    error_message = "Each rule needs its own rulePriority."
  }

  assert {
    condition = alltrue([
      for r in jsondecode(aws_ecr_lifecycle_policy.this["rarebit/game"].policy).rules : r.action.type == "expire"
    ])
    error_message = "Every rule's action is expire."
  }

  assert {
    condition = !anytrue([
      for r in jsondecode(aws_ecr_lifecycle_policy.this["rarebit/game"].policy).rules : r.selection.tagStatus == "any"
    ])
    error_message = "No rule may select tagStatus \"any\": it would count main images too, and could expire one an environment runs."
  }

  assert {
    condition = anytrue([
      for r in jsondecode(aws_ecr_lifecycle_policy.this["rarebit/game"].policy).rules :
      r.selection.tagStatus == "tagged" &&
      (contains(try(r.selection.tagPrefixList, []), "pr-") || contains(try(r.selection.tagPatternList, []), "pr-*")) &&
      r.selection.countType == "sinceImagePushed" && r.selection.countUnit == "days" && r.selection.countNumber == 3
    ])
    error_message = "PR images (pr-…) expire 3 days after they were pushed."
  }

  assert {
    condition = anytrue([
      for r in jsondecode(aws_ecr_lifecycle_policy.this["rarebit/game"].policy).rules :
      r.selection.tagStatus == "tagged" &&
      (contains(try(r.selection.tagPrefixList, []), "main-") || contains(try(r.selection.tagPatternList, []), "main-*")) &&
      r.selection.countType == "imageCountMoreThan" && r.selection.countNumber == 15 && !can(r.selection.countUnit)
    ])
    error_message = "Main images (main-…): keep the newest 15, by count. imageCountMoreThan takes no countUnit."
  }

  assert {
    condition = anytrue([
      for r in jsondecode(aws_ecr_lifecycle_policy.this["rarebit/game"].policy).rules :
      r.selection.tagStatus == "untagged" &&
      r.selection.countType == "sinceImagePushed" && r.selection.countUnit == "days" && r.selection.countNumber == 1
    ])
    error_message = "Untagged images expire 1 day after they were pushed."
  }
}

run "rejects_an_invalid_repository_name" {
  command = plan

  variables {
    repositories = ["Rarebit/Game"]
  }

  expect_failures = [var.repositories]
}
