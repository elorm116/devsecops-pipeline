#!/bin/bash
################################################################################
# userdata.sh — EC2 bootstrap script
# Runs once on first boot. Installs Docker, pulls image from ECR, starts app.
################################################################################

set -euo pipefail
exec > >(tee /var/log/userdata.log | logger -t userdata) 2>&1

echo "=== Starting bootstrap ==="

# Update system
dnf update -y

# Install Docker
dnf install -y docker
systemctl enable docker
systemctl start docker

# Add ec2-user to docker group (so it can run docker without sudo)
usermod -aG docker ec2-user

# Install AWS CLI v2 (already present on AL2023, but ensure it's current)
dnf install -y aws-cli

# Ensure SSM agent is installed and running (preferred over SSH)
dnf install -y amazon-ssm-agent || true
systemctl enable amazon-ssm-agent || true
systemctl start amazon-ssm-agent || true

# Authenticate Docker to ECR
echo "=== Authenticating to ECR ==="
ECR_REGISTRY="$(echo "${ecr_repository_url}" | cut -d/ -f1)"
aws ecr get-login-password --region "${aws_region}" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

# Pull latest image
echo "=== Pulling latest image ==="
docker pull "${ecr_repository_url}:${image_tag}"

# Stop any existing container
docker stop ${project_name} 2>/dev/null || true
docker rm   ${project_name} 2>/dev/null || true

# Run the container
echo "=== Starting container ==="
docker run -d \
  --name ${project_name} \
  --restart unless-stopped \
  -p 5000:5000 \
  -e APP_ENV=production \
  "${ecr_repository_url}:${image_tag}"

echo "=== Bootstrap complete ==="

# IMDSv2-compatible (http_tokens=required)
METADATA_BASE="http://169.254.169.254/latest"
IMDS_TOKEN="$(curl -sS -X PUT "$METADATA_BASE/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
PUBLIC_IP=""
if [[ -n "$IMDS_TOKEN" ]]; then
  PUBLIC_IP="$(curl -sS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" "$METADATA_BASE/meta-data/public-ipv4" || true)"
fi

if [[ -n "$PUBLIC_IP" ]]; then
  echo "App running at http://$PUBLIC_IP:5000"
fi