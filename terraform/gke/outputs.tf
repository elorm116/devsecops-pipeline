################################################################################
# terraform/gke/outputs.tf
################################################################################

output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "GKE cluster API endpoint"
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "region" {
  description = "GCP region"
  value       = var.region
}

output "artifact_registry_url" {
  description = "Artifact Registry URL — use this as your GCP image registry"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${var.cluster_name}"
}

output "get_credentials_command" {
  description = "Run this after apply to configure kubectl for GKE"
  value       = "gcloud container clusters get-credentials ${var.cluster_name} --region ${var.region} --project ${var.project_id}"
}
