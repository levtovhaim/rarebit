# 0047. An environment's EKS cluster: a private-node cluster with an API restricted to the operator, a small on-demand node group, and Pod Identity

- **Status:** accepted
- **Date:** 2026-11-27
- **Deciders:** platform owner

## Context

- The game runs on Kubernetes (the architecture in CLAUDE.md), and the first environment is needed tonight for a playable link. It's created for a session and destroyed at its end.
- **Who talks to the cluster:** a person, with `aws login` credentials. CI never does; GitOps will do the deploying later.
- **What the workloads need:**
  - about 1.5 vCPU and 2 GiB of requests in all: two replicas each of the game, the validator and the web UI, plus Redis, Postgres and the controllers;
  - one EBS volume for Postgres;
  - IAM rights for two controllers: the AWS Load Balancer Controller and the EBS CSI driver.
- **Standard support:** EKS 1.37 is the default version in eu-central-1 and in standard support (checked 2026-11-23). Rule 6 rules out extended support.

## Decision

**`infra/modules/eks` wraps `terraform-aws-modules/eks` 21.30.2:**

- **Kubernetes 1.37**, in the network module's private subnets.
- **The API endpoint:**
  - public, but answers only the operators' addresses (`admin_cidrs`, a `/24` or smaller, never `0.0.0.0/0`). The live unit takes it from `RAREBIT_ADMIN_CIDR` in `.mise.local.toml`, so no address is in git;
  - private access on, for the nodes.
- **Access entries** (`authentication_mode = "API"`), not the `aws-auth` ConfigMap. Whoever runs the apply becomes the cluster admin, so no person's IAM name is written in git.
- **One managed node group:** two t3.medium nodes, on-demand, AL2023. A spot interruption during a game is what this first environment exists to avoid; Karpenter, with spot first, replaces this node group later.
- **Add-ons managed by EKS,** each pinned to EKS's default version for 1.37 (2026-11-27):
  - the VPC CNI, with prefix delegation, so a t3.medium runs more than 17 pods;
  - the Pod Identity agent, kube-proxy and CoreDNS;
  - the EBS CSI driver.
- **Pod Identity** (`terraform-aws-modules/eks-pod-identity` 2.11.0) gives the EBS CSI driver and the AWS Load Balancer Controller their IAM roles: no OIDC provider, no service account annotations.
- **Its state is private** (ADR 0042): it holds the allowed address and the admin's IAM user, so `prod/eks` is in `private_state_units`, the unit refuses to run otherwise, `admin_cidrs` is `sensitive`, and the pull request plan role may not describe a cluster or its access entries.
- **Never extended support:** `upgrade_policy` is `STANDARD`, so at the end of standard support EKS upgrades the cluster instead of billing the extended rate (rule 6).
- **Storage:** EKS has no default StorageClass since 1.30, so the EBS CSI add-on's gp3 class is made the default.
- **IMDS:** the nodes' launch template requires IMDSv2 with one network hop, written down rather than left to the module's default, so a pod off the host network can't reach the node's credentials.
- **Cost choices:** no control-plane logs, no customer-managed KMS key (EKS already encrypts secrets with an AWS-owned key), no IRSA OIDC provider, no deletion protection (the environment is destroyed every night, by a person).
- **Live units:** `infra/live/prod/network` and `infra/live/prod/eks`. The `eks` unit reads the VPC through a Terragrunt `dependency` block, with mock outputs only for `init` and `validate`.

## Alternatives considered

| Option | Why not |
|---|---|
| EKS Auto Mode | AWS runs the nodes and the add-ons, for a fee on top of each instance's price; and it hides the parts of EKS (node groups, CNI, add-ons, Pod Identity) this environment exists to run and understand |
| A private-only API endpoint | Needs a VPN or a bastion in the VPC for every `kubectl`; the address allowlist gets most of the protection for none of the cost |
| Spot nodes | Cheaper, but a two-minute interruption notice in the middle of a game; Karpenter brings spot back with on-demand fallback |
| IRSA (an IAM OIDC provider and annotated service accounts) | Pod Identity is simpler: no OIDC provider per cluster, no trust policy per cluster, the role names the service account |
| The `aws-auth` ConfigMap | Deprecated in favor of access entries, and edited inside the cluster instead of through the EKS API |

## Consequences

- **Good:**
  - about $0.20/h for the cluster and nodes, gone with the environment;
  - nobody but the operator's address reaches the API;
  - no IAM user name, account ID or address in git.
- **Bad / risks:**
  - **A changed home address locks the operator out** until `RAREBIT_ADMIN_CIDR` is updated and the unit applied again (seconds, through the AWS API, which isn't restricted).
  - **Only whoever applied the cluster is its admin.** Another operator needs an access entry (an `access_entries` input).
  - **Two nodes, no autoscaling:** a load test beyond their capacity leaves pods `Pending` until Karpenter.
  - **The add-ons are pinned to EKS's default versions for 1.37** on 2026-11-27, which AWS picks; they move with the next Kubernetes upgrade, or when the dependency automation (#70) proposes newer ones.
- **Follow-ups:** Karpenter, and the cluster's own observability, in later pull requests.

## How we'll know it was right

- `terragrunt apply` from nothing to two `Ready` nodes in about 15 minutes, and `destroy` back to nothing.
- No `kubectl` from any address but the operator's.
