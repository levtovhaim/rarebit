# Cost

What the AWS account costs, resource by resource: the model, and the actuals from Cost Explorer once they exist. Update it in the same PR when instance types, sizing or always-on resources change (CLAUDE.md → Documentation map).

## Always on

Resources managed in `infra/live` that exist whether or not the platform is up. Infracost diffs on infra PRs come with the CI plan workflow (issue #61).

| Resource | Unit | Model | Actual |
|---|---|---|---|
| Terraform state bucket (S3 Standard, eu-central-1) | `infra/live/_global/bootstrap` | Under $0.01/month. State files are kilobytes. Every old version from the last 90 days is kept, plus the newest 20 of each file however old. Each plan or apply writes and deletes a lock and reads the state, and an apply also writes it: at S3 Standard rates, well under a cent. | 2026-11-26: $0.0011 for all of the account's S3 usage, before credits (Cost Explorer, estimated) |
| Image registries (ECR: 4 main and 4 PR repositories) | `infra/live/_global/ecr` | Cents a month. ECR bills storage per GB-month. The images are 9.5 MB (web), 15.2 MB (validator), 57.7 MB (bots) and 61.5 MB (game) compressed (`docker save`, gzipped, 2026-11-26), and layers shared between tags of a repository are stored once. PR images expire after 7 days and each main repository keeps the newest 50, so the total stays at a few GB at most. Basic scanning is free; pushes from CI (data in) and pulls inside eu-central-1 cost nothing; pulls from outside AWS (a laptop, a GitHub runner) count as internet egress, within the account's free 100 GB a month. | 2026-11-26: $0 (no ECR usage in Cost Explorer; the repositories are empty) |
| GitHub OIDC provider and CI roles (IAM) | `infra/live/_global/github-oidc` | $0: IAM, OIDC providers and STS calls are free. The pull request plan role is denied Cost Explorer (billed $0.01 a request), CloudWatch `GetMetricData` and Logs Insights queries (both billed), so a pull request can't spend money through it (ADR 0038). | 2026-11-26: $0 (no IAM line in Cost Explorer) |
| Budgets (monthly $30, daily $4, credits $110) and the cost anomaly monitor | `infra/live/_global/cost-alerts` | $0: budgets without actions are free, and so is Cost Anomaly Detection ([AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/)). A plan of the unit reads the monitor and the subscription through the Cost Explorer API, $0.01 a request: a few cents a plan (ADR 0041). | Made or last changed in the console on 2026-11-23/24, imported 2026-11-27; no Budgets line in Cost Explorer for 2026-11-26 |

**The account as a whole,** usage before credits (Cost Explorer, `RECORD_TYPE` Usage, estimated): 2026-11-23 $0.00002, 2026-11-24 $0.104, 2026-11-25 $0.00001, 2026-11-26 $0.0011. The $0.104 is an Aurora Serverless v2 cluster made in the console and deleted 41 minutes later, outside `infra/live`; it's most of the $0.105 the monthly and credits budgets show for November.

## The platform (hourly, only while up)

Prod (`infra/live/prod`, ADRs 0046–0048) exists only while a session runs: it's created and destroyed by hand (`docs/runbooks/eks.md`). Rates for eu-central-1, on-demand, from the AWS Price List API (2026-11-23 and 2026-11-27):

| Resource | $/h |
|---|---|
| EKS control plane (standard support) | 0.100 |
| 2 × t3.medium nodes, on-demand | 0.096 |
| ALB (hourly, plus about 0.004 of capacity units at this traffic) | 0.031 |
| 3 public IPv4 addresses (the NAT instance's Elastic IP, the ALB's two) | 0.015 |
| NAT instance (t4g.nano, fck-nat) | 0.005 |
| EBS: the nodes' and the NAT instance's root volumes and Postgres's 2 GiB, about 50 GB | 0.007 |
| **Total** | **≈ 0.25** |

No NAT Gateway ($0.052/h and $0.052/GB, ADR 0046), no interface endpoints ($0.012/h per zone each), no control-plane logs. Infracost isn't wired into pull requests yet (#61), so this table is the estimate; the next day's Cost Explorer actuals are compared with it.

## Quotas

The account's EC2 vCPU quotas in eu-central-1, raised on 2026-11-23. The Karpenter NodePool limits must stay below them.

| Quota | Code | Value |
|---|---|---|
| Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances | `L-1216C47A` | 16 vCPU |
| All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests | `L-34B43A08` | 32 vCPU |
