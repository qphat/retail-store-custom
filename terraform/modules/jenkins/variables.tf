variable "env_name" {
  description = "Environment name prefix for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to launch the Jenkins instance into"
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet ID — Jenkins needs a public IP for the GitHub webhook"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — user_data runs aws eks update-kubeconfig at boot"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for Jenkins"
  type        = string
  default     = "t3.medium"
}

variable "volume_size_gb" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "allowed_cidr" {
  description = "Your IP in CIDR notation for Jenkins UI + SSH (e.g. 1.2.3.4/32). Use 0.0.0.0/0 only for testing."
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
