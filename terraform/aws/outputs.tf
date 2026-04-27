################################################################################
# outputs.tf — Values printed after terraform apply
################################################################################

output "ecr_repository_url" {
  description = "ECR URL — used in the GitHub Actions pipeline"
  value       = aws_ecr_repository.app_kms.repository_url
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer (zero-downtime entrypoint)"
  value       = aws_lb.app.dns_name
}

output "alb_url" {
  description = "HTTP URL of the Application Load Balancer"
  value       = "http://${aws_lb.app.dns_name}"
}

output "health_check_url" {
  description = "Health check endpoint via ALB"
  value       = "http://${aws_lb.app.dns_name}/health"
}

output "github_actions_role_arn" {
  description = "ARN to set as AWS_ROLE_ARN in GitHub secrets"
  value       = aws_iam_role.github_actions_ecr.arn
}