# The state bucket itself (ADR 0032). It's the one unit whose state can't start in S3: the bucket
# doesn't exist until this unit's first apply. So the first apply keeps its state in a local file,
# and `terragrunt init -migrate-state` then moves that state into the bucket it just created
# (docs/runbooks/terraform-state.md → Bootstrap from nothing).

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/infra/modules//state-bootstrap"
}

inputs = {
  bucket_name = include.root.locals.state_bucket
}

# Only while RAREBIT_BOOTSTRAP_LOCAL_STATE=true: a Terraform override file that replaces the S3
# backend from root.hcl with a local state file next to this one (git ignores *.tfstate). Without
# the variable, Terragrunt deletes the override again, and the S3 backend applies.
generate "bootstrap_local_state" {
  path        = "backend_override.tf"
  if_exists   = "overwrite_terragrunt"
  disable     = get_env("RAREBIT_BOOTSTRAP_LOCAL_STATE", "false") != "true"
  if_disabled = "remove_terragrunt"
  contents    = <<-EOF
    terraform {
      backend "local" {
        path = "${get_terragrunt_dir()}/bootstrap.tfstate"
      }
    }
  EOF
}
