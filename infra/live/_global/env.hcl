# Units in _global belong to no environment: the account's foundation (state, CI access, registries,
# budgets), shared by dev and prod. root.hcl reads `env` from here for the Env tag.
locals {
  env = "global"
}
