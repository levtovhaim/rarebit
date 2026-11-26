terraform {
  # ~> 1.17: the Terraform pinned in .mise.toml (1.17.2) and later 1.x releases. The features this
  # module relies on are older: native S3 locking (use_lockfile) and mock values during plan in
  # tests (override_during), both from 1.11.
  required_version = "~> 1.17"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}
