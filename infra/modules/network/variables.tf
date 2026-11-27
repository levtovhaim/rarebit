variable "name" {
  description = "The name of the VPC and the prefix of everything in it, e.g. rarebit-prod."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name))
    error_message = "name is 3-31 lowercase letters, digits and dashes."
  }
}

variable "cidr" {
  description = "The VPC's IPv4 range. A /16 leaves room for the pods: with the VPC CNI every pod gets a VPC address."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) <= 16
    error_message = "cidr is an IPv4 range of /16 or larger."
  }
}

variable "public_subnets" {
  description = "Availability zone => IPv4 range of the public subnet there: the load balancer and the NAT instance."
  type        = map(string)

  validation {
    condition     = length(var.public_subnets) >= 2 && alltrue([for c in values(var.public_subnets) : can(cidrhost(c, 0))])
    error_message = "public_subnets has at least two zones, each with an IPv4 range (an ALB needs two)."
  }
}

variable "private_subnets" {
  description = "Availability zone => IPv4 range of the private subnet there: the nodes and the pods."
  type        = map(string)

  validation {
    condition     = length(var.private_subnets) >= 2 && alltrue([for c in values(var.private_subnets) : can(cidrhost(c, 0))])
    error_message = "private_subnets has at least two zones, each with an IPv4 range."
  }
}

variable "cluster_name" {
  description = "The EKS cluster that will use this VPC: its subnet tags (load balancers, Karpenter) name it."
  type        = string
}

variable "nat_instance_type" {
  description = "The NAT instance's type (fck-nat on Graviton, arm64). A t4g.nano is enough for image pulls and the game's egress."
  type        = string
  default     = "t4g.nano"

  validation {
    condition     = can(regex("^t4g\\.", var.nat_instance_type))
    error_message = "The NAT instance runs the arm64 fck-nat image: use a t4g type."
  }
}
