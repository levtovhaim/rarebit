# Cost

What the AWS account costs, resource by resource: the model, and the actuals from Cost Explorer once they exist. Update it in the same PR when instance types, sizing or always-on resources change (CLAUDE.md → Documentation map).

## Always on

Resources managed in `infra/live` that exist whether or not the platform is up. The budgets and the cost anomaly monitor, made by hand before Terraform, join this table when they're imported. Infracost diffs on infra PRs come with the CI plan workflow (issue #61).

| Resource | Unit | Model | Actual |
|---|---|---|---|
| Terraform state bucket (S3 Standard, eu-central-1) | `infra/live/_global/bootstrap` | Under $0.01/month. State files are kilobytes. Every old version from the last 90 days is kept, plus the newest 20 of each file however old. Each plan or apply writes and deletes a lock and reads the state, and an apply also writes it: at S3 Standard rates, well under a cent. | Created 2026-11-26; Cost Explorer actuals from the next day |
| Image registries (ECR, 4 private repositories) | `infra/live/_global/ecr` | Cents a month. ECR bills storage per GB-month; the compressed images are 15 to 65 MB each, layers shared between tags of a repository are stored once, PR images expire after 3 days and only the newest 15 `main` images stay, so the total stays under 1 GB. Basic scanning is free; pushes from CI (data in) and pulls inside eu-central-1 cost nothing. | — (not applied yet) |

## The platform (hourly, only while up)

The cluster, its nodes, the load balancer and the NAT instance come with the platform PRs, each with its hourly cost and an Infracost diff (CLAUDE.md → Rules, rule 6). Nothing hourly exists yet.

## Quotas

The account's EC2 vCPU quotas in eu-central-1, raised on 2026-11-23. The Karpenter NodePool limits must stay below them.

| Quota | Code | Value |
|---|---|---|
| Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances | `L-1216C47A` | 16 vCPU |
| All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests | `L-34B43A08` | 32 vCPU |
