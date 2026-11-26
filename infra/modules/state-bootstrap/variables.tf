variable "bucket_name" {
  description = "Name of the state bucket. Bucket names are global across AWS, so include the account ID and the region (infra/live/root.hcl builds rarebit-tfstate-<account>-<region>)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name)) && !strcontains(var.bucket_name, "--")
    error_message = "Use 3-63 lowercase letters, digits and single hyphens, starting and ending with a letter or digit (no dots: they break TLS for virtual-hosted bucket URLs)."
  }
}

variable "noncurrent_version_days" {
  description = "Days an old state version is kept after a newer write replaces it. The newest noncurrent_versions_kept versions are kept regardless of age."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_days >= 7
    error_message = "Keep old versions at least 7 days: they are how a bad state write gets undone."
  }
}

variable "noncurrent_versions_kept" {
  description = "How many old versions of each state file to keep, however old they are."
  type        = number
  default     = 20

  validation {
    condition     = var.noncurrent_versions_kept >= 1 && var.noncurrent_versions_kept <= 100
    error_message = "Keep between 1 and 100 old versions (S3's limit for newer_noncurrent_versions is 100)."
  }
}
