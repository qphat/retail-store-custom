variable "name" {
  type        = string
  description = "ALB name prefix"
}

variable "vpc_id" {
  type        = string
  description = "VPC to create the ALB in"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnets for the ALB (must span at least 2 AZs)"
}

variable "env_name" {
  type        = string
  description = "Environment name"
}

variable "tags" {
  type    = map(string)
  default = {}
}
