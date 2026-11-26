# The image registries: one private ECR repository per service image (ADR 0036). CI pushes here
# (pr-<number>-<sha7>, main-<sha7>); the cluster's nodes pull from here.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/infra/modules//ecr-repositories"
}

inputs = {
  repositories = [
    "rarebit/validator",
    "rarebit/game",
    "rarebit/web",
    "rarebit/bots",
  ]
}
