terraform {
  # ~> 1.17: the Terraform pinned in .mise.toml (1.17.2) and later 1.x releases.
  required_version = "~> 1.17"

  # aws is ours; cloudinit renders the NAT instance's user data in RaJiska/fck-nat 1.6.1, pinned here
  # so every provider in the lock file is one we chose.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
    # tflint-ignore: terraform_unused_required_providers # pinned for fck-nat, see above
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "2.4.1"
    }
  }
}
