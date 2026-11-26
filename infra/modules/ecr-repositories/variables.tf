variable "repositories" {
  description = "The repositories to create: name => kind. \"main\" holds main-<sha7> images (e.g. rarebit/game), \"pr\" holds pr-<number>-<sha7> images (e.g. rarebit/pr/game). Each kind gets its own lifecycle rules."
  type        = map(string)

  validation {
    condition = length(var.repositories) > 0 && alltrue([
      for name, kind in var.repositories :
      can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", name)) &&
      length(name) >= 2 && length(name) <= 256 && contains(["main", "pr"], kind)
    ])
    error_message = "Give at least one repository. Each name is 2-256 lowercase letters, digits and . _ - separators, optionally in path segments (rarebit/pr/game), as ECR requires; each kind is \"main\" or \"pr\"."
  }
}
