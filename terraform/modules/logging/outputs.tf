# App services use this URL in their FireLens / Fluent Bit config
output "elasticsearch_url" {
  value = "http://elasticsearch.${var.env_name}.local:9200"
}

output "elasticsearch_sg_id" {
  value = aws_security_group.elasticsearch.id
}

output "kibana_url" {
  value = "http://<alb-dns>/kibana"
}
