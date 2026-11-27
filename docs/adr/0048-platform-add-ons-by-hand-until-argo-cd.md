# 0048. Until Argo CD, the in-cluster add-ons and the services are installed by a person with Helm, from pinned versions and values in git

- **Status:** accepted
- **Date:** 2026-11-27
- **Deciders:** platform owner

## Context

- **The architecture puts everything in the cluster under Argo CD** (CLAUDE.md, PLAN): Terraform stops at the cluster, and GitOps does the rest.
- **The first environment is needed tonight,** and Argo CD (its install, the app-of-apps, the ApplicationSets, the sync waves) is a pull request of its own.
- **Rule 2:** `helm install`, `upgrade`, `uninstall` and `rollback` are infra-changing commands, so a person runs them.
- **The add-ons need values that only exist at deploy time:** the VPC ID, the ALB's hostname, a generated Redis password, the registry with the account ID.
- **With the AWS Load Balancer Controller's targets as pod IPs,** a rollout that goes by the kubelet's readiness alone can leave the ALB with no healthy target for 10–15 s (the review of the chart, ADR 0045).

## Decision

**The in-cluster pieces are installed by a person, following `docs/runbooks/eks.md`, from what git pins:**

- **The app namespace, `rarebit`** (`deploy/platform/namespace.yaml`). It's created first, because labels only apply to pods created after them. Its labels:
  - `elbv2.k8s.aws/pod-readiness-gate-inject: enabled`: every pod behind the ALB gets a readiness gate, so a rollout waits until the ALB itself sees a new pod healthy;
  - `pod-security.kubernetes.io/enforce: restricted`: the restricted Pod Security Standard, which the chart's pods meet.
- **The AWS Load Balancer Controller,** chart 3.6.3 (`deploy/platform/aws-load-balancer-controller/values.yaml`).
- **CloudNativePG,** chart 0.29.2, with one Postgres cluster (`deploy/platform/postgres/cluster.yaml`, its image by digest).
- **The services,** with the shared chart (ADR 0045), in order:
  1. Redis;
  2. the migrate Job, waited for;
  3. the validator, the game and the web UI.
- **Values that only exist at deploy time stay in the cluster, not in git:**
  - the Redis password, in a Secret;
  - the game's allowed origin (the ALB's hostname), in a ConfigMap;
  - the database URL, in CloudNativePG's own Secret;
  - the registry, from the account ID at install time.
- **The images** are built from a `main` commit and pushed as `main-<sha7>` by `deploy/push-images.sh`, which writes `deploy/envs/<env>/*/image-tags.yaml`. A person runs it, because people may push main images as break-glass (ADR 0040), until CI builds them (#62).

**Argo CD replaces the Helm commands, not the files:** the same charts, versions and values become its Applications.

## Alternatives considered

| Option | Why not |
|---|---|
| Argo CD first, then the game | A pull request of its own before any link; tonight's goal is the link |
| Terraform's Helm provider for the add-ons | Puts the cluster's contents in Terraform state, which the plan keeps out (Terraform stops at the cluster); and a destroy would race the controllers' own cleanup of ALBs and volumes |
| Plain `kubectl apply` of rendered manifests | Loses Helm's release history and rollback, with nothing gained |

## Consequences

- **Good:**
  - a playable environment tonight, from versions and values that git holds;
  - the readiness gates and Pod Security labels are on from the first pod.
- **Bad / risks:**
  - **The cluster can drift from git:** nothing reconciles it, so a hand-made change stays until the next install. Argo CD's self-heal fixes that.
  - **The order is a person's to follow,** bring-up and teardown alike. The runbook writes it down, and `plat env up` and `plat env down` will run it.
  - **The teardown has to delete the Ingresses first,** or the ALB, its target groups and its security groups are orphaned, and the VPC's destroy hangs (`docs/runbooks/eks.md` → Tear down).
- **Follow-ups:** Argo CD and the GitOps layout; `plat env up` and `down`; the nightly teardown.

## How we'll know it was right

- The runbook brings a playable game up from nothing in under an hour, and tears it down to nothing, the leak check included.
- Argo CD can take over the same charts and values without changing them.
