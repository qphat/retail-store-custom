variable "cluster_name" {
  type        = string
  description = "ECS cluster name"
}

variable "env_name" {
  type        = string
  description = "Environment name"
}

variable "container_insights" {
  type        = bool
  description = "Enable CloudWatch Container Insights (costs extra — disable for dev)"
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
