env_name   = "prod"
aws_region = "us-east-1"
cidr_block = "10.2.0.0/16"
az_count   = 2

ui_cpu    = 1024
ui_memory = 2048

catalog_cpu    = 512
catalog_memory = 1024

# 2 replicas for availability — ALB auto-routes around failed tasks
ui_desired_count      = 2
catalog_desired_count = 2

es_cpu       = 2048
es_memory    = 4096
es_java_opts = "-Xms2g -Xmx2g"

kibana_cpu    = 1024
kibana_memory = 2048
