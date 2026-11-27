# 0045. Every service deploys with one Helm chart, its values layered by service, environment and image tag

- **Status:** accepted
- **Date:** 2026-11-27
- **Deciders:** platform owner

## Context

- Four workloads need to run in Kubernetes:
  - the validator, and its `migrate` Job;
  - the game server;
  - the web UI;
  - Redis.

  More will follow: the bots, the ingest worker, the `rarity` job.
- Every service must meet the same runtime contract (CLAUDE.md rule 7): non-root, a read-only root filesystem, probes on `/healthz` and `/readyz`, a graceful drain on its stop signal. And the same labels, from its catalog entry (CLAUDE.md → Conventions).
- The services differ in details the deployment has to get right, written in each README: no shell in the images (so no `exec` probes or hooks), and each one's drain timing.
- Rule 3: deploy with `deploy/charts/service`, whose `values.schema.json` must pass; no copy-pasted charts.
- The registry's host holds the AWS account ID, which stays out of git (ADR 0035).
- Promotions change only `deploy/envs/**/image-tags.yaml`, the one path under `deploy/` without a code owner (CLAUDE.md → Conventions, ADR 0036).

## Decision

**One chart, `deploy/charts/service`, deploys every service and job.** It renders:
- a Deployment (`mode: deployment`) or a Job (`mode: job`);
- a Service, an optional ALB Ingress, a PodDisruptionBudget when there's more than one replica, and a ServiceAccount.

**The chart sets the parts that must never differ:**
- the pod runs as the image's numeric non-root user, with seccomp `RuntimeDefault`;
- a read-only root filesystem, no privilege escalation, every capability dropped;
- no service account token, no service links;
- requests for CPU and memory and a memory limit, with no CPU limit (it only throttles);
- the labels, with `owner` and `tier` from the service's values, which the tests check against its catalog entry;
- a rolling update that never drops below the replica count, and topology spread across zones and nodes;
- a Job named after its image tag, since a Job's pod template can't change: a new tag runs the migration again.

**`values.schema.json` refuses what the golden path doesn't allow:**
- an image without a `sha256` digest, or `latest`;
- a missing owner, or a tier the catalog doesn't have;
- missing resources, or a CPU limit;
- a deployment without probes or a grace period;
- a port under 1024, root, an ingress class other than `alb`;
- a mount that doesn't say whether it's read-only;
- any key the chart doesn't know, so a misspelling fails instead of being ignored.

**Values come in three layers,** applied in order (`helm -f`):
1. `deploy/apps/<service>/values.yaml`: what's true in every environment (ports, probes, timing, resources, Ingress rules);
2. `deploy/envs/<env>/<service>/values.yaml`: what an environment adds (replicas, secrets, the allowed origin);
3. `deploy/envs/<env>/<service>/image-tags.yaml`: the image tag with its digest, the only file a promotion changes.

**The registry's host isn't in git.** Our images' `image.registry` is set at install time from the account ID, outside git (ADR 0035). An upstream image (Redis) names its registry in its values.

**Every service's shutdown timing is tested** against its README (`deploy/test/render.sh`, in `make deploy` and the `deploy` check in CI). The tests also check:
- every rendered workload against the rules above;
- every manifest with kubeconform;
- the one load balancer: only the game and the web UI have an Ingress, all in IngressGroup `rarebit` with the same scheme and listener (CLAUDE.md rule 6). The game takes `/socket.io` ahead of the web UI's `/`, and no Ingress routes to a metrics port.

## Alternatives considered

| Option | Why not |
|---|---|
| A chart per service | Four copies of the same security settings and labels, drifting apart (rule 3) |
| Plain manifests with Kustomize overlays | No schema for a service's values, so a typo or a missing probe gets through; and the same YAML in every service's base |
| Upstream charts for Redis (Bitnami and others) | Bitnami moved its images and charts behind new terms in 2025. Our one-replica, no-persistence Redis is a container with a port and a probe, which this chart already deploys |
| The migration as a Helm hook (`pre-install`, `pre-upgrade`) | Hooks run before the release's other objects exist (its ServiceAccount among them), and Argo CD maps them to its own phases anyway. A Job named after the image runs once per image, in sync with the release |
| The registry in the values, with the account ID | The account ID stays out of git (ADR 0035) |

## Consequences

- **Good:**
  - a new service is a values file, and the schema and tests hold it to the same rules as the rest;
  - the timing that each README asks for is checked before anything reaches a cluster;
  - a promotion touches one small file per service.
- **Bad / risks:**
  - **The registry has to be passed at every install.** Argo CD (later) needs it from somewhere other than git: a cluster-side value, or an ECR pull-through rule.
  - **Lists don't merge in Helm,** so an environment adds variables through `extraEnv`, not `env`.
  - **kubeconform downloads the Kubernetes schemas** from GitHub on every run without a cache, and validates against the newest published version, not the cluster's.
  - **The chart has no NetworkPolicy, HPA, ServiceMonitor or ExternalSecret yet.** They arrive with the cluster features they need.
- **Follow-ups:**
  - the first deployment, to EKS, with its environment's values and image tags;
  - Argo CD, monitoring and policies, each in the pull request that adds the feature.

## How we'll know it was right

- A new service deploys by adding a values file and a catalog entry, with no change to the chart.
- No deployment fails in a way the tests could have caught: a missing probe, a wrong label, a grace period too short.
