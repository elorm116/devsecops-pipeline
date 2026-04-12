################################################################################
# terraform/gke/variables.tf
################################################################################

variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "project-31856ac9-76a2-472d-96c"
}

variable "region" {
  description = "GCP region — me-west1 is closest to Qatar"
  type        = string
  default     = "me-west1"
}

variable "cluster_name" {
  description = "Name used to prefix all GKE resources"
  type        = string
  default     = "devsecops-pipeline"
}
