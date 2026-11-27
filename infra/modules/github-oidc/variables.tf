variable "github_repository" {
  description = "The GitHub repository, owner/name, whose workflow runs may take the roles."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "Use owner/name, e.g. levtovhaim/rarebit."
  }
}

variable "github_owner_id" {
  description = "The numeric ID of the repository's owner on GitHub (gh api repos/<owner>/<name> → .owner.id). GitHub's immutable subject puts it in the token's sub."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "A GitHub owner ID is a number, e.g. 360220203."
  }
}

variable "github_repository_id" {
  description = "The numeric ID of the repository on GitHub (gh api repos/<owner>/<name> → .id). GitHub's immutable subject puts it in the token's sub."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "A GitHub repository ID is a number, e.g. 1468801318."
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

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.region))
    error_message = "Use an AWS region name, e.g. eu-central-1."
  }
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

  validation {
    condition     = length(var.main_repositories) > 0
    error_message = "Name at least one main repository: an empty list makes a policy without a resource, which AWS refuses at apply."
  }
}

variable "pr_repositories" {
  description = "Names of the ECR repositories for PR images (rarebit/pr/<service>): the pr role may push to and delete from these."
  type        = list(string)

  validation {
    condition     = length(var.pr_repositories) > 0
    error_message = "Name at least one PR repository: an empty list makes a policy without a resource, which AWS refuses at apply."
  }

  validation {
    condition     = length(setintersection(var.pr_repositories, var.main_repositories)) == 0
    error_message = "A repository is either main or PR, never both: the pr role would get push and delete on a main repository."
  }
}

variable "private_state_prefixes" {
  description = "Unit paths (state keys under the bucket, e.g. _global/cost-alerts) whose state holds personal data: the tf_plan role may not read them."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.private_state_prefixes : can(regex("^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$", p))])
    error_message = "A unit path, no leading or trailing slash and no wildcard, e.g. _global/cost-alerts."
  }
}

variable "state_bucket" {
  description = "The Terraform state bucket: the only bucket whose objects the tf_plan role may read (each unit's state)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket))
    error_message = "Use an S3 bucket name: 3-63 characters, lowercase letters, digits, dots and hyphens."
  }
}
