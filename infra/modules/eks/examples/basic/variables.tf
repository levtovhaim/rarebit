variable "vpc_id" {
  description = "A VPC with private subnets in two zones (infra/modules/network/examples/basic)."
  type        = string
}

variable "subnet_ids" {
  description = "Its private subnets."
  type        = list(string)
}

variable "admin_cidrs" {
  description = "Your own address as a /32: the only one that may reach the cluster's API."
  type        = list(string)
}
