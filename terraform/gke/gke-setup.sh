#!/bin/bash
# ===============================================
# GCP WIF Setup - Final Bulletproof Version
# ===============================================

set -e

# ================== CONFIG ==================
PROJECT_ID="project-31856ac9-76a2-472d-96c"
REGION="me-west1"
BUCKET_NAME="devsecops-pipeline-gke-tfstate"
SA_NAME="github-actions-sa"
POOL_NAME="github-pool-v2"
PROVIDER_NAME="github-provider"

# Get repo name dynamically
REPO_FULL=$(git config --get remote.origin.url | sed 's/.*github.com\///' | sed 's/\.git$//')
# Fetch Project Number (Crucial for WIF bindings)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')

echo "🚀 Starting WIF Setup for repo: $REPO_FULL (Project #: $PROJECT_NUMBER)"

# 1. Enable APIs
gcloud services enable container.googleapis.com artifactregistry.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com --project=$PROJECT_ID

# 2. GCS Bucket
gcloud storage buckets create gs://$BUCKET_NAME --location=$REGION --project=$PROJECT_ID 2>/dev/null || true

# 3. Service Account & Roles
gcloud iam service-accounts create $SA_NAME --project=$PROJECT_ID 2>/dev/null || true

for role in roles/container.admin roles/artifactregistry.writer roles/storage.objectAdmin; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="$role" --quiet > /dev/null
done

# 4. Workload Identity Pool + Provider
echo "🌐 Configuring Workload Identity..."
gcloud iam workload-identity-pools create $POOL_NAME \
  --project=$PROJECT_ID --location=global || true

# Force Create/Update Provider
gcloud iam workload-identity-pools providers create-oidc $PROVIDER_NAME \
  --project=$PROJECT_ID --location=global --workload-identity-pool=$POOL_NAME \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository == '${REPO_FULL}'" 2>/dev/null || \
gcloud iam workload-identity-pools providers update-oidc $PROVIDER_NAME \
  --project=$PROJECT_ID --location=global --workload-identity-pool=$POOL_NAME \
  --attribute-condition="assertion.repository == '${REPO_FULL}'"

echo "⏳ Waiting for GCP propagation..."
sleep 7

# 5. Bind SA to GitHub repo (Using PROJECT_NUMBER)
echo "🔗 Binding Service Account to repository..."
gcloud iam service-accounts add-iam-policy-binding \
  "${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --project=$PROJECT_ID \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/attribute.repository/${REPO_FULL}"

# 6. Artifact Registry
gcloud artifacts repositories create devsecops-pipeline-secure \
  --repository-format=docker --location=$REGION --project=$PROJECT_ID 2>/dev/null || true

echo -e "\n🎉 WIF Setup Completed! Use these in GitHub Secrets:"
echo "GCP_PROJECT_NUMBER: $PROJECT_NUMBER"
echo "GCP_WORKLOAD_IDENTITY_POOL: $POOL_NAME"