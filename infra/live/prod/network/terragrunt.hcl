# The VPC prod's cluster runs in (ADR 0046): two zones, the NAT instance, the S3 endpoint.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/infra/modules//network"
}

inputs = {
  name = "rarebit-prod"
  cidr = "10.40.0.0/16"
  # /24 public (the ALB and the NAT instance need a handful of addresses), /20 private: with the VPC
  # CNI every pod takes a VPC address, and prefix delegation takes them 16 at a time.
  public_subnets  = { "eu-central-1a" = "10.40.0.0/24", "eu-central-1b" = "10.40.1.0/24" }
  private_subnets = { "eu-central-1a" = "10.40.16.0/20", "eu-central-1b" = "10.40.32.0/20" }
  cluster_name    = "rarebit-prod"
}
