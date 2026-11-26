# The image registries (ADR 0036). Main images (main-<sha7>) go to rarebit/<service>, which only
# main's CI may push to; PR images (pr-<number>-<sha7>) go to rarebit/pr/<service>. The cluster's
# nodes pull from the main repositories, previews from the PR repositories.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/infra/modules//ecr-repositories"
}

inputs = {
  repositories = {
    "rarebit/validator"    = "main"
    "rarebit/game"         = "main"
    "rarebit/web"          = "main"
    "rarebit/bots"         = "main"
    "rarebit/pr/validator" = "pr"
    "rarebit/pr/game"      = "pr"
    "rarebit/pr/web"       = "pr"
    "rarebit/pr/bots"      = "pr"
  }
}
