# Prod's EKS cluster (ADR 0047), in the network unit's VPC.

include "root" {
  path = find_in_parent_folders("root.hcl")
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
}

inputs = {
  name               = "rarebit-prod"
  kubernetes_version = "1.37"
  vpc_id             = dependency.network.outputs.vpc_id
  subnet_ids         = dependency.network.outputs.private_subnet_ids
  # The operator's own address as a /32, from .mise.local.toml (git ignores it): the only address the
  # cluster's API answers. Unset, this unit refuses to run.
  admin_cidrs = [regex("^[0-9.]+/32$", get_env("RAREBIT_ADMIN_CIDR"))]
}
