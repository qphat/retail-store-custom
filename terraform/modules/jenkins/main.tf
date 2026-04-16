# ── Data sources ──────────────────────────────────────────────────────────────

# Latest Ubuntu 22.04 LTS (Jammy) AMI — HVM, x86_64, SSD
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "jenkins" {
  name        = "${var.env_name}-jenkins"
  description = "Jenkins controller — UI (8080) and SSH (22) from allowed CIDR only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  # Jenkins JNLP agent port (if you add inbound agents later)
  ingress {
    description = "JNLP agents"
    from_port   = 50000
    to_port     = 50000
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.env_name}-jenkins" })
}

# ── IAM Role + Instance Profile ───────────────────────────────────────────────

resource "aws_iam_role" "jenkins" {
  name = "${var.env_name}-jenkins"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "jenkins" {
  name = "${var.env_name}-jenkins-policy"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # EKS — update-kubeconfig at boot + pipeline deploys
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListClusters", "eks:AccessKubernetesApi"]
        Resource = "*"
      },
      # ECR — push/pull images (used instead of Docker Hub if you switch registries)
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:PutImage"]
        Resource = "*"
      },
      # Terraform remote state — S3 read/write + DynamoDB lock
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::retail-store-tf-state-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::retail-store-tf-state-${data.aws_caller_identity.current.account_id}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/retail-store-tf-lock"
      },
      # ECS deploy (cicd.yml equivalent path — optional but useful)
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition",
          "ecs:UpdateService", "ecs:DescribeServices",
          "ecs:ListTaskDefinitions", "ecs:DeregisterTaskDefinition"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:DescribeLoadBalancers"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*-execution-role"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.env_name}-jenkins"
  role = aws_iam_role.jenkins.name
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_id
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name
  vpc_security_group_ids = [aws_security_group.jenkins.id]

  # Bootstrap script installs Jenkins + all CI/CD tools
  user_data = templatefile("${path.module}/user_data.sh", {
    cluster_name = var.cluster_name
    aws_region   = var.aws_region
  })

  root_block_device {
    volume_size           = var.volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # Prevent accidental instance replacement when user_data changes
  # (re-bootstrap requires manual instance recreation)
  lifecycle {
    ignore_changes = [user_data]
  }

  tags = merge(var.tags, { Name = "${var.env_name}-jenkins" })
}

# ── Elastic IP ────────────────────────────────────────────────────────────────
# Stable public IP — GitHub webhook URL won't break after stop/start

resource "aws_eip" "jenkins" {
  instance = aws_instance.jenkins.id
  domain   = "vpc"

  tags = merge(var.tags, { Name = "${var.env_name}-jenkins" })
}
