# Plain Terraform, no Terragrunt: `terraform init && terraform plan` in this directory, with AWS
# credentials. It shows the module on its own; the real bucket comes from infra/live/_global/bootstrap.

provider "aws" {
  region = "eu-central-1"
}

data "aws_caller_identity" "current" {}

module "state_bootstrap" {
  source = "../.."

  bucket_name = "example-tfstate-${data.aws_caller_identity.current.account_id}-eu-central-1"
}
