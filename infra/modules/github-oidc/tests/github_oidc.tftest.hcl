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
  github_repository = "example-org/example-repo"
  account_id        = "000000000000"
  region            = "eu-central-1"
  roles             = { pr = "gha-ci-pr", main = "gha-ci-main", tf_plan = "gha-tf-plan" }
  main_repositories = ["rarebit/game"]
  pr_repositories   = ["rarebit/pr/game"]
  state_bucket      = "test-tfstate"
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

  assert {
    condition     = try(jsondecode(aws_iam_role.this["pr"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"], "") == "repo:example-org/example-repo:pull_request"
    error_message = "The pr role: only pull_request runs of this repository (sub = repo:<owner>/<name>:pull_request)."
  }

  assert {
    condition     = try(jsondecode(aws_iam_role.this["main"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"], "") == "repo:example-org/example-repo:ref:refs/heads/main"
    error_message = "The main role: only runs for the main branch of this repository (sub = repo:<owner>/<name>:ref:refs/heads/main)."
  }

  assert {
    condition     = try(jsondecode(aws_iam_role.this["tf_plan"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"], "") == "repo:example-org/example-repo:pull_request"
    error_message = "The tf_plan role: only pull_request runs of this repository."
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
    error_message = "No CI role may change IAM, repository policies, lifecycle rules, tag mutability, scanning or replication, or use a * action."
  }

  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.this["main"].policy).Statement :
      s.Effect == "Allow" && contains(flatten([s.Action]), "ecr:BatchDeleteImage")
    ])
    error_message = "The main role can't delete images: main images go only by the lifecycle rules."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.tf_plan_read_only.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "The tf_plan role reads through ReadOnlyAccess."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.this["tf_plan"].policy).Statement :
      s.Effect == "Allow" && s.Resource == "arn:aws:s3:::test-tfstate/*.tflock"
    ])
    error_message = "The tf_plan role may write only lock objects in the state bucket."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.this["tf_plan"].policy).Statement :
      s.Effect == "Deny" && contains(flatten([s.Action]), "secretsmanager:GetSecretValue") && contains(flatten([s.Action]), "ssm:GetParameter")
    ])
    error_message = "The tf_plan role can't read secret values: a plan runs the pull request's own code."
  }

  assert {
    condition     = alltrue([for r in aws_iam_role.this : r.path == "/ci/" && r.max_session_duration == 3600])
    error_message = "The roles are under /ci/, with one-hour sessions."
  }
}

run "rejects_missing_or_extra_roles" {
  command = plan

  variables {
    roles = { pr = "gha-ci-pr", main = "gha-ci-main" }
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
