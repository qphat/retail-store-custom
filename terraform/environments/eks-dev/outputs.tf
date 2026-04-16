output "cluster_name" {
  description = "EKS cluster name — run: aws eks update-kubeconfig --name <value>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA"
  value       = module.eks.oidc_issuer_url
}

output "cart_irsa_role_arn" {
  description = "Annotate the cart ServiceAccount with this ARN for DynamoDB access"
  value       = module.eks.cart_irsa_role_arn
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region us-east-1"
}

output "jenkins_url" {
  description = "Jenkins UI — open in browser after ~3 min for bootstrap to complete"
  value       = module.jenkins.jenkins_url
}

output "jenkins_initial_password" {
  description = "Command to get the initial Jenkins admin password"
  value       = module.jenkins.initial_password_command
}

output "jenkins_instance_id" {
  description = "Jenkins EC2 instance ID"
  value       = module.jenkins.instance_id
}
