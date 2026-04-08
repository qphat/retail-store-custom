output "github_actions_role_arn" {
  description = "Set this as GitHub variable AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions.arn
}
