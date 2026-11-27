terraform {
  # ~> 1.17: the Terraform pinned in .mise.toml (1.17.2) and later 1.x releases. Nothing here needs a
  # newer feature than mock_provider in tests (1.7).
  required_version = "~> 1.17"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}
