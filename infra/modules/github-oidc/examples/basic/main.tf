# Plain Terraform, no Terragrunt: `terraform init && terraform plan` in this directory, with AWS
# credentials. It shows the module on its own; the real roles come from infra/live/_global/github-oidc.
# Plan, don't apply: an account has one OIDC provider per issuer URL, so an apply here would collide
# with the real one.

provider "aws" {
  region = "eu-central-1"

  # Every AWS resource is tagged through default_tags (CLAUDE.md → Rules, rule 6), examples too.
  default_tags {
    tags = {
      Project   = "rarebit"
      Env       = "example"
      ManagedBy = "terraform"
      Source    = "infra/modules/github-oidc/examples/basic"
    }
  }
}

data "aws_caller_identity" "current" {}

module "github_oidc" {
  source = "../.."

  github_repository = "example-org/example-repo"
  account_id        = data.aws_caller_identity.current.account_id
  region            = "eu-central-1"
  roles             = { pr = "example-ci-pr", main = "example-ci-main", tf_plan = "example-tf-plan" }
  main_repositories = ["example/service"]
  pr_repositories   = ["example/pr/service"]
  state_bucket      = "example-tfstate"
}
