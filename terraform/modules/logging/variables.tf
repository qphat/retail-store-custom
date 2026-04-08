variable "env_name" {
  type        = string
  description = "Environment name"
}

variable "cluster_id" {
  type        = string
  description = "ECS cluster ID"
}

variable "cluster_name" {
  type        = string
  description = "ECS cluster name"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets to run ES and Kibana tasks in"
}

variable "alb_listener_arn" {
  type        = string
  description = "ALB listener ARN (Kibana adds a listener rule here)"
}

variable "alb_sg_id" {
  type        = string
  description = "ALB security group ID"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block — Elasticsearch allows inbound from this range"
}

variable "elasticsearch_image" {
  type    = string
  default = "elasticsearch:8.13.0"
}

variable "kibana_image" {
  type    = string
  default = "kibana:8.13.0"
}

variable "es_cpu" {
  type    = number
  default = 1024
}

variable "es_memory" {
  type    = number
  default = 2048
}

variable "es_java_opts" {
  type    = string
  default = "-Xms512m -Xmx512m"
}

variable "kibana_cpu" {
  type    = number
  default = 512
}

variable "kibana_memory" {
  type    = number
  default = 1024
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "tags" {
  type    = map(string)
  default = {}
}
