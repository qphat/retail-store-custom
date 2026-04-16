variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "env_name" {
  type    = string
  default = "eks-dev"
}

variable "cidr_block" {
  type    = string
  default = "10.1.0.0/16"   # different CIDR from ECS dev (10.0.0.0/16) to allow VPC peering later
}

variable "az_count" {
  type    = number
  default = 2
}

variable "k8s_version" {
  type    = string
  default = "1.32"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"   # 2 vCPU, 4GB — fits all 5 app services + ELK
}

variable "node_desired" {
  type    = number
  default = 2
}

variable "node_min" {
  type    = number
  default = 1
}

variable "node_max" {
  type    = number
  default = 3
}

variable "jenkins_instance_type" {
  description = "EC2 instance type for Jenkins controller"
  type        = string
  default     = "t3.medium"
}

variable "jenkins_allowed_cidr" {
  description = "Your IP in CIDR notation for Jenkins UI + SSH (e.g. 1.2.3.4/32)"
  type        = string
}
