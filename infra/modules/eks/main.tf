# An environment's EKS cluster (ADR 0047): terraform-aws-modules/eks with a small managed node group,
# the add-ons every workload needs, and Pod Identity roles for the controllers that call AWS. What runs
# in the cluster is installed by hand for now (docs/runbooks/eks.md), and by Argo CD later.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.30.2"

  name               = var.name
  kubernetes_version = var.kubernetes_version
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids

  # The API: public, but only from the operators' addresses; the nodes use the private endpoint.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.admin_cidrs
  endpoint_private_access      = true

  # Access entries, not the aws-auth ConfigMap. Whoever runs the apply becomes the cluster's admin, so
  # no person's IAM name is written in git.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Cost: no control-plane logs and no customer-managed KMS key (EKS already encrypts secrets with a key
  # AWS owns). No IRSA OIDC provider either: the controllers use Pod Identity.
  enabled_log_types           = []
  create_cloudwatch_log_group = false
  create_kms_key              = false
  encryption_config           = null
  enable_irsa                 = false
  # The environment is torn down every night (rule 2: by a person).
  deletion_protection = false

  # Each add-on's version is EKS's default for 1.37 on 2026-11-27 (aws eks describe-addon-versions),
  # pinned, so a new cluster gets the same versions as the last one (rule 4).
  addons = {
    # Prefix delegation: each network interface gets /28 prefixes, so a t3.medium runs far more than its
    # 17 pods without it. Installed before the nodes, so they come up with it.
    vpc-cni = {
      addon_version  = "v1.22.4-eksbuild.14"
      before_compute = true
      configuration_values = jsonencode({
        env = { ENABLE_PREFIX_DELEGATION = "true", WARM_PREFIX_TARGET = "1" }
      })
    }
    eks-pod-identity-agent = { addon_version = "v1.4.1-eksbuild.3", before_compute = true }
    kube-proxy             = { addon_version = "v1.37.0-eksbuild.39" }
    coredns                = { addon_version = "v1.14.7-eksbuild.35" }
    # Volumes for Postgres (CloudNativePG); its controller calls the EC2 API through Pod Identity.
    aws-ebs-csi-driver = {
      addon_version = "v1.68.1-eksbuild.1"
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      # On-demand: a spot interruption during a game is what this environment exists to avoid tonight.
      # Karpenter, with spot first, replaces this node group later.
      capacity_type = "ON_DEMAND"
      min_size      = var.node_count
      max_size      = var.node_count + 1
      desired_size  = var.node_count
    }
  }
}

# Pod Identity: an IAM role a Kubernetes service account assumes through the EKS Pod Identity agent,
# with no OIDC provider and no annotation on the service account.
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.11.0"

  name                      = "${var.name}-ebs-csi"
  attach_aws_ebs_csi_policy = true
}

# The AWS Load Balancer Controller turns the Ingresses into the one ALB (IngressGroup rarebit).
module "lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.11.0"

  name                            = "${var.name}-aws-lb-controller"
  attach_aws_lb_controller_policy = true

  associations = {
    controller = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}
