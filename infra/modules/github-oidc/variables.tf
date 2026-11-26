variable "github_repository" {
  description = "The GitHub repository, owner/name, whose workflow runs may take the roles."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "Use owner/name, e.g. levtovhaim/rarebit."
  }
}

variable "account_id" {
  description = "The AWS account the roles and repositories are in, for the ARNs in the policies."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "An AWS account ID is exactly 12 digits."
  }
}

variable "region" {
  description = "The region of the ECR repositories."
  type        = string
}

variable "role_path" {
  description = "The IAM path for the roles, e.g. /ci/; repository policies match the roles by their ARN, which includes it."
  type        = string
  default     = "/ci/"

  validation {
    condition     = can(regex("^/([A-Za-z0-9_+=,.@-]+/)*$", var.role_path))
    error_message = "An IAM path starts and ends with /, e.g. /ci/."
  }
}

variable "roles" {
  description = "The role names: pr (pull request image builds), main (main image builds), tf_plan (pull request terraform plans)."
  type        = map(string)

  validation {
    condition     = toset(keys(var.roles)) == toset(["pr", "main", "tf_plan"])
    error_message = "Name exactly three roles: pr, main and tf_plan."
  }
}

variable "main_repositories" {
  description = "Names of the ECR repositories for main images (rarebit/<service>): the main role may push to these."
  type        = list(string)
}

variable "pr_repositories" {
  description = "Names of the ECR repositories for PR images (rarebit/pr/<service>): the pr role may push to and delete from these."
  type        = list(string)
}

variable "state_bucket" {
  description = "The Terraform state bucket: the tf_plan role may write and delete lock objects (*.tflock) there."
  type        = string
}
