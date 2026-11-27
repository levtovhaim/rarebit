# eks

An environment's EKS cluster (ADR 0047), wrapping [terraform-aws-modules/eks](https://github.com/terraform-aws-modules/terraform-aws-eks) 21.30.2:

- **Kubernetes 1.37** in the given private subnets.
- **The API endpoint** is public but answers only `admin_cidrs`, the operators' own addresses (a `/24` or smaller; never `0.0.0.0/0`). Private access is on for the nodes.
- **Access entries.** Whoever runs the apply becomes the cluster's admin, so no IAM user name is written in git.
- **One managed node group:** `node_count` on-demand nodes (default 2 × t3.medium, AL2023). Karpenter replaces it later.
- **Add-ons, each pinned:** the VPC CNI with prefix delegation, the Pod Identity agent, kube-proxy, CoreDNS and the EBS CSI driver.
- **Pod Identity roles** ([eks-pod-identity](https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity) 2.11.0) for the EBS CSI driver and for the AWS Load Balancer Controller (`kube-system/aws-load-balancer-controller`).
- **Left out on purpose:** control-plane logs, a customer-managed KMS key and an IRSA OIDC provider (cost), and deletion protection (the environment is destroyed every night, by a person).

What runs in the cluster is installed by hand for now (`docs/runbooks/eks.md`, ADR 0048). It's applied from `infra/live/prod/eks`.

## Usage

```hcl
module "eks" {
  source = "../../modules/eks"

  name               = "rarebit-prod"
  kubernetes_version = "1.37"
  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.private_subnet_ids
  admin_cidrs        = ["192.0.2.10/32"]
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.17 |
| aws | 6.73.0 |
| cloudinit | 2.4.1 |
| null | 3.3.2 |
| time | 0.14.2 |
| tls | 4.4.2 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.73.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| ebs\_csi\_pod\_identity | terraform-aws-modules/eks-pod-identity/aws | 2.11.0 |
| eks | terraform-aws-modules/eks/aws | 21.30.2 |
| lb\_controller\_pod\_identity | terraform-aws-modules/eks-pod-identity/aws | 2.11.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_default_tags.current](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/data-sources/default_tags) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_cidrs | The addresses allowed to reach the cluster's public API endpoint: the operators' own IPs (/32). CI never talks to the cluster. Personal data: the unit that sets it is a private state unit (ADR 0042). | `list(string)` | n/a | yes |
| kubernetes\_version | The EKS Kubernetes version: the newest in standard support (CLAUDE.md rule 6: never one in extended support). | `string` | n/a | yes |
| name | The cluster's name, e.g. rarebit-prod. It also prefixes its IAM roles. | `string` | n/a | yes |
| subnet\_ids | The private subnets for the nodes, the pods and the control plane's network interfaces, in at least two zones. | `list(string)` | n/a | yes |
| vpc\_id | The VPC (infra/modules/network). | `string` | n/a | yes |
| node\_count | How many nodes the managed node group runs (it can grow by one during a rolling update). | `number` | `2` | no |
| node\_instance\_types | The managed node group's instance types, on-demand. | `list(string)` | ```[ "t3.medium" ]``` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| cluster\_endpoint | The Kubernetes API's URL. |
| cluster\_name | The cluster's name, for `aws eks update-kubeconfig --name`. |
| lb\_controller\_role\_arn | The AWS Load Balancer Controller's IAM role, assumed through Pod Identity by kube-system/aws-load-balancer-controller. |
| node\_security\_group\_id | The nodes' security group. |
<!-- END_TF_DOCS -->
