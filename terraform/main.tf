################################################################################
# main.tf — Core AWS resources
# Provisions: VPC, subnet, EC2, ECR, security group, IAM role
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

  default_tags {
    tags = local.common_tags
  }
}

locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
    Owner       = var.team_name
    Cluster     = var.cluster_name
  }

  ecr_secure_repository_name = "${var.project_name}-secure"
}

# merge() combines common_tags with resource-specific tags.
# Every resource gets Environment, ManagedBy, Project, Owner, Cluster
# PLUS its own Name tag without repeating the common ones.

################################################################################
# VPC & Networking
################################################################################

resource "aws_vpc" "main" {
  # checkov:skip=CKV2_AWS_11:Flow logs disabled for cost control in development
  # checkov:skip=CKV2_AWS_12:Default SG is unused; custom SGs are used for all resources
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-igw"
  })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-subnet"
  })
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-public-subnet-b"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-rt"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "app" {
  name        = "${var.project_name}-sg"
  description = "Allow HTTP and app traffic"
  vpc_id      = aws_vpc.main.id

  # SSM Session Manager is used for admin access instead of SSH.
  # Reason: no inbound port 22 needed, no key pair distribution, and better auditability.

  # App port
  ingress {
    description     = "HTTP traffic from ALB"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Prometheus (internal scrape)
  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    # checkov:skip=CKV_AWS_382:Allowing outbound for package updates and API integrations
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-sg"
  })
}

resource "aws_security_group" "alb" {
  # checkov:skip=CKV_AWS_260:ALB is intended to be public, so ingress from 0.0.0.0/0 on port 80 is required
  # checkov:skip=CKV_AWS_382:ALB needs to route to dynamic backend instances, so open egress is standard
  name        = "${var.project_name}-alb-sg"
  description = "Allow inbound HTTP to the load balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alb-sg"
  })
}

################################################################################
# IAM — Least-privilege role for EC2
################################################################################

resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ec2-role"
  })
}

# Enable AWS Systems Manager Session Manager on the instances (preferred over SSH)
resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ec2_policy" {
  # checkov:skip=CKV_AWS_355:Using '*' for CloudWatch and ECR since resources are dynamically created and maintaining ARNs in this lab introduces breaking complexity
  name = "${var.project_name}-ec2-policy"
  role = aws_iam_role.ec2_role.id

  # Least privilege: only what the app needs
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Pull images from ECR
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        # Write metrics to CloudWatch
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      },
      {
        # Write logs to CloudWatch
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

################################################################################
# KMS — Customer-managed key for ECR
################################################################################

################################################################################
# ECR — Container registry
################################################################################

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "ecr" {
  description             = "${var.project_name} ECR encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowECRUseOfKey"
        Effect = "Allow"
        Principal = {
          Service = "ecr.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          Bool = {
            "kms:GrantIsForAWSResource" = "true"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-ecr-kms"
  })
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${var.project_name}-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

resource "aws_ecr_repository" "app_kms" {
  #checkov:skip=CKV_AWS_51:Tag immutability conflicts with re-pushing convenience tags (e.g., :latest). Prefer SHA tags in deployments.
  name                 = local.ecr_secure_repository_name
  image_tag_mutability = "MUTABLE"

  # Scan on push — free AWS vulnerability scanning
  image_scanning_configuration {
    scan_on_push = true
  }

  # Encrypt images at rest
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = merge(local.common_tags, {
    Name = local.ecr_secure_repository_name
  })
}

# Lifecycle policy — keep only the last 10 images (free tier storage limit)
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app_kms.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

################################################################################
# EC2
################################################################################

# Latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

################################################################################
# Zero-downtime serving layer — ALB + ASG (2 instances)
################################################################################

resource "aws_lb" "app" {
  #checkov:skip=CKV_AWS_150:Deletion protection disabled to support routine teardown for cost control.
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public_b.id]

  # Fixes CKV_AWS_131: Protects against HTTP Desync attacks by dropping invalid headers
  drop_invalid_header_fields = true

  # Fixes CKV_AWS_150: Skips deletion protection for cost/teardown convenience
  # checkov:skip=CKV_AWS_150:Deletion protection disabled to support routine teardown for cost control.

  # Fixes CKV2_AWS_28: Skips WAF requirement (Standard for labs/dev to save costs)
  # checkov:skip=CKV2_AWS_28:WAF not required for this environment level. In real production, consider adding AWS WAF for enhanced security.
  # checkov:skip=CKV2_AWS_20:Skipping HTTP to HTTPS redirection because this lab does not have a domain/SSL certificate

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    prefix  = "${var.project_name}/alb"
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alb"
  })
}

resource "aws_lb_target_group" "app" {
  # checkov:skip=CKV_AWS_378:Using HTTP protocol because HTTPS is not configured internally for this lab

  name        = "${var.project_name}-tg"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-tg"
  })
}

resource "aws_lb_listener" "http" {
  # checkov:skip=CKV_AWS_2:Using HTTP because this lab does not provision SSL certificates or a domain name
  # checkov:skip=CKV_AWS_103:HTTPS not configured so strict TLS/SSL settings do not apply

  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_launch_template" "app" { # checkov:skip=CKV_AWS_88:Instances run in a public subnet for this lab configuration (no NAT Gateway configured)
  name_prefix = "${var.project_name}-lt-"

  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  ebs_optimized = true

  network_interfaces {
    device_index = 0
    # checkov:skip=CKV_AWS_88:Instances run in a public subnet for this lab configuration (no NAT Gateway configured)
    associate_public_ip_address = true
    security_groups             = [aws_security_group.app.id]
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    aws_region         = var.aws_region
    ecr_repository_url = aws_ecr_repository.app_kms.repository_url
    project_name       = var.project_name
    image_tag          = var.image_tag
  }))

  monitoring {
    enabled = true
  }

  metadata_options {
    http_tokens = "required"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.project_name}-server" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${var.project_name}-volume" })
  }
}

################################################################################
# ALB access logs — S3 bucket
################################################################################

resource "aws_s3_bucket" "alb_logs" {
  # checkov:skip=CKV_AWS_18:This is the logging bucket itself; nesting logs causes recursion issues
  # checkov:skip=CKV_AWS_21:Versioning omitted for cost-savings in a lab environment
  # checkov:skip=CKV_AWS_144:Cross-region replication omitted for cost avoidance/simplicity
  # checkov:skip=CKV2_AWS_62:S3 event notifications not required for this logging architecture
  # checkov:skip=CKV_AWS_145:KMS encryption omitted for ALBs to avoid potential complications with default AWS log delivery IAM roles

  bucket_prefix = "${var.project_name}-alb-logs-"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alb-logs"
  })
}

# New Resource: Fixes CKV2_AWS_61
resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire_old_logs"
    status = "Enabled"

    expiration {
      days = 90
    }

    # checkov:skip=CKV_AWS_300:Failed multipart uploads check omitted to prevent breaking lifecycle changes
    # In production, abort_incomplete_multipart_upload would be ideal
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_elb_service_account" "this" {}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSALBLogs"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_elb_service_account.this.arn
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/${var.project_name}/alb/*"
      },
      {
        Sid    = "AWSALBLogBucketAcl"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_elb_service_account.this.arn
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.alb_logs.arn
      }
    ]
  })
}

resource "aws_autoscaling_group" "app" {
  # Using name_prefix (instead of name) allows lifecycle.create_before_destroy
  # to work without an ASG name collision during replacement.
  name_prefix         = "${var.project_name}-asg-"
  min_size            = 2
  max_size            = 2
  desired_capacity    = 2
  vpc_zone_identifier = [aws_subnet.public.id, aws_subnet.public_b.id]

  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "${var.project_name}-server" })
    iterator = common_tag
    content {
      key                 = common_tag.key
      value               = common_tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
