################################################################################
# backend.tf — S3 remote state
#
# IMPORTANT: Create the S3 bucket BEFORE running terraform init.
# You can use the `terraform-bootstrap` project to provision this:
#   cd ../terraform-bootstrap
#   terraform init
#   terraform apply
#
################################################################################

terraform {
  backend "s3" {
    bucket       = "mali-devsecops-pipeline-tfstate"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
