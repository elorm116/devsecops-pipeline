################################################################################
# variables.tf — All configurable inputs
################################################################################

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Used to prefix all resource names"
  type        = string
  default     = "devsecops-pipeline"
}

variable "environment" {
  description = "Environment name for tagging and naming (e.g., dev, prod)"
  type        = string
  default     = "dev"
}

variable "team_name" {
  description = "The name of the team that owns these resources"
  type        = string
  default     = "devsecops-team"
}

variable "cluster_name" {
  description = "The name of the cluster or project grouping"
  type        = string
  default     = "auth-cluster"
}

variable "image_tag" {
  description = "ECR image tag to deploy on the instance (e.g., latest, a git SHA, a semver tag)"
  type        = string
  default     = "latest"
}

variable "instance_type" {
  description = "EC2 instance type — t3.small is free tier eligible"
  type        = string
  default     = "t3.small"
}
