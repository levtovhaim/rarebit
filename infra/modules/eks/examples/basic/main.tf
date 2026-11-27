# Plain Terraform, no Terragrunt: `terraform init && terraform plan` in this directory, with AWS
# credentials. It shows the module on its own; the real cluster comes from infra/live/prod/eks.
# An apply here creates a billable EKS cluster and nodes: plan only.

provider "aws" {
  region = "eu-central-1"

  # Every AWS resource is tagged through default_tags (CLAUDE.md → Rules, rule 6), examples too.
  default_tags {
    tags = {
      Project   = "rarebit"
      Env       = "example"
      ManagedBy = "terraform"
      Source    = "infra/modules/eks/examples/basic"
    }
  }
}

module "eks" {
  source = "../.."

  name               = "rarebit-example"
  kubernetes_version = "1.37"
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids
  admin_cidrs        = var.admin_cidrs
}
