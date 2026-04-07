# ── SSM Parameter: Fluent Bit config ─────────────────────────────────────────
# Stored in SSM so every app task's execution role can read it without
# baking it into the Docker image. The ecs-service module mounts it as a secret.
resource "aws_ssm_parameter" "fluent_bit_config" {
  name  = "/${var.env_name}/fluent-bit/config"
  type  = "String"
  value = templatefile("${path.module}/fluent-bit.conf.tpl", {
    es_host   = "elasticsearch.${var.env_name}.local"
    env_name  = var.env_name
    log_level = "warn"
  })

  tags = var.tags
}

# ── Cloud Map: Private DNS namespace ─────────────────────────────────────────
# Creates a private Route53 hosted zone for {env}.local inside the VPC.
# Services register DNS A records so containers can discover each other
# using names like: elasticsearch.dev.local, kibana.dev.local, ui.dev.local
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "${var.env_name}.local"
  description = "Private DNS for ${var.env_name} ECS services"
  vpc         = var.vpc_id

  tags = var.tags
}

# Cloud Map service for Elasticsearch
resource "aws_service_discovery_service" "elasticsearch" {
  name = "elasticsearch"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = var.tags
}

# Cloud Map service for Kibana
resource "aws_service_discovery_service" "kibana" {
  name = "kibana"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = var.tags
}

# ── IAM: Shared execution role for logging services ───────────────────────────
resource "aws_iam_role" "logging_execution" {
  name = "${var.env_name}-logging-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "logging_execution" {
  role       = aws_iam_role.logging_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── Security Groups ───────────────────────────────────────────────────────────

# Elasticsearch: accept 9200 from anywhere within the VPC
# (app tasks in private subnets, Kibana, and Fluent Bit sidecars all need access)
resource "aws_security_group" "elasticsearch" {
  name        = "${var.env_name}-elasticsearch-sg"
  description = "Elasticsearch: allow 9200 from VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "ES REST API from VPC"
    from_port   = 9200
    to_port     = 9200
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.env_name}-elasticsearch-sg" })
}

# Kibana: accept 5601 from ALB only
resource "aws_security_group" "kibana" {
  name        = "${var.env_name}-kibana-sg"
  description = "Kibana: allow 5601 from ALB"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Kibana UI from ALB"
    from_port       = 5601
    to_port         = 5601
    protocol        = "tcp"
    security_groups = [var.alb_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.env_name}-kibana-sg" })
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "elasticsearch" {
  name              = "/ecs/${var.env_name}/elasticsearch"
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "kibana" {
  name              = "/ecs/${var.env_name}/kibana"
  retention_in_days = 7
  tags              = var.tags
}

# ── Elasticsearch Task Definition ─────────────────────────────────────────────
# Important: ES runs without FireLens sidecar — it IS part of the logging infra.
# Sending its own logs via FireLens → ES would create a circular dependency.
resource "aws_ecs_task_definition" "elasticsearch" {
  family                   = "${var.env_name}-elasticsearch"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.es_cpu
  memory                   = var.es_memory
  execution_role_arn       = aws_iam_role.logging_execution.arn

  container_definitions = jsonencode([{
    name      = "elasticsearch"
    image     = var.elasticsearch_image
    essential = true

    portMappings = [
      { containerPort = 9200, protocol = "tcp" }
    ]

    environment = [
      # single-node: ES elects itself master, no cluster discovery needed
      # This is the only valid mode for Fargate (no persistent EBS, no inter-node discovery)
      { name = "discovery.type",                   value = "single-node" },
      { name = "xpack.security.enabled",           value = "false" },
      { name = "xpack.security.http.ssl.enabled",  value = "false" },
      { name = "ES_JAVA_OPTS",                     value = var.es_java_opts },
      # vm.max_map_count: Fargate can't run sysctl (no privileged containers).
      # bootstrap.memory_lock=false lets ES start without that check.
      { name = "bootstrap.memory_lock",            value = "false" },
      # Limit ES to the container's network interface (not 0.0.0.0 default)
      { name = "network.host",                     value = "0.0.0.0" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.env_name}/elasticsearch"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "es"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -sf http://localhost:9200/_cluster/health?pretty || exit 1"]
      interval    = 30
      timeout     = 10
      retries     = 5
      startPeriod = 60   # ES takes ~30-60s to start
    }
  }])

  tags = var.tags
}

# ── Elasticsearch ECS Service ─────────────────────────────────────────────────
resource "aws_ecs_service" "elasticsearch" {
  name            = "${var.env_name}-elasticsearch"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.elasticsearch.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.elasticsearch.id]
    assign_public_ip = false
  }

  # Register with Cloud Map so other services resolve elasticsearch.{env}.local
  service_registries {
    registry_arn = aws_service_discovery_service.elasticsearch.arn
  }

  tags = var.tags
}

# ── Kibana Task Definition ────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "kibana" {
  family                   = "${var.env_name}-kibana"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.kibana_cpu
  memory                   = var.kibana_memory
  execution_role_arn       = aws_iam_role.logging_execution.arn

  container_definitions = jsonencode([{
    name      = "kibana"
    image     = var.kibana_image
    essential = true

    portMappings = [
      { containerPort = 5601, protocol = "tcp" }
    ]

    environment = [
      # Kibana reaches ES via Cloud Map DNS (same pattern as Helm chart's ClusterIP DNS)
      { name = "ELASTICSEARCH_HOSTS",   value = "http://elasticsearch.${var.env_name}.local:9200" },
      # Sub-path routing — same as Helm chart's SERVER_BASEPATH
      { name = "SERVER_BASEPATH",       value = "/kibana" },
      { name = "SERVER_REWRITEBASEPATH", value = "true" },
      { name = "NODE_OPTIONS",          value = "--max-old-space-size=1024" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.env_name}/kibana"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "kibana"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -sf http://localhost:5601/kibana/api/status || exit 1"]
      interval    = 30
      timeout     = 10
      retries     = 5
      startPeriod = 90   # Kibana waits for ES then initialises plugins — takes a while
    }
  }])

  tags = var.tags
}

# ── Kibana ALB Target Group + Listener Rule ───────────────────────────────────
resource "aws_lb_target_group" "kibana" {
  name        = "${var.env_name}-kibana"
  port        = 5601
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/kibana/api/status"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 30
    timeout             = 10
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "kibana" {
  listener_arn = var.alb_listener_arn
  priority     = 5   # evaluated before app services (low number = high priority)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kibana.arn
  }

  condition {
    path_pattern {
      values = ["/kibana*"]
    }
  }

  tags = var.tags
}

# ── Kibana ECS Service ────────────────────────────────────────────────────────
resource "aws_ecs_service" "kibana" {
  name            = "${var.env_name}-kibana"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.kibana.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.kibana.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.kibana.arn
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.kibana.arn
    container_name   = "kibana"
    container_port   = 5601
  }

  depends_on = [
    aws_ecs_service.elasticsearch,   # Kibana needs ES running first
    aws_lb_listener_rule.kibana,
  ]

  tags = var.tags
}

# ── Kibana Setup Task Definition (one-shot, like K8s Job) ─────────────────────
# Not run automatically — trigger manually after Kibana is healthy:
#   aws --endpoint-url=http://localhost:4566 ecs run-task \
#     --cluster dev-retail-store --task-definition dev-kibana-setup \
#     --launch-type FARGATE \
#     --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx]}"
resource "aws_ecs_task_definition" "kibana_setup" {
  family                   = "${var.env_name}-kibana-setup"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.logging_execution.arn

  container_definitions = jsonencode([{
    name      = "kibana-setup"
    image     = "curlimages/curl:8.7.1"
    essential = true

    command = [
      "sh", "-c",
      <<-EOT
        echo "Waiting for Kibana to be ready..."
        until curl -sf http://kibana.${var.env_name}.local:5601/kibana/api/status; do
          echo "Kibana not ready, retrying in 10s..."; sleep 10;
        done
        echo "Creating data view logs-*..."
        curl -X POST http://kibana.${var.env_name}.local:5601/kibana/api/data_views/data_view \
          -H "kbn-xsrf: true" \
          -H "Content-Type: application/json" \
          -d '{"data_view":{"title":"logs-*","name":"retail-store-logs","timeFieldName":"@timestamp"}}'
        echo "Done."
      EOT
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.env_name}/kibana"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "kibana-setup"
      }
    }
  }])

  tags = var.tags
}
