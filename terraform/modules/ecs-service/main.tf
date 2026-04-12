locals {
  full_name      = "${var.env_name}-${var.service_name}"
  log_group_app  = "/ecs/${var.env_name}/${var.service_name}"
  log_group_flb  = "/ecs/${var.env_name}/${var.service_name}/firelens"

  # Parse ES host/port from the URL for Fluent Bit config
  # elasticsearch_url = "http://elasticsearch.dev.local:9200"
  es_host = replace(replace(var.elasticsearch_url, "http://", ""), ":9200", "")
}

# ── IAM: Execution Role ───────────────────────────────────────────────────────
# ECS uses this to: pull Docker images, push logs to CloudWatch, read SSM secrets
resource "aws_iam_role" "execution" {
  name = "${local.full_name}-execution-role"

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

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow the execution role to read SSM parameters (for Fluent Bit config)
resource "aws_iam_role_policy" "execution_ssm" {
  name = "ssm-read"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters", "ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.env_name}/*"
    }]
  })
}

# ── IAM: Task Role ────────────────────────────────────────────────────────────
# The app code runs with this role. Currently empty — services use in-memory persistence.
# Add policies here when services need S3, SQS, DynamoDB etc.
resource "aws_iam_role" "task" {
  name = "${local.full_name}-task-role"

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

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_app
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "firelens" {
  name              = local.log_group_flb
  retention_in_days = 3    # Fluent Bit operational logs — shorter retention is fine
  tags              = var.tags
}

# ── Task Definition ───────────────────────────────────────────────────────────
# Two containers per task:
#   1. log_router — Fluent Bit FireLens sidecar
#   2. <service>  — the application container
resource "aws_ecs_task_definition" "this" {
  family                   = local.full_name
  network_mode             = "awsvpc"    # required for Fargate
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    # ── Container 1: FireLens log router (Fluent Bit sidecar) ──
    # Uses AWS-managed FireLens config (no custom config file needed).
    # App container specifies the output plugin + ES connection in its log options.
    {
      name      = "log_router"
      image     = var.fluent_bit_image
      essential = false   # if Fluent Bit crashes, app container keeps running

      # AWS-managed FireLens: no custom config-file, AWS injects the base config.
      # Output plugin config comes from the app container's logConfiguration.options.
      firelensConfiguration = {
        type    = "fluentbit"
        options = {}
      }

      # Fluent Bit's own operational logs go to CloudWatch directly (not via FireLens —
      # that would create a loop where Fluent Bit tries to route its own logs through itself)
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.log_group_flb
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "firelens"
        }
      }

      mountPoints  = []
      volumesFrom  = []
      portMappings = []
    },

    # ── Container 2: Application container ──
    {
      name      = var.service_name
      image     = var.container_image
      essential = true

      portMappings = [
        { containerPort = var.container_port, protocol = "tcp" }
      ]

      environment = [
        for k, v in var.environment_vars : { name = k, value = v }
      ]

      # awsfirelens routes stdout → log_router (Fluent Bit) → Elasticsearch.
      # Name = output plugin; Host/Port/Index = ES connection details.
      # ECS generates a valid Fluent Bit [OUTPUT] section from these options.
      logConfiguration = {
        logDriver = "awsfirelens"
        options = {
          "Name"        = "es"
          "Host"        = local.es_host
          "Port"        = "9200"
          "Index"       = "logs-${var.service_name}"
          "Retry_Limit" = "2"
          "tls"         = "Off"
          "tls.verify"  = "Off"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -sf http://localhost:${var.container_port}${var.health_check_path} || exit 1"]
        interval    = var.health_check_interval
        timeout     = 5
        retries     = 3
        startPeriod = var.health_check_start_period
      }

      # Wait for Fluent Bit to be running before starting the app.
      dependsOn = [
        { containerName = "log_router", condition = "START" }
      ]
    }
  ])

  tags = var.tags
}

# ── Cloud Map Service Discovery ───────────────────────────────────────────────
# Registers an A record in {env}.local so other services can resolve
# {service}.{env}.local → task private IP (e.g. catalog.dev.local → 10.0.x.x)
resource "aws_service_discovery_service" "this" {
  name = var.service_name

  dns_config {
    namespace_id   = var.cloud_map_namespace_id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# ── Security Group ────────────────────────────────────────────────────────────
# Tasks only accept traffic from the ALB — not directly from the internet.
resource "aws_security_group" "service" {
  name        = "${local.full_name}-sg"
  description = "${var.service_name}: accept traffic from ALB only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "From ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_sg_id]
  }

  ingress {
    description = "Inter-service calls within VPC (Cloud Map service discovery)"
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound (ES, image pulls, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${local.full_name}-sg" })
}

# ── ALB Target Group ──────────────────────────────────────────────────────────
# Fargate tasks register as IP targets (not instance targets) because they use awsvpc networking.
resource "aws_lb_target_group" "this" {
  name        = local.full_name
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"   # required for Fargate awsvpc mode

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = var.tags
}

# ── ALB Listener Rule ─────────────────────────────────────────────────────────
resource "aws_lb_listener_rule" "this" {
  listener_arn = var.alb_listener_arn
  priority     = var.listener_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    path_pattern {
      values = [var.listener_path]
    }
  }

  tags = var.tags
}

# ── ECS Service ───────────────────────────────────────────────────────────────
resource "aws_ecs_service" "this" {
  name            = local.full_name
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = false   # tasks are in private subnets, behind NAT
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.service_name
    container_port   = var.container_port
  }

  # Deployment settings — how ECS rolls out new task definition versions
  deployment_minimum_healthy_percent = 50    # in dev: allow 0 running during deploy
  deployment_maximum_percent         = 200   # spin up new tasks before killing old

  # Register with Cloud Map so other services resolve {service}.{env}.local
  service_registries {
    registry_arn = aws_service_discovery_service.this.arn
  }

  # Ensure the ALB listener rule exists before creating the service
  # (service registration fails if target group isn't attached to a listener)
  depends_on = [aws_lb_listener_rule.this]

  tags = var.tags
}
