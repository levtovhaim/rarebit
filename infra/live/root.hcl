# Shared by every unit under infra/live: each unit's terragrunt.hcl `include`s this file. It generates
# the provider and the backend, so a unit only says which module it runs and with which inputs
# (ADR 0033).

terraform_version_constraint  = "~> 1.17"
terragrunt_version_constraint = "~> 1.2"

locals {
  # The one AWS account every unit may run in. It isn't committed (the repo is public): set it in
  # .mise.local.toml, which git ignores (infra/README.md; ADR 0035). get_env without a default fails
  # when the variable is unset, and regex fails unless it's exactly 12 digits. An empty value must
  # fail too: allowed_account_ids = [""] turns the provider's account check off.
  account_id = regex("^[0-9]{12}$", get_env("RAREBIT_AWS_ACCOUNT_ID"))
  region     = "eu-central-1"

  # The environment comes from the env.hcl of the directory the unit sits in (_global, later dev, prod).
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals.env

  # Bucket names are global across AWS: the account ID and region make this one ours (ADR 0032).
  state_bucket = "rarebit-tfstate-${local.account_id}-${local.region}"

  # Who owns the infrastructure, in the service catalog's owner format (catalog/README.md).
  owner = "user:haimlevtov"
}

# The account's foundation (_global: the state bucket, the registries, CI access, the budgets) is
# never destroyed by Terragrunt: not by a `run --all destroy` meant for an environment, and not by a
# `destroy` in the unit itself (no_run). Taking one down on purpose starts with a reviewed PR that
# changes this block. `apply -destroy` counts as `apply` here, so the same rule holds in review.
exclude {
  if      = local.env == "global"
  actions = ["destroy"]
  no_run  = true
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

# Every unit's state: one file per unit in the state bucket, named by the unit's path, locked by a
# lockfile next to it (ADR 0032). Terragrunt never creates or changes the bucket: the module owns it
# (ADR 0034).
remote_state {
  backend = "s3"

  generate = {
    path      = "backend.generated.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket                = local.state_bucket
    key                   = "${path_relative_to_include()}/terraform.tfstate"
    region                = local.region
    encrypt               = true
    use_lockfile          = true
    allowed_account_ids   = [local.account_id]
    disable_bucket_update = true
  }
}
