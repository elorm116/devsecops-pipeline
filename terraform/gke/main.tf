################################################################################
# terraform/gke/main.tf
# GKE Autopilot cluster — me-west1 (Tel Aviv)
# Autopilot: Google manages nodes, you pay per pod not per node
################################################################################

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.27"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

################################################################################
# VPC — dedicated network for the cluster
################################################################################

resource "google_compute_network" "gke_vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "gke_subnet" {
  name          = "${var.cluster_name}-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.gke_vpc.id

  # Secondary ranges required by GKE for pods and services
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/16"
  }
}

################################################################################
# GKE Autopilot cluster
################################################################################

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region

  # Autopilot — Google manages node pools, scaling, patching
  enable_autopilot = true

  network    = google_compute_network.gke_vpc.id
  subnetwork = google_compute_subnetwork.gke_subnet.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Keep the cluster private — nodes have no public IPs
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false   # keep public endpoint for kubectl access
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Release channel — REGULAR gets stable updates ~every few months
  release_channel {
    channel = "REGULAR"
  }

  # Workload identity — lets k8s service accounts act as GCP service accounts
  # Best practice for accessing GCP services from pods without static keys
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  deletion_protection = false   # allow terraform destroy for learning
}

################################################################################
# Artifact Registry — GCP's ECR equivalent
# We'll push a copy of the image here so GKE doesn't need ECR cross-cloud auth
################################################################################

resource "google_artifact_registry_repository" "app" {
  location      = var.region
  repository_id = var.cluster_name
  format        = "DOCKER"
  description   = "Docker images for devsecops-pipeline"
}

################################################################################
# Cloud NAT — Allows private nodes to access the internet (to pull images)
################################################################################

resource "google_compute_router" "router" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.gke_vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}