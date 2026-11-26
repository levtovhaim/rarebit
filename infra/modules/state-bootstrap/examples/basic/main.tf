# Plain Terraform, no Terragrunt: `terraform init && terraform plan` in this directory, with AWS
# credentials. It shows the module on its own; the real bucket comes from infra/live/_global/bootstrap.
# Plan, don't apply: the module's prevent_destroy means `terraform destroy` refuses to remove what an
# apply creates, until the module is edited.

provider "aws" {
  region = "eu-central-1"

  # Every AWS resource is tagged through default_tags (CLAUDE.md → Rules, rule 6), examples too.
  default_tags {
    tags = {
      Project   = "rarebit"
      Env       = "example"
      ManagedBy = "terraform"
      Source    = "infra/modules/state-bootstrap/examples/basic"
    }
  }
}

data "aws_caller_identity" "current" {}

module "state_bootstrap" {
  source = "../.."

  bucket_name = "example-tfstate-${data.aws_caller_identity.current.account_id}-eu-central-1"
}
