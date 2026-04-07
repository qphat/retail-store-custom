variable "env_name" {
  type        = string
  description = "Environment name (dev, staging, prod)"
}

variable "cidr_block" {
  type        = string
  description = "VPC CIDR block"
  default     = "10.0.0.0/16"
}

variable "az_count" {
  type        = number
  description = "Number of availability zones to span (determines subnet count)"
  default     = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}
