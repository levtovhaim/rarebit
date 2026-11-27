terraform {
  # ~> 1.17: the Terraform pinned in .mise.toml (1.17.2) and later 1.x releases.
  required_version = "~> 1.17"

  # aws is ours; the rest are what terraform-aws-modules/eks 21.30.2 needs (tls for its OIDC thumbprint,
  # time for its waits, cloudinit and null for the node groups' user data), pinned here so every
  # provider in the lock file is one we chose.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
    # tflint-ignore: terraform_unused_required_providers # pinned for the community modules, see above
    tls = {
      source  = "hashicorp/tls"
      version = "4.4.2"
    }
    # tflint-ignore: terraform_unused_required_providers # pinned for the community modules, see above
    time = {
      source  = "hashicorp/time"
      version = "0.14.2"
    }
    # tflint-ignore: terraform_unused_required_providers # pinned for the community modules, see above
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "2.4.1"
    }
    # tflint-ignore: terraform_unused_required_providers # pinned for the community modules, see above
    null = {
      source  = "hashicorp/null"
      version = "3.3.2"
    }
  }
}
