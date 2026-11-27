# `terraform test` in the module directory (make infra). The AWS provider is mocked: nothing reaches
# AWS and no credentials are needed. `apply` here applies to the mock only, so the IDs the assertions
# compare are the mock's. These are the specification of the subnets and the routes.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-central-1" }
  }
}

# fck-nat's own instance, AMI lookup and IAM aren't this module's to test; only its inputs are.
override_module {
  target  = module.nat
  outputs = {}
}

variables {
  name            = "rarebit-test"
  cidr            = "10.40.0.0/16"
  public_subnets  = { "eu-central-1a" = "10.40.0.0/24", "eu-central-1b" = "10.40.1.0/24" }
  private_subnets = { "eu-central-1a" = "10.40.16.0/20", "eu-central-1b" = "10.40.32.0/20" }
  cluster_name    = "rarebit-test"
}

run "subnets_per_zone" {
  command = apply

  assert {
    condition     = keys(aws_subnet.public) == ["eu-central-1a", "eu-central-1b"] && keys(aws_subnet.private) == ["eu-central-1a", "eu-central-1b"]
    error_message = "One public and one private subnet per zone, keyed by the zone."
  }

  assert {
    condition     = alltrue([for z, s in aws_subnet.public : s.availability_zone == z && s.cidr_block == var.public_subnets[z]])
    error_message = "Each public subnet sits in its zone, with its range."
  }

  assert {
    condition     = alltrue([for z, s in aws_subnet.private : s.availability_zone == z && s.cidr_block == var.private_subnets[z]])
    error_message = "Each private subnet sits in its zone, with its range."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.vpc_id == aws_vpc.this.id && s.map_public_ip_on_launch == false])
    error_message = "Public subnets are in this VPC and hand out no public IPs: only the NAT instance's Elastic IP and the load balancer face the internet."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.private : s.vpc_id == aws_vpc.this.id])
    error_message = "Private subnets are in this VPC."
  }
}

run "subnet_tags_for_the_controllers" {
  command = apply

  assert {
    condition     = alltrue([for s in aws_subnet.public : lookup(s.tags, "kubernetes.io/role/elb", "") == "1"])
    error_message = "Public subnets carry kubernetes.io/role/elb=1: the AWS Load Balancer Controller puts internet-facing ALBs there."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.private : lookup(s.tags, "kubernetes.io/role/internal-elb", "") == "1"])
    error_message = "Private subnets carry kubernetes.io/role/internal-elb=1, for internal load balancers."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.private : lookup(s.tags, "karpenter.sh/discovery", "") == var.cluster_name])
    error_message = "Private subnets carry karpenter.sh/discovery=<cluster>: Karpenter finds the subnets for new nodes by it."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : lookup(s.tags, "karpenter.sh/discovery", "") == ""])
    error_message = "No node ever goes in a public subnet."
  }
}

run "routes" {
  command = apply

  assert {
    condition     = aws_route.public_internet.route_table_id == aws_route_table.public.id && aws_route.public_internet.destination_cidr_block == "0.0.0.0/0" && aws_route.public_internet.gateway_id == aws_internet_gateway.this.id
    error_message = "The public route table sends 0.0.0.0/0 to the internet gateway."
  }

  assert {
    condition     = alltrue([for z, s in aws_subnet.public : aws_route_table_association.public[z].subnet_id == s.id && aws_route_table_association.public[z].route_table_id == aws_route_table.public.id])
    error_message = "Every public subnet uses the public route table."
  }

  assert {
    condition     = alltrue([for z, s in aws_subnet.private : aws_route_table_association.private[z].subnet_id == s.id && aws_route_table_association.private[z].route_table_id == aws_route_table.private.id])
    error_message = "Every private subnet uses the private route table."
  }

  assert {
    condition     = aws_route_table.private.vpc_id == aws_vpc.this.id && aws_route_table.public.vpc_id == aws_vpc.this.id
    error_message = "Both route tables are this VPC's."
  }

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && aws_vpc_endpoint.s3.route_table_ids == toset([aws_route_table.private.id])
    error_message = "S3 is a gateway endpoint on the private route table, so image layers skip the NAT instance."
  }

  assert {
    condition     = output.private_subnet_ids == [aws_subnet.private["eu-central-1a"].id, aws_subnet.private["eu-central-1b"].id]
    error_message = "private_subnet_ids lists the subnets in zone order."
  }
}

run "refuses_one_zone" {
  command = plan

  variables {
    public_subnets  = { "eu-central-1a" = "10.40.0.0/24" }
    private_subnets = { "eu-central-1a" = "10.40.16.0/20" }
  }

  expect_failures = [var.public_subnets, var.private_subnets]
}

run "refuses_a_small_vpc" {
  command = plan

  variables {
    cidr = "10.40.0.0/24"
  }

  expect_failures = [var.cidr]
}

run "refuses_an_x86_nat_type" {
  command = plan

  variables {
    nat_instance_type = "t3.nano"
  }

  expect_failures = [var.nat_instance_type]
}
