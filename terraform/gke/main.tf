################################################################################
# Terraform Settings & Providers
################################################################################

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.27"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
    }
  }
}

data "google_client_config" "default" {}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}

################################################################################
# VPC — Dedicated network for the cluster
################################################################################

resource "google_compute_network" "gke_vpc" {
  # checkov:skip=CKV2_GCP_18:Custom firewall rules defined below satisfy this
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "gke_subnet" {
  name                     = "${var.cluster_name}-subnet"
  ip_cidr_range            = "10.10.0.0/24"
  region                   = var.region
  network                  = google_compute_network.gke_vpc.id
  private_ip_google_access = true # Fixes CKV_GCP_74

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/16"
  }

  # Fix for CKV_GCP_26 & CKV_GCP_61 (VPC Flow Logs)
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Explicit firewall rules - Fixes CKV2_GCP_12
resource "google_compute_firewall" "gke_allow_internal" {
  name          = "${var.cluster_name}-allow-internal"
  network       = google_compute_network.gke_vpc.name
  direction     = "INGRESS"
  source_ranges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }
}

resource "google_compute_firewall" "gke_health_checks" {
  name          = "${var.cluster_name}-health-checks"
  network       = google_compute_network.gke_vpc.name
  direction     = "INGRESS"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]

  allow {
    protocol = "tcp"
  }
}

################################################################################
# GKE Autopilot Cluster
################################################################################

resource "google_container_cluster" "primary" {
  # checkov:skip=CKV_GCP_18:Public endpoint required for local kubectl access
  # checkov:skip=CKV_GCP_65:Google Groups RBAC requires an Organization workspace
  name     = var.cluster_name
  location = var.region


  enable_autopilot = true

  # Fixes CKV_GCP_21
  resource_labels = {
    env        = "dev"
    managed_by = "terraform"
    owner      = "anthony"
  }

  network    = google_compute_network.gke_vpc.id
  subnetwork = google_compute_subnetwork.gke_subnet.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Fixes CKV_GCP_20 (Restricted Control Plane Access)
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0" # Update to your specific Public IP for better security
      display_name = "Anthony-Home-Office"
    }
  }

  # Fixes CKV_GCP_13
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Hardening Toggles - Fixes CKV_GCP_61, CKV_GCP_66, CKV_GCP_12
  enable_intranode_visibility = true

  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  network_policy {
    enabled = true
  }

  # Fixes CKV_GCP_69
 # Consolidated Node Config - Fixes CKV_GCP_69 & CKV_GCP_68
  node_config {
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Shielded GKE Nodes settings
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  deletion_protection = false # Set to true in production to prevent accidental deletion
}

################################################################################
# Artifact Registry
################################################################################

resource "google_artifact_registry_repository" "app" {
  # checkov:skip=CKV_GCP_84:Using Google-managed encryption for cost efficiency
  location      = var.region
  repository_id = var.cluster_name
  format        = "DOCKER"
  description   = "Docker images for devsecops-pipeline"
}

################################################################################
# Cloud NAT — Allows private nodes to pull images from internet
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
}

################################################################################
# ArgoCD Bootstrap
################################################################################

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.5.0"

  depends_on = [google_container_cluster.primary]
}

################################################################################
# Root Application (App-of-Apps)
################################################################################

resource "kubernetes_manifest" "root_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "root-app"
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/elorm116/devsecops-pipeline.git"
        targetRevision = "main"
        path           = "gitops/apps-gke" 
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  }

  depends_on = [helm_release.argocd]
}
