# tflint for every Terraform directory under infra/ (make infra, and the tflint hook in make check).

config {
  call_module_type = "local"
}

# Terraform language rules, all of them: typed and documented variables and outputs, pinned
# providers and versions, the standard module layout, naming.
plugin "terraform" {
  enabled = true
  preset  = "all"
}

# AWS rules: invalid instance types, regions, names and other values the provider only rejects at apply.
plugin "aws" {
  enabled = true
  version = "0.50.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
