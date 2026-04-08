locals {
  common_tags = {
    Environment = var.env_name
    Project     = "retail-store"
    ManagedBy   = "terraform"
  }
}

# ── 1. VPC ────────────────────────────────────────────────────────────────────
module "vpc" {
  source     = "../../modules/vpc"
  env_name   = var.env_name
  cidr_block = var.cidr_block
  az_count   = var.az_count
  tags       = local.common_tags
}

# ── 2. ECS Cluster ────────────────────────────────────────────────────────────
module "ecs_cluster" {
  source       = "../../modules/ecs-cluster"
  cluster_name = "${var.env_name}-retail-store"
  env_name     = var.env_name
  tags         = local.common_tags
}

# ── 3. Application Load Balancer ──────────────────────────────────────────────
module "alb" {
  source            = "../../modules/alb"
  name              = "${var.env_name}-retail-store"
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  env_name          = var.env_name
  tags              = local.common_tags
}

# ── 4. EFK Logging Stack ──────────────────────────────────────────────────────
module "logging" {
  source             = "../../modules/logging"
  env_name           = var.env_name
  cluster_id         = module.ecs_cluster.cluster_id
  cluster_name       = module.ecs_cluster.cluster_name
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = var.cidr_block
  private_subnet_ids = module.vpc.private_subnet_ids
  alb_listener_arn   = module.alb.alb_listener_arn
  alb_sg_id          = module.alb.alb_sg_id
  es_cpu             = var.es_cpu
  es_memory          = var.es_memory
  es_java_opts       = var.es_java_opts
  kibana_cpu         = var.kibana_cpu
  kibana_memory      = var.kibana_memory
  aws_region         = var.aws_region
  tags               = local.common_tags
}

# ── 5. Catalog Service ────────────────────────────────────────────────────────
module "catalog_service" {
  source                 = "../../modules/ecs-service"
  service_name           = "catalog"
  env_name               = var.env_name
  cluster_id             = module.ecs_cluster.cluster_id
  cluster_name           = module.ecs_cluster.cluster_name
  vpc_id                 = module.vpc.vpc_id
  vpc_cidr               = var.cidr_block
  private_subnet_ids     = module.vpc.private_subnet_ids
  alb_listener_arn       = module.alb.alb_listener_arn
  alb_sg_id              = module.alb.alb_sg_id
  cloud_map_namespace_id = module.logging.cloud_map_namespace_id

  container_image   = "koomi1/retail-app-catalog:latest"
  container_port    = 8080
  health_check_path = "/health"
  cpu               = var.catalog_cpu
  memory            = var.catalog_memory
  desired_count     = var.catalog_desired_count

  listener_path     = "/catalogue*"
  listener_priority = 10

  elasticsearch_url         = module.logging.elasticsearch_url
  health_check_start_period = 10
  health_check_interval     = 20

  environment_vars = {
    RETAIL_CATALOG_PERSISTENCE_PROVIDER = "memory"
  }

  aws_region = var.aws_region
  tags       = local.common_tags
  depends_on = [module.logging]
}

# ── 6. Cart Service ───────────────────────────────────────────────────────────
module "cart_service" {
  source                 = "../../modules/ecs-service"
  service_name           = "cart"
  env_name               = var.env_name
  cluster_id             = module.ecs_cluster.cluster_id
  cluster_name           = module.ecs_cluster.cluster_name
  vpc_id                 = module.vpc.vpc_id
  vpc_cidr               = var.cidr_block
  private_subnet_ids     = module.vpc.private_subnet_ids
  alb_listener_arn       = module.alb.alb_listener_arn
  alb_sg_id              = module.alb.alb_sg_id
  cloud_map_namespace_id = module.logging.cloud_map_namespace_id

  container_image   = "koomi1/retail-app-cart:latest"
  container_port    = 8080
  health_check_path = "/actuator/health"
  cpu               = var.cart_cpu
  memory            = var.cart_memory
  desired_count     = var.cart_desired_count

  listener_path     = "/api/cart*"
  listener_priority = 20

  elasticsearch_url         = module.logging.elasticsearch_url
  health_check_start_period = 60
  health_check_interval     = 30

  environment_vars = {
    RETAIL_CART_PERSISTENCE_PROVIDER = "in-memory"
  }

  aws_region = var.aws_region
  tags       = local.common_tags
  depends_on = [module.logging]
}

# ── 7. Orders Service ─────────────────────────────────────────────────────────
module "orders_service" {
  source                 = "../../modules/ecs-service"
  service_name           = "orders"
  env_name               = var.env_name
  cluster_id             = module.ecs_cluster.cluster_id
  cluster_name           = module.ecs_cluster.cluster_name
  vpc_id                 = module.vpc.vpc_id
  vpc_cidr               = var.cidr_block
  private_subnet_ids     = module.vpc.private_subnet_ids
  alb_listener_arn       = module.alb.alb_listener_arn
  alb_sg_id              = module.alb.alb_sg_id
  cloud_map_namespace_id = module.logging.cloud_map_namespace_id

  container_image   = "koomi1/retail-app-orders:latest"
  container_port    = 8080
  health_check_path = "/actuator/health"
  cpu               = var.orders_cpu
  memory            = var.orders_memory
  desired_count     = var.orders_desired_count

  listener_path     = "/api/orders*"
  listener_priority = 30

  elasticsearch_url         = module.logging.elasticsearch_url
  health_check_start_period = 60
  health_check_interval     = 30

  environment_vars = {
    RETAIL_ORDERS_PERSISTENCE_PROVIDER = "in-memory"
    RETAIL_ORDERS_MESSAGING_PROVIDER   = "in-memory"
  }

  aws_region = var.aws_region
  tags       = local.common_tags
  depends_on = [module.logging]
}

# ── 8. Checkout Service ───────────────────────────────────────────────────────
module "checkout_service" {
  source                 = "../../modules/ecs-service"
  service_name           = "checkout"
  env_name               = var.env_name
  cluster_id             = module.ecs_cluster.cluster_id
  cluster_name           = module.ecs_cluster.cluster_name
  vpc_id                 = module.vpc.vpc_id
  vpc_cidr               = var.cidr_block
  private_subnet_ids     = module.vpc.private_subnet_ids
  alb_listener_arn       = module.alb.alb_listener_arn
  alb_sg_id              = module.alb.alb_sg_id
  cloud_map_namespace_id = module.logging.cloud_map_namespace_id

  container_image   = "koomi1/retail-app-checkout:latest"
  container_port    = 8080
  health_check_path = "/health"
  cpu               = var.checkout_cpu
  memory            = var.checkout_memory
  desired_count     = var.checkout_desired_count

  listener_path     = "/api/checkout*"
  listener_priority = 40

  elasticsearch_url         = module.logging.elasticsearch_url
  health_check_start_period = 10
  health_check_interval     = 20

  environment_vars = {
    RETAIL_CHECKOUT_PERSISTENCE_PROVIDER = "in-memory"
    RETAIL_CHECKOUT_ENDPOINTS_ORDERS     = "http://orders.${var.env_name}.local:8080"
  }

  aws_region = var.aws_region
  tags       = local.common_tags
  depends_on = [module.logging]
}

# ── 9. UI Service ─────────────────────────────────────────────────────────────
module "ui_service" {
  source                 = "../../modules/ecs-service"
  service_name           = "ui"
  env_name               = var.env_name
  cluster_id             = module.ecs_cluster.cluster_id
  cluster_name           = module.ecs_cluster.cluster_name
  vpc_id                 = module.vpc.vpc_id
  vpc_cidr               = var.cidr_block
  private_subnet_ids     = module.vpc.private_subnet_ids
  alb_listener_arn       = module.alb.alb_listener_arn
  alb_sg_id              = module.alb.alb_sg_id
  cloud_map_namespace_id = module.logging.cloud_map_namespace_id

  container_image   = "koomi1/retail-app-ui:latest"
  container_port    = 8080
  health_check_path = "/actuator/health"
  cpu               = var.ui_cpu
  memory            = var.ui_memory
  desired_count     = var.ui_desired_count

  listener_path     = "/*"
  listener_priority = 100

  elasticsearch_url         = module.logging.elasticsearch_url
  health_check_start_period = 60
  health_check_interval     = 30

  environment_vars = {
    RETAIL_UI_ENDPOINTS_CATALOG  = "http://catalog.${var.env_name}.local:8080"
    RETAIL_UI_ENDPOINTS_CARTS    = "http://cart.${var.env_name}.local:8080"
    RETAIL_UI_ENDPOINTS_CHECKOUT = "http://checkout.${var.env_name}.local:8080"
    RETAIL_UI_ENDPOINTS_ORDERS   = "http://orders.${var.env_name}.local:8080"
  }

  aws_region = var.aws_region
  tags       = local.common_tags
  depends_on = [module.logging]
}
