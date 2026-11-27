# Prod's EKS cluster (ADR 0047), in the network unit's VPC.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  # This unit's state holds the operator's home address and IAM user name: it runs only while it's
  # listed as private, so pull request plans can't read it (ADR 0042).
  listed_private = regex("^listed$", contains(
    read_terragrunt_config(find_in_parent_folders("_global/shared.hcl")).locals.private_state_units,
    path_relative_to_include("root")
  ) ? "listed" : "${path_relative_to_include("root")} is not in private_state_units")
}

terraform {
  source = "${get_repo_root()}/infra/modules//eks"
}

# The VPC and subnets come from the network unit's state. The mock values let `make infra` validate this
# unit before the network exists; a plan or an apply always reads the real outputs.
dependency "network" {
  config_path = "../network"

  mock_outputs = {
    vpc_id             = "vpc-00000000000000000"
    private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate"]
  # make infra runs init and validate with no backend and no credentials: don't read the network's
  # state then, use the mocks. A plan or an apply always reads it.
  skip_outputs = contains(["init", "validate"], get_terraform_command())
}

inputs = {
  name               = "rarebit-prod"
  kubernetes_version = "1.37"
  vpc_id             = dependency.network.outputs.vpc_id
  subnet_ids         = dependency.network.outputs.private_subnet_ids
  # The operator's own address as a /32, from .mise.local.toml (git ignores it): the only address the
  # cluster's API answers. Unset, this unit refuses to run.
  admin_cidrs = local.listed_private == "listed" ? [regex("^[0-9.]+/32$", get_env("RAREBIT_ADMIN_CIDR"))] : []
}
