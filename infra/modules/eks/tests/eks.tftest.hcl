# `terraform test` in the module directory (make infra). The AWS provider is mocked and the community
# modules are overridden: nothing reaches AWS and no credentials are needed. What's tested is this
# module's own rules, its inputs' validations.

mock_provider "aws" {}
mock_provider "tls" {}
mock_provider "time" {}
mock_provider "cloudinit" {}
mock_provider "null" {}

override_module {
  target = module.eks
  outputs = {
    cluster_name           = "rarebit-test"
    cluster_endpoint       = "https://example.eks.amazonaws.com"
    node_security_group_id = "sg-00000000000000000"
  }
}

override_module {
  target  = module.ebs_csi_pod_identity
  outputs = { iam_role_arn = "arn:aws:iam::000000000000:role/rarebit-test-ebs-csi" }
}

override_module {
  target  = module.lb_controller_pod_identity
  outputs = { iam_role_arn = "arn:aws:iam::000000000000:role/rarebit-test-aws-lb-controller" }
}

variables {
  name               = "rarebit-test"
  kubernetes_version = "1.37"
  vpc_id             = "vpc-00000000000000000"
  subnet_ids         = ["subnet-00000000000000001", "subnet-00000000000000002"]
  admin_cidrs        = ["192.0.2.10/32"]
}

run "plans" {
  command = plan

  assert {
    condition     = output.cluster_name == "rarebit-test"
    error_message = "The cluster's name comes through."
  }
}

run "refuses_an_api_open_to_the_world" {
  command = plan

  variables {
    admin_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.admin_cidrs]
}

run "refuses_a_wide_api_range" {
  command = plan

  variables {
    admin_cidrs = ["10.0.0.0/8"]
  }

  expect_failures = [var.admin_cidrs]
}

run "refuses_no_admin_range" {
  command = plan

  variables {
    admin_cidrs = []
  }

  expect_failures = [var.admin_cidrs]
}

run "refuses_one_subnet" {
  command = plan

  variables {
    subnet_ids = ["subnet-00000000000000001"]
  }

  expect_failures = [var.subnet_ids]
}

run "refuses_one_node" {
  command = plan

  variables {
    node_count = 1
  }

  expect_failures = [var.node_count]
}

run "refuses_a_patch_version" {
  command = plan

  variables {
    kubernetes_version = "1.37.2"
  }

  expect_failures = [var.kubernetes_version]
}
