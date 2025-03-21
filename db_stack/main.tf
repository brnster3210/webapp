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
      # Authentication method (e.g., service account key)
      # credentials = file("path/to/your/service_account_key.json")
    }


#*********************************************
#                  SQL Creation              *
#*********************************************

