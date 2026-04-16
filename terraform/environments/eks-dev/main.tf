locals {
  common_tags = {
    Environment = var.env_name
    Project     = "retail-store"
    ManagedBy   = "terraform"
  }
}

# ── 1. VPC ────────────────────────────────────────────────────────────────────
# Same vpc module as ECS — reused without modification.
# Different CIDR (10.1.0.0/16) to avoid overlap with ECS dev VPC (10.0.0.0/16).
module "vpc" {
  source     = "../../modules/vpc"
  env_name   = var.env_name
  cidr_block = var.cidr_block
  az_count   = var.az_count
  tags       = local.common_tags
}

# ── 2. EKS Cluster ────────────────────────────────────────────────────────────
# Creates: control plane, managed node group, OIDC provider, IRSA roles.
# No ALB module — NGINX ingress controller provisions its own NLB.
# No Cloud Map — K8s DNS (CoreDNS) handles service discovery natively.
# No logging module — ELK stack is deployed via Helm chart.
module "eks" {
  source             = "../../modules/eks-cluster"
  env_name           = var.env_name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
  k8s_version        = var.k8s_version
  node_instance_type = var.node_instance_type
  node_desired       = var.node_desired
  node_min           = var.node_min
  node_max           = var.node_max
  tags               = local.common_tags
}

# ── 3. Jenkins CI/CD Controller ───────────────────────────────────────────────
# EC2 instance (t3.medium) with IAM role, EIP, and bootstrap user_data.
# No manual SSH steps — all tools installed at first boot.
# Jenkins URL: http://<EIP>:8080
module "jenkins" {
  source           = "../../modules/jenkins"
  env_name         = var.env_name
  vpc_id           = module.vpc.vpc_id
  public_subnet_id = module.vpc.public_subnet_ids[0]
  cluster_name     = module.eks.cluster_name
  aws_region       = var.aws_region
  instance_type    = var.jenkins_instance_type
  allowed_cidr     = var.jenkins_allowed_cidr
  tags             = local.common_tags
}
