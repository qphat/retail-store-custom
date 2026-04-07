# ── ALB Security Group ─────────────────────────────────────────────────────────
# Allow inbound HTTP from anywhere; egress to ECS tasks (handled by task SG).
resource "aws_security_group" "alb" {
  name        = "${var.env_name}-alb-sg"
  description = "ALB: allow HTTP from internet"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.env_name}-alb-sg" })
}

# ── Application Load Balancer ─────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = var.name
  internal           = false          # internet-facing
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  # For prod you'd enable: access_logs { bucket = "..." }
  tags = merge(var.tags, { Name = var.name })
}

# ── Default Target Group ───────────────────────────────────────────────────────
# Handles requests that don't match any listener rule (returns 404).
resource "aws_lb_target_group" "default" {
  name     = "${var.env_name}-default-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  tags = var.tags
}

# ── HTTP Listener ──────────────────────────────────────────────────────────────
# Individual services add listener rules via the ecs-service module.
# Default action = 404 (no service matched).
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.default.arn
  }

  tags = var.tags
}
