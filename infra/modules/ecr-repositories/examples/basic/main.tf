# Plain Terraform, no Terragrunt: `terraform init && terraform plan` in this directory, with AWS
# credentials. It shows the module on its own; the real repositories come from infra/live/_global/ecr.
# Plan, don't apply: the repositories have prevent_destroy, and the registry scanning configuration is
# one per account and region, so an apply here would take over the real one.

provider "aws" {
  region = "eu-central-1"

  # Every AWS resource is tagged through default_tags (CLAUDE.md → Rules, rule 6), examples too.
  default_tags {
    tags = {
      Project   = "rarebit"
      Env       = "example"
      ManagedBy = "terraform"
      Source    = "infra/modules/ecr-repositories/examples/basic"
    }
  }
}

module "ecr_repositories" {
  source = "../.."

  repositories = {
    "example/service"    = "main"
    "example/pr/service" = "pr"
  }

  push_principals = {
    main = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ci/example-main"]
    pr   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ci/example-pr"]
  }

  delete_principals = {
    main = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/*"]
    pr   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ci/example-pr"]
  }
}

data "aws_caller_identity" "current" {}
