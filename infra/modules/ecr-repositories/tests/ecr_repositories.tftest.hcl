# `terraform test` in the module directory (make infra). The AWS provider is mocked: nothing reaches
# AWS and no credentials are needed. The lifecycle assertions are the specification of the rules.

mock_provider "aws" {}

variables {
  repositories = {
    "rarebit/game"    = "main"
    "rarebit/pr/game" = "pr"
  }
}

run "repositories_are_locked_down" {
  command = plan

  assert {
    condition     = length(aws_ecr_repository.this) == 2 && length(aws_ecr_lifecycle_policy.this) == 2
    error_message = "One repository and one lifecycle policy per name."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.image_tag_mutability == "IMMUTABLE"])
    error_message = "Tags must be immutable."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : one(r.image_scanning_configuration).scan_on_push])
    error_message = "Every repository scans on push."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : one(r.encryption_configuration).encryption_type == "AES256"])
    error_message = "Images must be encrypted at rest (AES256)."
  }

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.force_delete == false])
    error_message = "Terraform must not delete a repository that still holds images."
  }

  assert {
    condition = (
      aws_ecr_registry_scanning_configuration.this.scan_type == "BASIC" &&
      anytrue([
        for r in aws_ecr_registry_scanning_configuration.this.rule :
        r.scan_frequency == "SCAN_ON_PUSH" && anytrue([for f in r.repository_filter : f.filter == "*" && f.filter_type == "WILDCARD"])
      ])
    )
    error_message = "The registry scans every repository on push (basic scanning)."
  }
}

run "main_repositories_keep_the_newest_50_main_images" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_ecr_lifecycle_policy.this["rarebit/game"].policy).rules) == 2
    error_message = "A main repository has two rules: main images by count, untagged images by age."
  }

  assert {
    condition = anytrue([
      for r in jsondecode(aws_ecr_lifecycle_policy.this["rarebit/game"].policy).rules :
      r.selection.tagStatus == "tagged" && contains(try(r.selection.tagPrefixList, []), "main-") &&
      r.selection.countType == "imageCountMoreThan" && r.selection.countNumber == 50 && !can(r.selection.countUnit)
    ])
    error_message = "Main images (main-…): keep the newest 50, by count. imageCountMoreThan takes no countUnit."
  }

  assert {
    condition = !anytrue([
      for r in jsondecode(aws_ecr_lifecycle_policy.this["rarebit/game"].policy).rules :
      contains(try(r.selection.tagPrefixList, []), "pr-") || r.selection.tagStatus == "any"
    ])
    error_message = "A main repository has no rule for PR images and no \"any\" rule: only its own count may expire a main image."
  }
}

run "pr_repositories_expire_pr_images_after_7_days" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_ecr_lifecycle_policy.this["rarebit/pr/game"].policy).rules) == 2
    error_message = "A PR repository has two rules: PR images by age, untagged images by age."
  }

  assert {
    condition = anytrue([
      for r in jsondecode(aws_ecr_lifecycle_policy.this["rarebit/pr/game"].policy).rules :
      r.selection.tagStatus == "tagged" && contains(try(r.selection.tagPrefixList, []), "pr-") &&
      r.selection.countType == "sinceImagePushed" && r.selection.countUnit == "days" && r.selection.countNumber == 7
    ])
    error_message = "PR images (pr-…) expire 7 days after they were pushed."
  }

  assert {
    condition = !anytrue([
      for r in jsondecode(aws_ecr_lifecycle_policy.this["rarebit/pr/game"].policy).rules :
      contains(try(r.selection.tagPrefixList, []), "main-") || r.selection.tagStatus == "any"
    ])
    error_message = "A PR repository has no rule for main images and no \"any\" rule."
  }
}

run "every_policy_is_well_formed" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for p in aws_ecr_lifecycle_policy.this : [
        length(distinct([for r in jsondecode(p.policy).rules : r.rulePriority])) == length(jsondecode(p.policy).rules),
        alltrue([for r in jsondecode(p.policy).rules : r.action.type == "expire"]),
      ]
    ]))
    error_message = "In every policy each rule has its own rulePriority, and every action is expire."
  }

  assert {
    condition = alltrue([
      for p in aws_ecr_lifecycle_policy.this : anytrue([
        for r in jsondecode(p.policy).rules :
        r.selection.tagStatus == "untagged" && r.selection.countType == "sinceImagePushed" &&
        r.selection.countUnit == "days" && r.selection.countNumber == 1
      ])
    ])
    error_message = "Every repository expires untagged images 1 day after they were pushed."
  }
}

run "rejects_an_invalid_repository_name" {
  command = plan

  variables {
    repositories = { "Rarebit/Game" = "main" }
  }

  expect_failures = [var.repositories]
}

run "rejects_a_one_character_name" {
  command = plan

  variables {
    repositories = { "a" = "main" }
  }

  expect_failures = [var.repositories]
}

run "rejects_an_unknown_kind" {
  command = plan

  variables {
    repositories = { "rarebit/game" = "release" }
  }

  expect_failures = [var.repositories]
}
