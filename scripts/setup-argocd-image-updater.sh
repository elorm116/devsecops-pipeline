#!/bin/bash
################################################################################
# ArgoCD Image Updater Setup
# Watches ECR for new image tags → commits updated tag back to Git →
# ArgoCD detects the commit → deploys to Pi automatically
################################################################################

# Ensure script stops on first error
set -e

# ── Step 1: Install Image Updater ────────────────────────────────────────────
echo "Installing ArgoCD Image Updater..."
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/config/install.yaml

echo "Waiting for Image Updater to be ready..."
kubectl -n argocd rollout status deployment argocd-image-updater --timeout=120s

# ── Step 2: Give Image Updater access to ECR ─────────────────────────────────
# It needs to poll ECR for new tags — we create a dedicated secret
echo "Setting up ECR credentials..."

# Load secrets from a local .env file
if [ -f "scripts/.env" ]; then
  source scripts/.env
else
  echo "Error: scripts/.env file not found! Please create one with your secrets."
  exit 1
fi

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$GITHUB_PAT" ]; then
  echo "Error: Missing required credentials in scripts/.env"
  exit 1
fi

kubectl -n argocd create secret generic ecr-credentials \
  --from-literal=aws_access_key_id=$AWS_ACCESS_KEY_ID \
  --from-literal=aws_secret_access_key=$AWS_SECRET_ACCESS_KEY \
  --from-literal=aws_region=us-east-1 \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Patching Image Updater config to use ECR..."
kubectl -n argocd patch configmap argocd-image-updater-config \
  --type merge \
  --patch '{
    "data": {
      "registries.conf": "registries:\n  - name: ECR\n    api_url: https://393818036545.dkr.ecr.us-east-1.amazonaws.com\n    prefix: 393818036545.dkr.ecr.us-east-1.amazonaws.com\n    credentials: secret:argocd/ecr-credentials#aws_access_key_id\n    credsexpire: 10h\n    default: true\n    insecure: false\n"
    }
  }'

echo "Restarting Image Updater to pick up new config..."
kubectl -n argocd rollout restart deployment argocd-image-updater-controller --timeout=300s

# ── Step 3: Give ArgoCD write access to your GitHub repo ─────────────────────
# Image Updater commits the new image tag back to Git
echo "Setting up GitHub credentials..."

# GitHub PAT is loaded from the .env file above
kubectl -n argocd create secret generic github-credentials \
  --from-literal=username=elorm116 \
  --from-literal=password=$GITHUB_PAT \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Step 4: Verify it runs ───────────────────────────────────────────────────
echo "Setup complete! Verifying..."
kubectl -n argocd get pods | grep image-updater
echo "You can view logs with: kubectl -n argocd logs deployment/argocd-image-updater-controller --tail=20"
