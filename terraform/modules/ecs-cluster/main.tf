resource "aws_ecs_cluster" "main" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  tags = merge(var.tags, { Name = var.cluster_name })
}

# Cluster-level log group — used for ECS exec logs, cluster events
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/ecs/${var.env_name}/cluster"
  retention_in_days = 7   # short retention for learning; use 30+ in prod

  tags = var.tags
}
