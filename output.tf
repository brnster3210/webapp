#*********************************************
#                Output Results              *
#*********************************************

# Output the VPC and subnet details
output "vpc_name" {
  value = google_compute_network.main_vpc_network.name
}

output "subnet_name" {
  value = google_compute_subnetwork.public_subnet.name
}

# Output the load balancer IP
output "load_balancer_ip" {
  value = google_compute_global_forwarding_rule.webapp_lb.ip_address
}

# Output the private IP of the Cloud SQL instance
output "database_private_ip" {
  value = google_sql_database_instance.webapp_db.private_ip_address
}

# output "webapp_map_url" {
#   value = google_compute_url_map.webapp_url_map
# }

# output "webapp_proxy" {
#   value = google_compute_target_http_proxy.webapp_proxy
# }