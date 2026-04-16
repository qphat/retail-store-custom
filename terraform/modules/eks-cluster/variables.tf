variable "env_name" {
  type        = string
  description = "Environment name prefix (e.g. eks-dev)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the EKS cluster will be created"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for EKS worker nodes"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs (tagged for ALB provisioning by NGINX ingress)"
}

variable "k8s_version" {
  type        = string
  default     = "1.32"
  description = "Kubernetes version for the EKS cluster"
}

variable "node_instance_type" {
  type        = string
  default     = "t3.medium"
  description = "EC2 instance type for worker nodes (t3.medium = 2 vCPU, 4GB RAM)"
}

variable "node_desired" {
  type        = number
  default     = 2
  description = "Desired number of worker nodes"
}

variable "node_min" {
  type        = number
  default     = 1
  description = "Minimum number of worker nodes"
}

variable "node_max" {
  type        = number
  default     = 3
  description = "Maximum number of worker nodes"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to all resources"
}
