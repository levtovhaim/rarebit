terraform {
  # 1.11: native S3 state locking (use_lockfile). 1.11: mock values during plan in tests.
  required_version = "~> 1.17"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.73.0"
    }
  }
}
