# `terraform test` in the module directory (make infra). The AWS provider is mocked: nothing reaches
# AWS and no credentials are needed. The trust assertions are the specification of who may take
# which role; the permission assertions say what each role may do.

mock_provider "aws" {
  override_during = plan

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::000000000000:oidc-provider/token.actions.githubusercontent.com"
    }
  }
}

variables {
  github_repository    = "example-org/example-repo"
  github_owner_id      = "1001"
  github_repository_id = "2002"
  account_id           = "000000000000"
  region               = "eu-central-1"
  roles                = { pr = "gha-ci-pr", main = "gha-ci-main", tf_plan = "gha-tf-plan" }
  main_repositories    = ["rarebit/game"]
  pr_repositories      = ["rarebit/pr/game"]
  state_bucket         = "test-tfstate"
}

run "the_provider_trusts_github_actions_for_sts" {
  command = plan

  assert {
    condition     = aws_iam_openid_connect_provider.github.url == "https://token.actions.githubusercontent.com"
    error_message = "The provider is GitHub Actions' token issuer."
  }

  assert {
    condition     = aws_iam_openid_connect_provider.github.client_id_list == toset(["sts.amazonaws.com"])
    error_message = "Tokens are accepted only for the audience sts.amazonaws.com."
  }
}

run "each_role_trusts_exactly_one_kind_of_run" {
  command = plan

  assert {
    condition = alltrue([
      for k, r in aws_iam_role.this :
      length(jsondecode(r.assume_role_policy).Statement) == 1 &&
      jsondecode(r.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(r.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(r.assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::000000000000:oidc-provider/token.actions.githubusercontent.com"
    ])
    error_message = "Each role has one trust statement: AssumeRoleWithWebIdentity, by the GitHub OIDC provider only."
  }

  assert {
    condition = alltrue([
      for k, r in aws_iam_role.this :
      keys(jsondecode(r.assume_role_policy).Statement[0].Condition) == ["StringEquals"]
    ])
    error_message = "Trust conditions use StringEquals only: no StringLike or other wildcards, so a claim must match exactly."
  }

  assert {
    condition = alltrue([
      for k, r in aws_iam_role.this :
      try(jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"], "") == "sts.amazonaws.com"
    ])
    error_message = "Every role requires the token's audience (aud) to be sts.amazonaws.com."
  }

  # GitHub's immutable subject: repo:<owner>@<owner-id>/<name>@<repository-id>:<context>. The
  # name-only form (repo:<owner>/<name>:...) never matches a token of this repository.
  assert {
    condition     = try(jsondecode(aws_iam_role.this["pr"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"], "") == "repo:example-org@1001/example-repo@2002:pull_request"
    error_message = "The pr role: only pull_request runs of this repository (sub = repo:<owner>@<owner-id>/<name>@<repository-id>:pull_request)."
  }

  assert {
    condition     = try(jsondecode(aws_iam_role.this["main"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"], "") == "repo:example-org@1001/example-repo@2002:ref:refs/heads/main"
    error_message = "The main role: only runs for the main branch of this repository (sub = repo:<owner>@<owner-id>/<name>@<repository-id>:ref:refs/heads/main)."
  }

  assert {
    condition     = try(jsondecode(aws_iam_role.this["tf_plan"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"], "") == "repo:example-org@1001/example-repo@2002:pull_request"
    error_message = "The tf_plan role: only pull_request runs of this repository (sub = repo:<owner>@<owner-id>/<name>@<repository-id>:pull_request)."
  }
}

run "each_role_may_do_only_its_job" {
  command = plan

  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.this["pr"].policy).Statement :
      contains(flatten([s.Resource]), "arn:aws:ecr:eu-central-1:000000000000:repository/rarebit/game")
    ])
    error_message = "The pr role has no rights on a main repository."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.this["pr"].policy).Statement :
      s.Effect == "Allow" && contains(flatten([s.Action]), "ecr:PutImage") && s.Resource == ["arn:aws:ecr:eu-central-1:000000000000:repository/rarebit/pr/game"]
    ])
    error_message = "The pr role may push to the PR repositories."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.this["main"].policy).Statement :
      s.Effect == "Allow" && contains(flatten([s.Action]), "ecr:PutImage") && s.Resource == ["arn:aws:ecr:eu-central-1:000000000000:repository/rarebit/game"]
    ])
    error_message = "The main role may push to the main repositories, and only those."
  }

  assert {
    condition = !anytrue(flatten([
      for k, p in aws_iam_role_policy.this : [
        for s in jsondecode(p.policy).Statement :
        s.Effect == "Allow" && anytrue([
          for a in flatten([s.Action]) : can(regex("^(iam:|ecr:(Set|Delete|Put(Lifecycle|ImageTagMutability|Registry|ImageScanning|Replication))|ecr:\\*$|\\*$)", a))
        ])
      ]
    ]))
    error_message = "No CI role's inline policy may change IAM, repository policies, lifecycle rules, tag mutability, scanning or replication, or allow a * action."
  }

  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.this["main"].policy).Statement :
      s.Effect == "Allow" && contains(flatten([s.Action]), "ecr:BatchDeleteImage")
    ])
    error_message = "The main role can't delete images: main images go only by the lifecycle rules."
  }

  assert {
    condition     = alltrue([for r in aws_iam_role.this : r.path == "/ci/" && r.max_session_duration == 3600])
    error_message = "The roles are under /ci/, with one-hour sessions."
  }
}

run "the_plan_role_reads_configuration_and_writes_nothing" {
  command = plan

  assert {
    condition     = aws_iam_role_policy_attachment.tf_plan_read_only.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "The tf_plan role reads through ReadOnlyAccess."
  }

  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.this["tf_plan"].policy).Statement : s.Effect == "Deny"])
    error_message = "The tf_plan role's inline policy only denies: it writes nothing, not even a lock (PR plans run with -lock=false)."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.this["tf_plan"].policy).Statement :
      s.Effect == "Deny" && s.Resource == "*" && contains(flatten([s.Action]), "secretsmanager:GetSecretValue") && contains(flatten([s.Action]), "kms:Decrypt")
    ])
    error_message = "The tf_plan role can't read secret values: whoever opens a pull request controls the code that runs with it."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.this["tf_plan"].policy).Statement :
      s.Effect == "Deny" && s.Resource == "arn:aws:ssm:*:000000000000:parameter/*" && contains(flatten([s.Action]), "ssm:GetParametersByPath")
    ])
    error_message = "The tf_plan role can't read this account's SSM parameter values; AWS's public parameters stay readable."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.this["tf_plan"].policy).Statement :
      s.Effect == "Deny" && s.Resource == "*" && length(setsubtract(["account:*", "billing:*", "budgets:*", "ce:*", "invoicing:*", "payments:*", "tax:*"], flatten([s.Action]))) == 0
    ])
    error_message = "The tf_plan role can't read the account owner's contact, payment, tax or budget details, or call Cost Explorer (billed per request)."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.this["tf_plan"].policy).Statement :
      s.Effect == "Deny" && s.Resource == "*" && length(setsubtract(["sqs:ReceiveMessage", "logs:StartQuery", "logs:GetLogEvents", "dynamodb:Scan", "cloudwatch:GetMetricData"], flatten([s.Action]))) == 0
    ])
    error_message = "The tf_plan role can't read data (messages, logs, table items, metrics): a plan needs configuration only."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.this["tf_plan"].policy).Statement :
      s.Effect == "Deny" && s.Action == "s3:GetObject*" && try(s.NotResource, "") == "arn:aws:s3:::test-tfstate/*"
    ])
    error_message = "The tf_plan role reads objects only in the state bucket."
  }
}

run "each_role_has_exactly_its_policies" {
  command = plan

  assert {
    condition     = alltrue([for k, e in aws_iam_role_policies_exclusive.this : e.policy_names == toset(["permissions"])])
    error_message = "Each role has exactly one inline policy, permissions: anything added outside Terraform shows up in the plan."
  }

  assert {
    condition = (
      aws_iam_role_policy_attachments_exclusive.this["tf_plan"].policy_arns == toset(["arn:aws:iam::aws:policy/ReadOnlyAccess"]) &&
      length(aws_iam_role_policy_attachments_exclusive.this["pr"].policy_arns) == 0 &&
      length(aws_iam_role_policy_attachments_exclusive.this["main"].policy_arns) == 0
    )
    error_message = "Only the tf_plan role has a managed policy (ReadOnlyAccess); a managed policy attached outside Terraform shows up in the plan."
  }
}

run "rejects_a_missing_role" {
  command = plan

  variables {
    roles = { pr = "gha-ci-pr", main = "gha-ci-main" }
  }

  expect_failures = [var.roles]
}

run "rejects_an_extra_role" {
  command = plan

  variables {
    roles = { pr = "gha-ci-pr", main = "gha-ci-main", tf_plan = "gha-tf-plan", apply = "gha-tf-apply" }
  }

  expect_failures = [var.roles]
}

run "rejects_an_invalid_account_id" {
  command = plan

  variables {
    account_id = ""
  }

  expect_failures = [var.account_id]
}

run "rejects_a_repository_without_its_owner" {
  command = plan

  variables {
    github_repository = "example-repo"
  }

  expect_failures = [var.github_repository]
}

run "rejects_non_numeric_github_ids" {
  command = plan

  variables {
    github_owner_id      = "example-org"
    github_repository_id = ""
  }

  expect_failures = [var.github_owner_id, var.github_repository_id]
}

run "rejects_a_role_path_without_slashes" {
  command = plan

  variables {
    role_path = "ci"
  }

  expect_failures = [var.role_path]
}

run "rejects_an_empty_repository_list" {
  command = plan

  variables {
    main_repositories = []
  }

  expect_failures = [var.main_repositories]
}

run "rejects_a_repository_that_is_both_main_and_pr" {
  command = plan

  variables {
    pr_repositories = ["rarebit/pr/game", "rarebit/game"]
  }

  expect_failures = [var.pr_repositories]
}
