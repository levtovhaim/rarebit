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
    tls = {
      source  = "hashicorp/tls"
      version = "4.4.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.14.2"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "2.4.1"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.3.2"
    }
  }
}
