# Cost

What the AWS account costs, resource by resource: the model, and the actuals from Cost Explorer once they exist. Update it in the same PR when instance types, sizing or always-on resources change (CLAUDE.md → Documentation map).

## Always on

Resources managed in `infra/live` that exist whether or not the platform is up. Infracost diffs on infra PRs come with the CI plan workflow (issue #61).

| Resource | Unit | Model | Actual |
|---|---|---|---|
| Terraform state bucket (S3 Standard, eu-central-1) | `infra/live/_global/bootstrap` | Under $0.01/month. State files are kilobytes. Every old version from the last 90 days is kept, plus the newest 20 of each file however old. Each plan or apply writes and deletes a lock and reads the state, and an apply also writes it: at S3 Standard rates, well under a cent. | 2026-11-26: $0.0011 for all of the account's S3 usage, before credits (Cost Explorer, estimated) |
| Image registries (ECR: 4 main and 4 PR repositories) | `infra/live/_global/ecr` | Cents a month. ECR bills storage per GB-month. The images are 9.5 MB (web), 15.2 MB (validator), 57.7 MB (bots) and 61.5 MB (game) compressed (`docker save`, gzipped, 2026-11-26), and layers shared between tags of a repository are stored once. PR images expire after 7 days and each main repository keeps the newest 50, so the total stays at a few GB at most. Basic scanning is free; pushes from CI (data in) and pulls inside eu-central-1 cost nothing; pulls from outside AWS (a laptop, a GitHub runner) count as internet egress, within the account's free 100 GB a month. | 2026-11-26: $0 (no ECR usage in Cost Explorer; the repositories are empty) |
| GitHub OIDC provider and CI roles (IAM) | `infra/live/_global/github-oidc` | $0: IAM, OIDC providers and STS calls are free. The pull request plan role is denied Cost Explorer (billed $0.01 a request), CloudWatch `GetMetricData` and Logs Insights queries (both billed), so a pull request can't spend money through it (ADR 0038). | 2026-11-26: $0 (no IAM line in Cost Explorer) |
| Budgets (monthly $30, daily $4, credits $110) and the cost anomaly monitor | `infra/live/_global/cost-alerts` | $0: budgets without actions are free, and so is Cost Anomaly Detection ([AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/)). A plan of the unit reads the monitor and the subscription through the Cost Explorer API, $0.01 a request: a few cents a plan (ADR 0041). | Made in the console on 2026-11-23/24, imported 2026-11-27; no Budgets line in Cost Explorer for 2026-11-26 |

## The platform (hourly, only while up)

The cluster, its nodes, the load balancer and the NAT instance come with the platform PRs, each with its hourly cost and an Infracost diff (CLAUDE.md → Rules, rule 6). Nothing hourly exists yet.

## Quotas

The account's EC2 vCPU quotas in eu-central-1, raised on 2026-11-23. The Karpenter NodePool limits must stay below them.

| Quota | Code | Value |
|---|---|---|
| Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances | `L-1216C47A` | 16 vCPU |
| All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests | `L-34B43A08` | 32 vCPU |
