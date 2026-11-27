output "vpc_id" {
  description = "The VPC's ID."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "The public subnets' IDs, in the order of their zones."
  value       = [for z in local.zones : aws_subnet.public[z].id]
}

output "private_subnet_ids" {
  description = "The private subnets' IDs, in the order of their zones: where the nodes and pods go."
  value       = [for z in local.zones : aws_subnet.private[z].id]
}

output "private_route_table_id" {
  description = "The private subnets' route table: its default route goes through the NAT instance."
  value       = aws_route_table.private.id
}

output "nat_public_ip" {
  description = "The NAT instance's Elastic IP: every outbound connection from the pods comes from it."
  value       = aws_eip.nat.public_ip
}
