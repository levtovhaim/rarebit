# GitHub Actions reaches AWS with short-lived credentials and no stored keys (ADR 0038; CLAUDE.md →
# Rules, rule 5). Each workflow run gets a token signed by GitHub's OIDC issuer; STS trades it
# (AssumeRoleWithWebIdentity) for a role's credentials, valid for one hour. Which runs may take
# which role is decided by the token's claims, in each role's trust policy.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # No thumbprint_list: AWS verifies this issuer's certificate against its own trusted CAs.
}

locals {
  ecr_repository_arn   = "arn:aws:ecr:${var.region}:${var.account_id}:repository"
  main_repository_arns = [for name in var.main_repositories : "${local.ecr_repository_arn}/${name}"]
  pr_repository_arns   = [for name in var.pr_repositories : "${local.ecr_repository_arn}/${name}"]

  # TODO(human): which GitHub workflow runs may take each role. One IAM condition block per role,
  # comparing the token's claims (token.actions.githubusercontent.com:aud and :sub). A condition that
  # matches too much lets a pull request act as main. tests/github_oidc.tftest.hcl says what each
  # must be; `make infra` passes when they are.
  trust_conditions = {
    pr      = {}
    main    = {}
    tf_plan = {}
  }

  ecr_pull = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:DescribeImages", "ecr:GetDownloadUrlForLayer"]
  ecr_push = ["ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart"]

  # ecr:GetAuthorizationToken has no resource-level permissions: it logs in to the registry, and
  # which repositories the login may touch is decided by the statements after it.
  ecr_login = {
    Sid      = "EcrLogin"
    Effect   = "Allow"
    Action   = "ecr:GetAuthorizationToken"
    Resource = "*"
  }

  # What each role may do. No CI role gets rights on lifecycle rules, repository policies, tag
  # mutability, registry scanning or IAM.
  permissions = {
    # Pull request builds push and read PR images, and delete a PR's images when it closes.
    pr = jsonencode({
      Version = "2012-10-17"
      Statement = [
        local.ecr_login,
        {
          Sid      = "PushPrImages"
          Effect   = "Allow"
          Action   = concat(local.ecr_pull, local.ecr_push, ["ecr:BatchDeleteImage"])
          Resource = local.pr_repository_arns
        },
      ]
    })

    # main's builds push and read main images. No delete: main images go only by the lifecycle rules.
    main = jsonencode({
      Version = "2012-10-17"
      Statement = [
        local.ecr_login,
        {
          Sid      = "PushMainImages"
          Effect   = "Allow"
          Action   = concat(local.ecr_pull, local.ecr_push)
          Resource = local.main_repository_arns
        },
      ]
    })

    # Pull request plans read everything through ReadOnlyAccess (attached below), and take the state
    # lock, which is a write of a lock object (ADR 0032). The plan runs the pull request's own code,
    # so the role can't read secret values and can't touch another account's buckets.
    tf_plan = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "TakeStateLocks"
          Effect   = "Allow"
          Action   = ["s3:DeleteObject", "s3:PutObject"]
          Resource = "arn:aws:s3:::${var.state_bucket}/*.tflock"
        },
        {
          Sid    = "NoSecretValues"
          Effect = "Deny"
          Action = [
            "kms:Decrypt",
            "secretsmanager:GetSecretValue",
            "ssm:GetParameter",
            "ssm:GetParameterHistory",
            "ssm:GetParameters",
            "ssm:GetParametersByPath",
          ]
          Resource = "*"
        },
        {
          Sid       = "OnlyThisAccountsBuckets"
          Effect    = "Deny"
          Action    = "s3:*"
          Resource  = "*"
          Condition = { StringNotEquals = { "s3:ResourceAccount" = var.account_id } }
        },
      ]
    })
  }

  descriptions = {
    pr      = "GitHub Actions, pull requests: push PR images (ADR 0038)"
    main    = "GitHub Actions, main: push main images (ADR 0038)"
    tf_plan = "GitHub Actions, pull requests: terraform plan, read-only (ADR 0038)"
  }
}

resource "aws_iam_role" "this" {
  for_each = var.roles

  name                 = each.value
  path                 = var.role_path
  description          = local.descriptions[each.key]
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "GitHubActions"
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = local.trust_conditions[each.key]
      },
    ]
  })
}

resource "aws_iam_role_policy" "this" {
  for_each = aws_iam_role.this

  name   = "permissions"
  role   = each.value.id
  policy = local.permissions[each.key]
}

resource "aws_iam_role_policy_attachment" "tf_plan_read_only" {
  role       = aws_iam_role.this["tf_plan"].id
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
