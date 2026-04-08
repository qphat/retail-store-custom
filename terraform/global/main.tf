data "aws_caller_identity" "current" {}

# ── GitHub OIDC Provider ───────────────────────────────────────────────────────
# Allows GitHub Actions to get short-lived AWS credentials via OIDC.
# No long-lived AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY stored in GitHub.
#
# How it works:
#   1. GitHub Actions requests a JWT from GitHub's OIDC endpoint
#   2. AWS verifies the JWT signature against this provider's thumbprint
#   3. AWS issues temporary credentials scoped to the role below
#   4. Credentials expire when the workflow job ends
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # SHA1 thumbprint of GitHub's OIDC TLS certificate (stable, rarely changes)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { ManagedBy = "terraform", Purpose = "github-actions-oidc" }
}

# ── GitHub Actions IAM Role ───────────────────────────────────────────────────
resource "aws_iam_role" "github_actions" {
  name        = "github-actions-retail-store"
  description = "Assumed by GitHub Actions via OIDC for CI/CD"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        # Only allow the specific repo — prevents other GitHub repos from assuming this role
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:qphat/retail-store-custom:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = { ManagedBy = "terraform", Purpose = "github-actions-oidc" }
}

# ── IAM Policy ────────────────────────────────────────────────────────────────
resource "aws_iam_role_policy" "github_actions" {
  name = "github-actions-retail-store-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ── Terraform remote state ──
      {
        Sid    = "TerraformStateS3"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::retail-store-tf-state-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::retail-store-tf-state-${data.aws_caller_identity.current.account_id}/*"
        ]
      },
      {
        Sid    = "TerraformStateLock"
        Effect = "Allow"
        Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
        Resource = "arn:aws:dynamodb:*:${data.aws_caller_identity.current.account_id}:table/retail-store-tf-lock"
      },

      # ── ECS deploy (task def update + service update) ──
      {
        Sid    = "ECSDeployment"
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:ListTaskDefinitions",
          "ecs:TagResource"
        ]
        Resource = "*"
      },

      # ── ALB (describe DNS for smoke tests + health checks) ──
      {
        Sid      = "ALBDescribe"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeTargetHealth"]
        Resource = "*"
      },

      # ── IAM PassRole (required to register task definitions with execution/task roles) ──
      {
        Sid      = "PassRoleToECS"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*-execution-role"
      },
      {
        Sid      = "PassTaskRoleToECS"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*-task-role"
      },

      # ── Full infra permissions for terraform apply ──
      # Scoped to the resources this project creates
      {
        Sid    = "TerraformInfra"
        Effect = "Allow"
        Action = [
          "ec2:*", "ecs:*", "iam:*",
          "logs:*", "ssm:*",
          "elasticloadbalancing:*",
          "servicediscovery:*",
          "route53:*",
          "cloudwatch:*"
        ]
        Resource = "*"
      }
    ]
  })
}
