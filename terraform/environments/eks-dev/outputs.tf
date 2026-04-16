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
