output "vpc_id" {
  description = "The VPC's ID."
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "The private subnets' IDs."
  value       = module.network.private_subnet_ids
}
