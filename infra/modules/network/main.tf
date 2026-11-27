# The VPC an environment's EKS cluster runs in (ADR 0046): public subnets for the load balancer and the
# NAT instance, private subnets for the nodes and pods, and no NAT Gateway (CLAUDE.md rule 6).

data "aws_region" "current" {}

locals {
  # The zones both maps name, in order, so every list output has the same order.
  zones = sort(keys(var.private_subnets))
}

check "same_zones" {
  assert {
    condition     = toset(keys(var.public_subnets)) == toset(keys(var.private_subnets))
    error_message = "public_subnets and private_subnets name the same availability zones."
  }
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr
  # The cluster's DNS (pods resolving AWS endpoints, private endpoint names) needs both.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

# TODO(human): the subnets and the route tables.
#   - aws_subnet.public: one per zone in var.public_subnets, no public IPs on launch, tagged for
#     internet-facing load balancers;
#   - aws_subnet.private: one per zone in var.private_subnets, tagged for internal load balancers and
#     for Karpenter's subnet discovery;
#   - aws_route_table.public, with a default route to the internet gateway, and an association per
#     public subnet;
#   - aws_route_table.private, with an association per private subnet (its default route comes from
#     the NAT instance below).
#   tests/network.tftest.hcl is the specification.

# The NAT instance: fck-nat on a t4g.nano in an Auto Scaling group of one, which replaces it if it dies
# (ADR 0046). Its static network interface keeps the Elastic IP and the private route across a
# replacement. The module adds the private route table's default route through it.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

module "nat" {
  source  = "RaJiska/fck-nat/aws"
  version = "1.6.1"

  name               = "${var.name}-nat"
  vpc_id             = aws_vpc.this.id
  subnet_id          = aws_subnet.public[local.zones[0]].id
  instance_type      = var.nat_instance_type
  ha_mode            = true
  eip_allocation_ids = [aws_eip.nat.allocation_id]

  update_route_tables = true
  route_tables_ids    = { private = aws_route_table.private.id }

  # No SSH; Session Manager works through the instance role if it's ever needed.
  use_ssh              = false
  attach_ssm_policy    = true
  use_cloudwatch_agent = false
}

# S3 through a gateway endpoint (free): ECR stores image layers in S3, so pulls skip the NAT instance.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-s3" }
}
