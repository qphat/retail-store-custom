env_name   = "dev"
aws_region = "us-east-1"
cidr_block = "10.0.0.0/16"
az_count   = 2

# Java service — Spring Boot JVM needs headroom
ui_cpu    = 512
ui_memory = 1024

# Go service — static binary, minimal overhead
catalog_cpu    = 256
catalog_memory = 512

# Single task each in dev
ui_desired_count      = 1
catalog_desired_count = 1

# Elasticsearch — needs at least 1GB even in dev
es_cpu       = 1024
es_memory    = 2048
es_java_opts = "-Xms512m -Xmx512m"

# Kibana
kibana_cpu    = 512
kibana_memory = 1024
