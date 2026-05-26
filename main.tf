# ==========================================
# 0. Variables
# ==========================================
variable "project_id" {
  type        = string
  description = "The GCP Project ID"
}

# ==========================================
# 0.5 Local Variables (Workspace Config)
# ==========================================
locals {
  # Define configuration maps for each environment
  env_config = {
    dev  = { min_instances = 0, max_instances = 2 }
    prod = { min_instances = 1, max_instances = 5 }
  }
  # Dynamically select the config based on the active workspace. Fails if workspace is not dev or prod.
  env = local.env_config[terraform.workspace]

  # Resource naming convention
  app_name     = "sample-web-app"
  repo_id      = "sample-app-repo-${terraform.workspace}"
  service_name = "${local.app_name}-service-${terraform.workspace}"
  region       = "asia-south1"
}

# ==========================================
# 1. Terraform Backend & Provider
# ==========================================
terraform {
  backend "gcs" {
    # Replace with your exact bucket name (e.g., gcp-devops-pipeline-496410-tf-state)
    bucket = "gcp-devops-pipeline-496410-tf-state"
    prefix = "terraform/state"
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  # We use the variable here so it doesn't have to be hardcoded multiple times
  project = var.project_id
  region  = local.region
}

# ==========================================
# 2. Artifact Registry (Docker Image Storage)
# ==========================================
resource "google_artifact_registry_repository" "app_repo" {
  location      = local.region
  repository_id = local.repo_id
  description   = "Docker repository for the Node.js web application"
  format        = "DOCKER"
}

# ==========================================
# 3. Cloud Run Service (Web Hosting)
# ==========================================
resource "google_cloud_run_v2_service" "app_service" {
  name     = local.service_name
  location = local.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    # Apply the dynamic scaling variables from our locals block
    scaling {
      min_instance_count = local.env.min_instances
      max_instance_count = local.env.max_instances
    }

    containers {
      # The ${var.project_id} injects your project ID directly into the image URL
      image = "${local.region}-docker.pkg.dev/${var.project_id}/${local.repo_id}/${local.app_name}:latest"
      ports {
        container_port = 3000
      }
      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
      startup_probe {
        http_get {
          path = "/items"
          port = 3000
        }
        initial_delay_seconds = 5
        timeout_seconds       = 3
        period_seconds        = 10
        failure_threshold     = 3
      }
    }
  }

  # Ensure the registry exists BEFORE trying to deploy the service
  depends_on = [google_artifact_registry_repository.app_repo]
}

# ==========================================
# 4. Public Access (IAM Binding)
# ==========================================
# This makes the URL accessible to anyone on the internet
resource "google_cloud_run_v2_service_iam_binding" "public_access" {
  location = google_cloud_run_v2_service.app_service.location
  name     = google_cloud_run_v2_service.app_service.name
  role     = "roles/run.invoker"
  members  = ["allUsers"]
}

# ==========================================
# 5. Outputs
# ==========================================
# Prints the final website URL to the terminal
output "service_url" {
  value = google_cloud_run_v2_service.app_service.uri
}