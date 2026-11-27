# network

The VPC an environment's EKS cluster runs in (ADR 0046):

- **Two zones** (or more), with a public and a private subnet in each, given as `zone => CIDR` maps.
- **Public subnets** hold the ALB and the NAT instance. They hand out no public IPs and are tagged `kubernetes.io/role/elb`, so the AWS Load Balancer Controller puts internet-facing ALBs there.
- **Private subnets** hold the nodes and the pods. They're tagged `kubernetes.io/role/internal-elb` and `karpenter.sh/discovery = <cluster_name>`.
- **Routes:** the public subnets route `0.0.0.0/0` to the internet gateway, the private ones through the NAT instance.
- **The NAT instance:** [fck-nat](https://github.com/RaJiska/terraform-aws-fck-nat) 1.6.1 on a t4g.nano, in an Auto Scaling group of one, with an Elastic IP. **No NAT Gateway** (CLAUDE.md rule 6).
- **An S3 gateway endpoint** (free) on the private route table: ECR's image layers skip the NAT instance.

It's applied from `infra/live/prod/network`.

## Usage

```hcl
module "network" {
  source = "../../modules/network"

  name            = "rarebit-prod"
  cidr            = "10.40.0.0/16"
  public_subnets  = { "eu-central-1a" = "10.40.0.0/24", "eu-central-1b" = "10.40.1.0/24" }
  private_subnets = { "eu-central-1a" = "10.40.16.0/20", "eu-central-1b" = "10.40.32.0/20" }
  cluster_name    = "rarebit-prod"
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | ~> 1.17 |
| aws | 6.73.0 |
| cloudinit | 2.4.1 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.73.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| nat | RaJiska/fck-nat/aws | 1.6.1 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_default_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/default_security_group) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/eip) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/internet_gateway) | resource |
| [aws_route.public_internet](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/route) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/route_table) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/route_table_association) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/vpc) | resource |
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/resources/vpc_endpoint) | resource |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/6.73.0/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cidr | The VPC's IPv4 range. A /16 leaves room for the pods: with the VPC CNI every pod gets a VPC address. | `string` | n/a | yes |
| cluster\_name | The EKS cluster that will use this VPC: its subnet tags (load balancers, Karpenter) name it. | `string` | n/a | yes |
| name | The name of the VPC and the prefix of everything in it, e.g. rarebit-prod. | `string` | n/a | yes |
| private\_subnets | Availability zone => IPv4 range of the private subnet there: the nodes and the pods. | `map(string)` | n/a | yes |
| public\_subnets | Availability zone => IPv4 range of the public subnet there: the load balancer and the NAT instance. | `map(string)` | n/a | yes |
| nat\_ami\_id | The fck-nat AMI the NAT instance runs, pinned rather than the newest one published: fck-nat-al2023-hvm-1.4.0-20261109-arm64-ebs (2026-11-09) in eu-central-1. Bump it deliberately. | `string` | `"ami-02e293c9250757cfa"` | no |
| nat\_instance\_type | The NAT instance's type (fck-nat on Graviton, arm64). A t4g.nano is enough for image pulls and the game's egress. | `string` | `"t4g.nano"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| nat\_public\_ip | The NAT instance's Elastic IP: every outbound connection from the pods comes from it. |
| private\_route\_table\_id | The private subnets' route table: its default route goes through the NAT instance. |
| private\_subnet\_ids | The private subnets' IDs, in the order of their zones: where the nodes and pods go. |
| public\_subnet\_ids | The public subnets' IDs, in the order of their zones. |
| vpc\_id | The VPC's ID. |
<!-- END_TF_DOCS -->
