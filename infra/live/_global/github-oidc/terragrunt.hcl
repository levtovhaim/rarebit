# How GitHub Actions reaches AWS (ADR 0038): the OIDC provider and the CI roles. Pull request runs
# push PR images and plan; main's runs push main images. The repository names and role names come
# from shared.hcl, which the ecr unit reads too.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  shared = read_terragrunt_config(find_in_parent_folders("shared.hcl")).locals
}

terraform {
  source = "${get_repo_root()}/infra/modules//github-oidc"
}

inputs = {
  github_repository      = local.shared.github_repository
  github_owner_id        = local.shared.github_owner_id
  github_repository_id   = local.shared.github_repository_id
  account_id             = include.root.locals.account_id
  region                 = include.root.locals.region
  role_path              = local.shared.ci_role_path
  roles                  = local.shared.ci_roles
  main_repositories      = [for name, kind in local.shared.ecr_repositories : name if kind == "main"]
  pr_repositories        = [for name, kind in local.shared.ecr_repositories : name if kind == "pr"]
  state_bucket           = include.root.locals.state_bucket
  private_state_prefixes = local.shared.private_state_units
}
