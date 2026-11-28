# Plain Terraform, no Terragrunt: `terraform init && terraform plan` in this directory, with AWS
# credentials. It shows the module on its own; the real VPC comes from infra/live/prod/network.
# An apply here creates a billable NAT instance and Elastic IP: plan only.

provider "aws" {
  region = "eu-central-1"

  # Every AWS resource is tagged through default_tags (CLAUDE.md → Rules, rule 6), examples too.
  default_tags {
    tags = {
      Project   = "rarebit"
      Env       = "example"
      ManagedBy = "terraform"
      Source    = "infra/modules/network/examples/basic"
    }
  }
}

module "network" {
  source = "../.."

  name            = "rarebit-example"
  cidr            = "10.90.0.0/16"
  public_subnets  = { "eu-central-1a" = "10.90.0.0/24", "eu-central-1b" = "10.90.1.0/24" }
  private_subnets = { "eu-central-1a" = "10.90.16.0/20", "eu-central-1b" = "10.90.32.0/20" }
  cluster_name    = "rarebit-example"
}
