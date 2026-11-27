output "cluster_name" {
  description = "The cluster's name, for `aws eks update-kubeconfig --name`."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "The Kubernetes API's URL."
  value       = module.eks.cluster_endpoint
}

output "node_security_group_id" {
  description = "The nodes' security group."
  value       = module.eks.node_security_group_id
}

output "lb_controller_role_arn" {
  description = "The AWS Load Balancer Controller's IAM role, assumed through Pod Identity by kube-system/aws-load-balancer-controller."
  value       = module.lb_controller_pod_identity.iam_role_arn
}
