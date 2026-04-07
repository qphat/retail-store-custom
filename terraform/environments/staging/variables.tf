variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "env_name" {
  type    = string
  default = "dev"
}

variable "cidr_block" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

# ── UI service sizing ─────────────────────────────────────────────────────────
variable "ui_cpu" {
  type    = number
  default = 512
}

variable "ui_memory" {
  type    = number
  default = 1024
}

variable "ui_desired_count" {
  type    = number
  default = 1
}

# ── Catalog service sizing ────────────────────────────────────────────────────
variable "catalog_cpu" {
  type    = number
  default = 256
}

variable "catalog_memory" {
  type    = number
  default = 512
}

variable "catalog_desired_count" {
  type    = number
  default = 1
}

# ── Elasticsearch sizing ──────────────────────────────────────────────────────
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

# ── Kibana sizing ─────────────────────────────────────────────────────────────
variable "kibana_cpu" {
  type    = number
  default = 512
}

variable "kibana_memory" {
  type    = number
  default = 1536
}
