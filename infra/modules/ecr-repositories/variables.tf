variable "push_principals" {
  description = "Per kind (main, pr), the principal ARN patterns that may push (aws:PrincipalArn, ArnLike): everyone else is denied by the repository policy, whatever their IAM policies allow."
  type        = map(list(string))

  validation {
    condition     = toset(keys(var.push_principals)) == toset(["main", "pr"]) && alltrue([for k, v in var.push_principals : length(v) > 0])
    error_message = "Give push principals for exactly the kinds main and pr, at least one each."
  }
}

variable "delete_principals" {
  description = "Per kind (main, pr), the principal ARN patterns that may delete images: everyone else is denied. Lifecycle expiry isn't a principal's request and isn't affected."
  type        = map(list(string))

  validation {
    condition     = toset(keys(var.delete_principals)) == toset(["main", "pr"]) && alltrue([for k, v in var.delete_principals : length(v) > 0])
    error_message = "Give delete principals for exactly the kinds main and pr, at least one each."
  }
}

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
