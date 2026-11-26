# Cost

What the AWS account costs, resource by resource: the model, and the actuals from Cost Explorer once they exist. Update it in the same PR when instance types, sizing or always-on resources change (CLAUDE.md → Documentation map).

## Always on

Resources that exist whether or not the platform is up.

| Resource | Unit | Model | Actual |
|---|---|---|---|
| Terraform state bucket (S3 Standard, eu-central-1) | `infra/live/_global/bootstrap` | Under $0.01/month. State files are kilobytes, up to 20 old versions of each are kept, and a plan or apply makes a handful of requests (a lock write and delete, a state read, a state write): at S3 Standard rates, well under a cent. | Created 2026-11-26; Cost Explorer actuals from the next day |

## The platform (hourly, only while up)

The cluster, its nodes, the load balancer and the NAT instance come with the platform PRs, each with its hourly cost and an Infracost diff (CLAUDE.md → Rules, rule 6). Nothing hourly exists yet.

## Quotas

The account's EC2 vCPU quotas in eu-central-1, raised on 2026-11-23. The Karpenter NodePool limits must stay below them.

| Quota | Code | Value |
|---|---|---|
| Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances | `L-1216C47A` | 16 vCPU |
| All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests | `L-34B43A08` | 32 vCPU |
