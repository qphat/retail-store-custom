variable "service_name" {
  type        = string
  description = "Service name (ui, catalog, cart, orders, checkout)"
}

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
  description = "ECS cluster name (used for SSM path references)"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR — allows inter-service calls within the VPC"
  default     = "10.0.0.0/16"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets to run the ECS tasks in"
}

variable "alb_listener_arn" {
  type        = string
  description = "ALB HTTP listener ARN to attach listener rules to"
}

variable "alb_sg_id" {
  type        = string
  description = "ALB security group ID (service allows inbound from ALB only)"
}

# ── Container spec ────────────────────────────────────────────────────────────

variable "container_image" {
  type        = string
  description = "Full image reference e.g. koomi1/retail-app-ui:latest"
}

variable "container_port" {
  type        = number
  description = "Port the container listens on (always 8080 for this app)"
  default     = 8080
}

variable "health_check_path" {
  type        = string
  description = "HTTP path for ALB health check (/health or /actuator/health)"
}

variable "environment_vars" {
  type        = map(string)
  description = "Environment variables injected into the app container"
  default     = {}
}

# ── Sizing ────────────────────────────────────────────────────────────────────

variable "cpu" {
  type        = number
  description = "Fargate task CPU units (256=0.25vCPU, 512=0.5vCPU, 1024=1vCPU)"
}

variable "memory" {
  type        = number
  description = "Fargate task memory in MB"
}

variable "desired_count" {
  type        = number
  description = "Number of running task replicas"
  default     = 1
}

# ── ALB routing ───────────────────────────────────────────────────────────────

variable "listener_path" {
  type        = string
  description = "Path pattern for ALB listener rule e.g. /catalog* or /*"
}

variable "listener_priority" {
  type        = number
  description = "ALB listener rule priority (lower = evaluated first). Must be unique per listener."
}

# ── Service Discovery (Cloud Map) ────────────────────────────────────────────

variable "cloud_map_namespace_id" {
  type        = string
  description = "Cloud Map private DNS namespace ID ({env}.local) for service-to-service discovery"
}

# ── Logging / FireLens ────────────────────────────────────────────────────────

variable "elasticsearch_url" {
  type        = string
  description = "Elasticsearch URL for Fluent Bit output e.g. http://elasticsearch.dev.local:9200"
}

variable "fluent_bit_image" {
  type        = string
  description = "Fluent Bit image for FireLens sidecar"
  default     = "fluent/fluent-bit:3.0"
}

variable "aws_region" {
  type        = string
  description = "AWS region (used in awslogs log driver options)"
  default     = "us-east-1"
}

# ── Health check timing ───────────────────────────────────────────────────────
# Java services (Spring Boot) need a long startPeriod for JVM warmup.
# Go services start in <1s so a short startPeriod is fine.

variable "health_check_start_period" {
  type        = number
  description = "Seconds before health check failures count (Java: 60, Go/Node: 10)"
  default     = 30
}

variable "health_check_interval" {
  type        = number
  description = "Seconds between health checks"
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
