# The image registries (ADR 0036). Main images (main-<sha7>) go to rarebit/<service>, which only
# main's CI role and humans may push to; PR images (pr-<number>-<sha7>) go to rarebit/pr/<service>.
# The repository names and the CI role names come from shared.hcl, which the github-oidc unit reads
# too, so the roles and these repository policies always name each other the same way.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  shared = read_terragrunt_config(find_in_parent_folders("shared.hcl")).locals
  # Role ARNs are built from their names, so this unit doesn't depend on the github-oidc unit's
  # outputs; the repository policies match them by aws:PrincipalArn (ADR 0038).
  role_arn = { for key, name in local.shared.ci_roles : key => "arn:aws:iam::${include.root.locals.account_id}:role${local.shared.ci_role_path}${name}" }
  # People sign in as IAM users (ADR 0002): they may push and delete by hand, as break-glass.
  humans = "arn:aws:iam::${include.root.locals.account_id}:user/*"
}

terraform {
  source = "${get_repo_root()}/infra/modules//ecr-repositories"
}

inputs = {
  repositories = local.shared.ecr_repositories

  push_principals = {
    main = [local.role_arn.main, local.humans]
    pr   = [local.role_arn.pr, local.humans]
  }

  # Main images go only by the lifecycle rules; a PR's images are deleted when it closes.
  delete_principals = {
    main = [local.humans]
    pr   = [local.role_arn.pr, local.humans]
  }
}
