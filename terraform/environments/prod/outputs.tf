output "alb_dns_name" {
  description = "ALB DNS — open this in your browser or use for curl tests"
  value       = module.alb.alb_dns_name
}

output "kibana_url" {
  description = "Kibana UI"
  value       = "http://${module.alb.alb_dns_name}/kibana"
}

output "elasticsearch_url" {
  description = "Elasticsearch REST API (internal, reachable from private subnets)"
  value       = module.logging.elasticsearch_url
}
