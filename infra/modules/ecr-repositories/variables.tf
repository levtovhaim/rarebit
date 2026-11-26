variable "repositories" {
  description = "Names of the repositories to create, one per service image, e.g. rarebit/game."
  type        = set(string)

  validation {
    condition = length(var.repositories) > 0 && alltrue([
      for r in var.repositories : can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", r)) && length(r) <= 256
    ])
    error_message = "Give at least one name; each is lowercase letters, digits and . _ - separators, optionally in path segments (rarebit/game), at most 256 characters, as ECR requires."
  }
}
