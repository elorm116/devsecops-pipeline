################################################################################
# terraform/gke/backend.tf
# GCS bucket for Terraform state — GCP equivalent of S3
#
# Create the bucket BEFORE terraform init:
#
#   gcloud storage buckets create gs://devsecops-pipeline-gke-tfstate \
#     --location=me-west1 \
#     --project=project-31856ac9-76a2-472d-96c
#
#   gcloud storage buckets update gs://devsecops-pipeline-gke-tfstate \
#     --versioning
#
################################################################################

terraform {
  backend "gcs" {
    bucket = "devsecops-pipeline-gke-tfstate"
    prefix = "prod/terraform.tfstate"
  }
}
