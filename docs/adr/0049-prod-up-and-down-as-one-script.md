# 0049. Prod's bring-up and teardown are one bash script, which `plat env` will call

- **Status:** accepted
- **Date:** 2026-11-27
- **Deciders:** platform owner

## Context

- **Prod is created for a work session and destroyed at its end** (ADRs 0046–0048). It costs about $0.36/h while it's up (`docs/cost.md`).
- **The runbook (`docs/runbooks/eks.md`) has about 25 commands each way.** The teardown order matters: the ALB, its target groups and security groups, and Postgres's volume were created by in-cluster controllers. They must be gone before the cluster and the VPC, or the network's destroy hangs.
- **The first live run (2026-11-27) found failure modes that a person typing commands misses:**
  - the operator's address changes, and `kubectl` stops answering;
  - the login runs out part way through an apply;
  - a check that fails gets read as "nothing left".
- **`plat env up` and `plat env down`** (Python and Typer, `platform/cli`) are the planned interface. They don't exist yet, and building the CLI is its own piece of work.

## Decision

**`platform/env.sh` runs the runbook's steps, with `up`, `down` and `status`:**

- **`up`:**
  1. checks that every image prod pins is in ECR, before anything bills;
  2. applies the network and the cluster;
  3. installs the namespace, the LB controller, CloudNativePG and Postgres, and waits until Postgres is ready;
  4. creates the Redis password and the origin placeholder, only where they're missing;
  5. deploys the five services in order;
  6. sets the game's origin to the ALB, then restarts the game;
  7. checks the page.
- **`down`:**
  1. removes the services, then waits until the ALB, its target groups and its security groups are gone;
  2. deletes Postgres and waits for its volume;
  3. removes the controllers;
  4. checks that nothing they made is left;
  5. destroys the cluster, then the network;
  6. runs the leak check.
- **Every step can run again:** `helm upgrade --install`, `--ignore-not-found`, and create-if-missing. After a failure, the same command finishes the run.
- **Checks fail closed:** when a check can't run, the script stops. It never takes "couldn't check" as "gone".
- **A preflight runs before anything else.** It checks the tools, that the login is to the project account, and that `RAREBIT_ADMIN_CIDR` is the operator's current address.
- **Without `--yes`,** Terraform shows each plan and asks, and `down` asks once before it starts. **With `--yes`,** nothing asks, for a later unattended teardown.
- **A person runs `up` and `down`** (CLAUDE.md rule 2). `status` only reads.

**`plat env up` and `plat env down` will call this script, not reimplement it.** Argo CD (ADR 0048) later takes over the Helm steps.

## Alternatives considered

| Option | Why not |
|---|---|
| Write `plat env` in Python now | A new CLI with its own dependencies, tests and packaging, to run the same commands. The order and the checks are what matter, and they're the same in either language. |
| Keep the runbook as the only procedure | About 25 commands each way, with waits a person has to judge. Today's run hit the failures listed above. |
| Make targets (`make env-up`) | `make` targets here run without AWS (`make check`, `make infra`). An infra-changing target next to them is easy to run by mistake, by a person or an agent. |
| Terragrunt `run --all` for both units | It covers only Terraform. The in-cluster steps, the waits and the teardown order would still be by hand. |

## Consequences

- One command each way, about 25 minutes up and 15 down. The runbook keeps the steps, so a failed step can be understood and run by hand.
- **The script runs `terragrunt`, `helm` and `kubectl` itself,** so permission rules that match those commands don't see them. An agent that runs the script gets past those rules. Ask rules for the script itself (`platform/env.sh up` and `down`) are the fix.
- **Bash 4.4 or newer, in WSL or Linux.** Not macOS's built-in bash 3.2.
