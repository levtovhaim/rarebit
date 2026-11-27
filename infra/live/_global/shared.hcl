# Names that more than one _global unit needs, so they're written once.
locals {
  # The image repositories, name => kind (ADR 0036). The ecr unit creates them; the github-oidc unit
  # gives the CI roles push rights on them.
  ecr_repositories = {
    "rarebit/validator"    = "main"
    "rarebit/game"         = "main"
    "rarebit/web"          = "main"
    "rarebit/bots"         = "main"
    "rarebit/pr/validator" = "pr"
    "rarebit/pr/game"      = "pr"
    "rarebit/pr/web"       = "pr"
    "rarebit/pr/bots"      = "pr"
  }

  # The CI roles (ADR 0038), under one IAM path. The github-oidc unit creates them; the ecr unit's
  # repository policies name them.
  ci_role_path = "/ci/"
  ci_roles = {
    pr      = "gha-ci-pr"   # pull requests: push PR images
    main    = "gha-ci-main" # main: push main images
    tf_plan = "gha-tf-plan" # pull requests: terraform plan, read-only
  }

  # Units whose state holds personal data: the pull request plan role may not read their state, and the
  # plan workflow must skip them (ADR 0042, #62). List a unit here and apply github-oidc before the
  # unit's first apply.
  #   _global/cost-alerts: the alert address
  #   prod/eks: the operator's home address (the API's allowed /32) and IAM user (its access entry)
  private_state_units = ["_global/cost-alerts", "prod/eks"]

  # The repository on GitHub whose workflows may take these roles, with the numeric IDs GitHub puts
  # in its tokens' sub (immutable subject, ADR 0038). They're public: gh api repos/levtovhaim/rarebit
  # → .owner.id and .id. A rename changes the name part of the sub (update github_repository); a
  # repository deleted and created again gets a new ID.
  github_repository    = "levtovhaim/rarebit"
  github_owner_id      = "360220203"
  github_repository_id = "1468801318"
}
