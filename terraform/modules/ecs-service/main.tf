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
    {
      name      = "log_router"
      image     = var.fluent_bit_image
      essential = false   # if Fluent Bit crashes, app container keeps running

      # firelensConfiguration turns this container into the FireLens log router.
      # AWS injects it as a log broker — app container's awsfirelens log driver
      # sends logs here via a Unix socket in the shared task network namespace.
      firelensConfiguration = {
        type = "fluentbit"
        options = {
          # We provide a custom config rather than the AWS-managed default,
          # so we can control the Elasticsearch output settings.
          "config-file-type"  = "file"
          "config-file-value" = "/fluent-bit/etc/fluent-bit.conf"
        }
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

      environment = [
        { name = "ES_HOST",      value = local.es_host },
        { name = "ENV_NAME",     value = var.env_name },
        { name = "SERVICE_NAME", value = var.service_name },
        { name = "FLB_LOG_LEVEL", value = "warn" }
      ]

      # Fluent Bit config is mounted from SSM via a secret (populated by logging module)
      secrets = [
        {
          name      = "FLUENT_BIT_CONFIG"
          valueFrom = "/${var.env_name}/fluent-bit/config"
        }
      ]

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

      # KEY DIFFERENCE FROM K8s: instead of awslogs, use awsfirelens.
      # ECS intercepts this container's stdout and sends it to the log_router container.
      # The log_router (Fluent Bit) then routes it to Elasticsearch.
      logConfiguration = {
        logDriver = "awsfirelens"
        options = {
          # These become Fluent Bit record fields, available in filter rules
          "service" = var.service_name
          "env"     = var.env_name
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
      # START = container process started (not necessarily healthy).
      # We use START not HEALTHY to avoid needing a healthcheck on the sidecar.
      dependsOn = [
        { containerName = "log_router", condition = "START" }
      ]
    }
  ])

  tags = var.tags
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

  # Ensure the ALB listener rule exists before creating the service
  # (service registration fails if target group isn't attached to a listener)
  depends_on = [aws_lb_listener_rule.this]

  tags = var.tags
}
