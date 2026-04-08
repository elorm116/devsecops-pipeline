################################################################################
# main.tf — Bootstrap resources for Terraform State
#
# Best practices for real teams:
# - S3 Bucket for state
# - Versioning enabled
# - Encryption enabled
# - Public access completely blocked
# - Native S3 state locking (use_lockfile)
################################################################################

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.37"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# 1. Provide an S3 Bucket for remote state
resource "aws_s3_bucket" "terraform_state" {
  bucket = var.state_bucket_name

  # Prevent accidental deletion of this S3 bucket
  # Can be set to false if you want to allow terraform destroy to clean up everything, but be careful! Do this is dev only.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "Terraform State Bucket"
    Project = "devsecops-pipeline"
  }
}

# 2. Enable versioning (every state change is recoverable)
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 3. Enable server-side encryption by default
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 4. Explicitly block all public access to the bucket
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
