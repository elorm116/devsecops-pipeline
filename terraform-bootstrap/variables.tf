################################################################################
# variables.tf — Inputs for the bootstrap environment
################################################################################

variable "aws_region" {
  description = "AWS region for the state bucket"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "The name of the S3 bucket. Must be globally unique."
  type        = string
  default     = "mali-devsecops-pipeline-tfstate"
}
