################################################################################
# outputs.tf — Useful output values
################################################################################

output "s3_bucket_arn" {
  description = "The ARN of the S3 bucket"
  value       = aws_s3_bucket.terraform_state.arn
}