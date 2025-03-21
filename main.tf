    terraform {
      required_providers {
        google = {
          source  = "hashicorp/google"
          version = "~> 4.0"
        }
      }
    }

    # Configure Google Cloud Provider
    provider "google" {
      project = "devops-227900"
      region  = "us-west1"

    }

#*********************************************
#         VPC, NAT, LB, etc Creation         *
#*********************************************

# Create a VPC network for WebApp Stack
resource "google_compute_network" "main_vpc_network" {
  name                    = "main-vpc-network"
  auto_create_subnetworks = false  
  description             = "This is a main VPC network"
}

# Create a public subnet for WebApp Servers
resource "google_compute_subnetwork" "public_subnet" {
  name          = "public-subnet"
  region        = "us-west1"
  network       =  google_compute_network.main_vpc_network.self_link
  ip_cidr_range = "10.10.1.0/24"  
}

# Create a private subnet for MySQL DB
resource "google_compute_subnetwork" "private_subnet" {
  name                     = "private-subnet"
  region                   = "us-west1"
  network                  = google_compute_network.main_vpc_network.self_link
  ip_cidr_range            = "10.10.2.0/24" 
  private_ip_google_access = true  # Allows private Google access for instances in this subnet
}

# Create a Cloud Router for NAT gateway
resource "google_compute_router" "cloud_router" {
  name    = "my-cloud-router"  # Name of the Cloud Router
  region  = google_compute_subnetwork.public_subnet.region
  network = google_compute_network.main_vpc_network.self_link
}

# Create a NAT gateway for outbound internet access
resource "google_compute_router_nat" "nat_gateway" {
  name                               = "my-nat-gateway"  # Name of the NAT gateway
  router                             = google_compute_router.cloud_router.name
  region                             = google_compute_router.cloud_router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Create a custom route for Internet access
resource "google_compute_route" "internet_route" {
  name             = "internet-route"  # Name of the route
  dest_range       = "0.0.0.0/0"       # Destination CIDR (default route)
  network          = google_compute_network.main_vpc_network.id
  next_hop_gateway = "default-internet-gateway"  # Use the default internet gateway
  priority         = 100  # Route priority
}

# Create firewall rule allow SSH to WebApp instances
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"  # Name of the firewall rule
  network = google_compute_network.main_vpc_network.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]  # Allow SSH from anywhere
  target_tags   = ["webapp"]      # Apply this rule to instances with the tag webapp
}

# Create a firewall rule to allow HTTP traffic for WebApp
resource "google_compute_firewall" "allow_http" {
  name    = "allow-http"  # Name of the firewall rule
  network = google_compute_network.main_vpc_network.id

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]  # Allow traffic from anywhere
  target_tags   = ["webapp"]      # Apply this rule to instances with the tag webapp
}

# Create a firewall rule to allow internal traffic for MySQL DB
resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"  # Name of the firewall rule
  network = google_compute_network.main_vpc_network.id

  allow {
    protocol = "tcp"
    ports    = ["3306"]  # MySQL port
  }

  source_ranges = ["10.10.1.0/24"]  # Allow traffic from the public subnet
}

# Enable the Service Networking API
resource "google_project_service" "service_networking" {
  service = "servicenetworking.googleapis.com"
}

# Reserve an IP range for the private connection for SQL DB
resource "google_compute_global_address" "private_ip_range" {
  name          = "private-ip-range"  # Name of the IP range
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main_vpc_network.id
}

# Create a private service VPC connection
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main_vpc_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]

  depends_on = [google_project_service.service_networking]
}

#*********************************************
#                  SQL Creation              *
#*********************************************

# Create a Cloud SQL (MySQL) instance
resource "google_sql_database_instance" "webapp_db" {
  name             = "webapp-db-instance-01"  # Name of the database instance
  database_version = "MYSQL_8_0"              # MySQL version
  region           = "us-west1"               # Region for the database
  deletion_protection = false                 # Set to false to destroy the instance and DB, default setting True

  settings {
    tier = "db-f1-micro"  # Image type for the database

    ip_configuration {
      ipv4_enabled = false  # Disable public IP for the database
      private_network = google_compute_network.main_vpc_network.id
    }
  }
  depends_on = [ google_service_networking_connection.private_vpc_connection ]
}

# Create a database and user for the web application
resource "google_sql_database" "webapp_db" {
  name     = "webapp_db"  # Name of the database
  instance = google_sql_database_instance.webapp_db.name
}

resource "google_sql_user" "webapp_db_user" {
  name     = "webapp_user"  # Database username
  instance = google_sql_database_instance.webapp_db.name
  password = "ratsarefatthiseyear"
}

#*******************************************************
#        Autoscaling WebApp Instances Creation         *
#*******************************************************

# Create a template for the managed instance group (MIG)
resource "google_compute_instance_template" "webapp_template" {
  name         = "webapp-template-v1"  # Name of the instance template
  machine_type = "e2-medium"        # Machine type for the instances

  disk {
    source_image = "debian-cloud/debian-11"  # Base image for the instances
    auto_delete  = true
    boot         = true
  }

    network_interface {
    subnetwork = google_compute_subnetwork.public_subnet.id
    access_config {}
    }

    metadata_startup_script = <<-EOF
        #!/bin/bash
        apt-get update
        apt-get install -y apache2
        apt-get install -y default-mysql-client

        # Create a simple HTML page
        cat << 'EOL' > /var/www/html/index.html
        <html>            
        <body>
            <h1>Hello, Monitor Database Connection!</h1>
            <p>Database Connection Status: <span id="db-status">Checking...redirect to status page! If not add /cgi-bin/db-status to URL</span></p>
            <script>
                // Fetch database connection status from the server
                fetch('/usr/lib/cgi-bin/db-status)
                    .then(response => response.text())
                    .then(data => {
                        document.getElementById('db-status').textContent = data;
                    })
                    .catch(error => {
                        document.getElementById('db-status').textContent = 'Error: ' + error;
                    });
            </script>
            <script>
                // Redirect to the CGI script after 5 seconds
                setTimeout(function() {
                    window.location.href = "http://${google_sql_database_instance.webapp_db.private_ip_address}/cgi-bin/db-status";
                }, 5000);  // 5000 milliseconds = 5 seconds
            </script>
        </body>
        </html>
        EOL

        # Create a CGI script to check database connection status
        mkdir -p /usr/lib/cgi-bin
        cat << 'EOL' > /usr/lib/cgi-bin/db-status
        #!/bin/bash
        echo "Content-type: text/plain"
        echo ""

        # MySQL connection details
        MYSQL_HOST="${google_sql_database_instance.webapp_db.private_ip_address}"
        MYSQL_USER="webapp_user"
        MYSQL_PASSWORD="ratsarefatthiseyear"
        DATABASE_NAME="webapp_db"

        # Check MySQL connection
        if mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
            echo "Connected successfully!"
        else
            echo "Connection failed!"
        fi
        EOL

        # Make the CGI script executable
        chmod +x /usr/lib/cgi-bin/db-status
        
        # Enable CGI module in Apache
        a2enmod cgi

        # Restart Apache to apply changes
        systemctl restart apache2            
    EOF
        
    tags = ["webapp"]  # Tag instances for firewall rules
}

resource "time_sleep" "wait_for_health_check" {
  create_duration = "60s"  # Wait for 60 seconds

  depends_on = [ google_compute_health_check.autohealing]
}

# Health check for scale up if necessary 
resource "google_compute_health_check" "autohealing" {
  name                = "autohealing-health-check"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 10 # 50 seconds

  http_health_check {
    request_path = "/"
    port         = "80"
  }
}

# Create a managed instance group for WebApp
resource "google_compute_instance_group_manager" "webapp_mig" {
  name               = "webapp-mig"  # Name of the group instances
  base_instance_name = "webapp-instance"
  zone               = "us-west1-a"  # Zone for the group instances

  version {
    instance_template = google_compute_instance_template.webapp_template.id
  }

  target_size = 2  # Initial number of instances start with

  auto_healing_policies {
    health_check      = google_compute_health_check.autohealing.id
    initial_delay_sec = 300  # Delay before auto-healing starts
  }

  depends_on = [ time_sleep.wait_for_health_check ]

}

# Create an autoscaler for the group instances
resource "google_compute_autoscaler" "webapp_autoscaler" {
  name   = "webapp-autoscaler"  # Name of the autoscaler
  zone   = "us-west1-a"
  target = google_compute_instance_group_manager.webapp_mig.id

  autoscaling_policy {
    max_replicas    = 5  # Maximum number of instances
    min_replicas    = 2  # Minimum number of instances
    cooldown_period = 60  # Cooldown period in seconds

    cpu_utilization {
      target = 0.75  # Target CPU utilization 
    }
  }
}

# Forward traffic to the load balancer for HTTP load balancing
resource "google_compute_global_forwarding_rule" "webapp_lb" {
  name       = "webapp-lb"  # Name of the load balancer
  target     = google_compute_target_http_proxy.webapp_proxy.id
  port_range = "80"
}

# Create a target HTTP proxy to forward incomning HTTP reqeust to URL map
resource "google_compute_target_http_proxy" "webapp_proxy" {
  name    = "webapp-proxy"  # Name of the HTTP proxy
  url_map = google_compute_url_map.webapp_url_map.id
}

# Create a URL map route requests to the backend of the incoming URL
resource "google_compute_url_map" "webapp_url_map" {
  name            = "webapp-url-map"  # Name of the URL map
  default_service = google_compute_backend_service.webapp_backend.id
}

# Group of VMs that will server traffic for load balancing backend service 
resource "google_compute_backend_service" "webapp_backend" {
  name        = "webapp-backend"  # Name of the backend service
  port_name   = "http"
  protocol    = "HTTP"
  timeout_sec = 10

  backend {
    group = google_compute_instance_group_manager.webapp_mig.instance_group
  }

  health_checks = [google_compute_health_check.autohealing.id]

}

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
