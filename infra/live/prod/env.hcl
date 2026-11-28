# Units in prod: the environment players use. It's ephemeral for now: created for a work session and
# destroyed at its end (docs/runbooks/eks.md). root.hcl reads `env` from here for the Env tag.
locals {
  env = "prod"
}
