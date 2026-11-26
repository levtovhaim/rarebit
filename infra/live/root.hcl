# Shared by every unit under infra/live: each unit's terragrunt.hcl `include`s this file. It generates
# the provider and the backend, so a unit only says which module it runs and with which inputs
# (ADR 0033).

terraform_version_constraint  = "~> 1.17"
terragrunt_version_constraint = "~> 1.2"

locals {
  # The one AWS account every unit may run in. It isn't committed (the repo is public): set it in
  # .mise.local.toml, which git ignores (infra/README.md). get_env without a default fails when the
  # variable is unset, so no unit runs without it.
  account_id = get_env("RAREBIT_AWS_ACCOUNT_ID")
  region     = "eu-central-1"

  # The environment comes from the env.hcl of the directory the unit sits in (_global, later dev, prod).
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals.env

  # Bucket names are global across AWS: the account ID and region make this one ours (ADR 0032).
  state_bucket = "rarebit-tfstate-${local.account_id}-${local.region}"

  # The owner from the service catalog (catalog/README.md).
  owner = "user:haimlevtov"
}

# The AWS provider for every unit. allowed_account_ids makes plan and apply stop before they touch
# any other account, whatever credentials are active (ADR 0002). default_tags puts the same tags on
# every resource the provider creates (CLAUDE.md → Rules, rule 6).
generate "provider" {
  path      = "provider.generated.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region              = "${local.region}"
      allowed_account_ids = ["${local.account_id}"]

      default_tags {
        tags = {
          Project   = "rarebit"
          Env       = "${local.env}"
          ManagedBy = "terraform"
          Owner     = "${local.owner}"
          Source    = "infra/live/${path_relative_to_include()}"
        }
      }
    }
  EOF
}

# TODO(human): the remote_state block. Every unit's state goes to the bucket in local.state_bucket,
# one state file per unit, locked with a lockfile in the same bucket (docs/runbooks/terraform-state.md).
