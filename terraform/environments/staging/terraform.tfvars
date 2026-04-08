env_name   = "staging"
aws_region = "us-east-1"
cidr_block = "10.1.0.0/16"
az_count   = 2

ui_cpu    = 512
ui_memory = 1024

catalog_cpu    = 256
catalog_memory = 512

ui_desired_count      = 1
catalog_desired_count = 1

es_cpu       = 1024
es_memory    = 2048
es_java_opts = "-Xms512m -Xmx512m"

kibana_cpu    = 512
kibana_memory = 1536
