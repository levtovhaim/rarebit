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

  # The repository on GitHub whose workflows may take these roles.
  github_repository = "levtovhaim/rarebit"
}
