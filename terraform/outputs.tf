################################################################################
# outputs.tf — Values printed after terraform apply
################################################################################

output "ec2_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.app.public_ip
}

output "ec2_public_dns" {
  description = "Public DNS of the EC2 instance"
  value       = aws_instance.app.public_dns
}

output "ecr_repository_url" {
  description = "ECR URL — used in the GitHub Actions pipeline"
  value       = aws_ecr_repository.app.repository_url
}

output "app_url" {
  description = "Direct URL to the running application"
  value       = "http://${aws_instance.app.public_ip}:5000"
}

output "health_check_url" {
  description = "Health check endpoint"
  value       = "http://${aws_instance.app.public_ip}:5000/health"
}

output "metrics_url" {
  description = "Prometheus scrape endpoint"
  value       = "http://${aws_instance.app.public_ip}:5000/metrics"
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer (zero-downtime entrypoint)"
  value       = aws_lb.app.dns_name
}

output "alb_url" {
  description = "HTTP URL of the Application Load Balancer"
  value       = "http://${aws_lb.app.dns_name}"
}
