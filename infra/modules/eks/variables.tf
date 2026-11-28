variable "name" {
  description = "The cluster's name, e.g. rarebit-prod. It also prefixes its IAM roles."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name))
    error_message = "name is 3-31 lowercase letters, digits and dashes."
  }
}

variable "kubernetes_version" {
  description = "The EKS Kubernetes version: the newest in standard support (CLAUDE.md rule 6: never one in extended support)."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version is a minor version like 1.37."
  }
}

variable "vpc_id" {
  description = "The VPC (infra/modules/network)."
  type        = string
}

variable "subnet_ids" {
  description = "The private subnets for the nodes, the pods and the control plane's network interfaces, in at least two zones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids lists at least two private subnets (EKS needs two zones)."
  }
}

variable "admin_cidrs" {
  description = "The addresses allowed to reach the cluster's public API endpoint: the operators' own IPs (/32). CI never talks to the cluster. Personal data: the unit that sets it is a private state unit (ADR 0042)."
  type        = list(string)
  sensitive   = true

  validation {
    condition = length(var.admin_cidrs) > 0 && alltrue([
      for c in var.admin_cidrs : can(cidrhost(c, 0)) && tonumber(split("/", c)[1]) >= 24
    ])
    error_message = "admin_cidrs lists at least one IPv4 range of /24 or smaller: never 0.0.0.0/0."
  }
}

variable "node_instance_types" {
  description = "The managed node group's instance types, on-demand. c7i-flex.large (2 vCPU, 4 GiB): the smallest the AWS Free plan launches with a t3.medium's memory (the plan refuses t3.medium)."
  type        = list(string)
  default     = ["c7i-flex.large"]
}

variable "node_count" {
  description = "How many nodes the managed node group runs (it can grow by one during a rolling update)."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 2 && var.node_count <= 5
    error_message = "node_count is 2 to 5: two keeps a service's replicas on two nodes."
  }
}
