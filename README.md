# DevSecOps Pipeline — AWS + Raspberry Pi Homelab

![Pipeline](https://img.shields.io/github/actions/workflow/status/elorm116/devsecops-pipeline/pipeline.yaml?label=pipeline&logo=githubactions&logoColor=white)
![Security Gates](https://img.shields.io/badge/security%20gates-5%20passing-brightgreen?logo=shield)
![IaC](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform)
![Cloud](https://img.shields.io/badge/cloud-AWS-FF9900?logo=amazonaws)
![Kubernetes](https://img.shields.io/badge/kubernetes-k3s-326CE5?logo=kubernetes)
![GitOps](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo)
![Multi-arch](https://img.shields.io/badge/image-amd64%20%7C%20arm64-blue?logo=docker)
![Kustomize](https://img.shields.io/badge/config-Kustomize-FF6C37)

A production-grade DevSecOps platform built and debugged from scratch across two live environments — AWS cloud and a self-hosted Kubernetes cluster running on a Raspberry Pi 5. Security is automated at every stage of the delivery lifecycle. Infrastructure is code. Deployments are Git commits. The cluster manages itself.

Everything in this repo was built, broken, and fixed in real conditions. The troubleshooting ledger at the bottom documents five production issues encountered and resolved during the build — not hypothetical, not from a tutorial.

---

## Live endpoints

| Environment | URL | Notes |
|---|---|---|
| AWS (Application Load Balancer) | `terraform output -raw alb_url` | Provisioned by Terraform (often destroyed to avoid cost) |
| Pi homelab (Cloudflare Tunnel) | `https://web.learndevops.site` | k3s on Raspberry Pi 5, zero open ports |
| Health check | `/health` | Used by Kubernetes liveness/readiness probes |
| Prometheus metrics | `/metrics` | Scraped by Prometheus |

---

## How the system works

### The full delivery loop

```
Developer pushes to GitHub
         │
         ▼
┌─────────────────────────────────────────────────────┐
│  GitHub Actions — DevSecOps Pipeline                │
│                                                     │
│  [SAST: Bandit] ──────────────────────────┐         │
│                                           ├─▶ PASS  │
│  [Secrets: Trivy] ────────────────────────┘         │
│            │ (parallel)                             │
│            ▼                                        │
│  [Docker build — linux/amd64 + linux/arm64]         │
│            │                                        │
│            ▼                                        │
│  [Container scan: Trivy] ─────────────────┐         │
│                                           ├─▶ PASS  │
│  [IaC scan: Checkov] ─────────────────────┘         │
│            │ (parallel)                             │
│            ▼                                        │
│  [Push image to ECR — tagged sha-<commit>]          │
│            │                                        │
│            ▼                                        │
│  [DAST: OWASP ZAP — scans local staging app]        │
│            │                                        │
│            ▼                                        │
│  [Commit new tag to Git]  ◀── GitOps                │
│            │                                        │
│            ▼                                        │
│   ArgoCD detects commit → rolling deploy to Pi      │
└─────────────────────────────────────────────────────┘
         │                          │
         ▼                          ▼
┌─────────────────┐    ┌─────────────────────────────┐
│  AWS (optional) │    │  Raspberry Pi 5              │
│  ALB → EC2 (TF) │    │  k3s cluster                 │
│  Docker         │    │  ├─ flask-app (replicas)     │
│                 │    │  ├─ ArgoCD                   │
│  ECR  S3  IAM   │    │  ├─ Prometheus + Grafana     │
│  CloudWatch     │    │  └─ Traefik ingress          │
└─────────────────┘    │  Cloudflare Tunnel           │
                       │  → web.learndevops.site      │
                       └─────────────────────────────┘
```

### GitOps loop — how the Pi stays in sync

```
git push (any change)
    │
    ▼
Pipeline builds sha-tagged image → pushes to ECR
    │
    ▼
Pipeline commits updated image tag to:
gitops/manifests/flask-app/overlays/pi/patch-image.yaml
    │
    ▼
ArgoCD detects the Git commit (polls continuously)
    │
    ▼
Kustomize renders base/ + overlays/pi/ patches
    │
    ▼
kubectl apply → zero-downtime rolling deploy
new pod Running → old pod Terminated
    │
    ▼
Cluster state matches Git state ✓
Every deploy is a Git commit. Every rollback is a git revert.
```

---

## Security gates

| Gate | Tool | Failure mode | What it catches |
|------|------|-------------|----------------|
| SAST | Bandit | Warn + artifact | Insecure Python — `eval()`, shell injection, hardcoded secrets, weak crypto |
| Secret scan | Trivy | **Hard fail** | Credentials/API keys/tokens committed to source — blocks pipeline entirely |
| Container scan | Trivy | Warn + artifact | CVEs in base image layers and installed packages |
| IaC scan | Checkov | Warn + artifact | Terraform misconfigs — open security groups, unencrypted S3, overpermissive IAM |
| DAST | OWASP ZAP | Warn + artifact | Runtime vulnerabilities — missing headers, exposed endpoints, XSS, injection points |

Secret scanning is the only hard-fail gate. A committed credential stops the pipeline immediately — nothing ships. All other gates produce downloadable scan reports saved as GitHub Actions artifacts.

All five gates run on every push to `main` and on every pull request.

---

## Architecture decisions

**GitOps with pipeline-driven tag commits** — ArgoCD Image Updater was evaluated but the simplest, most auditable pattern is having the pipeline commit the new image SHA directly to `patch-image.yaml` in Git. ArgoCD detects the commit and syncs. Every deploy is a traceable Git commit with author, timestamp, and SHA. Rollback is `git revert`. (An optional Image Updater experiment script exists at `scripts/setup-argocd-image-updater.sh`, but it is not used by the default delivery loop.)

**Kustomize over plain YAML or Helm** — Kustomize is built into `kubectl` and ArgoCD natively. The base/overlay pattern keeps a single canonical set of manifests and applies environment-specific patches on top. The pipeline only ever touches one file — `overlays/pi/patch-image.yaml`.

**App of Apps pattern** — one root ArgoCD Application manages all others from `gitops/apps/`. Applied once by hand. After that, ArgoCD manages itself and the entire cluster from Git.

**Multi-source Helm in ArgoCD** — Prometheus and Traefik are installed via Helm charts but with values files stored in this repo. ArgoCD's multi-source feature pulls the upstream chart and our values together.

**Multi-architecture Docker image** — GitHub Actions runners are `x86_64`. The Pi is ARM64. The pipeline builds a single multi-arch manifest using QEMU and Buildx. One ECR tag, two architecture layers.

**Hardened pod security context** — containers run as non-root (UID 1000), with `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, and all Linux capabilities dropped. A `Memory`-backed `emptyDir` volume is mounted at `/tmp` to give Gunicorn the writable scratch space it needs.

**Cloudflare Tunnel over port forwarding** — the Pi has zero open inbound ports. Cloudflare Tunnel creates an outbound-only encrypted connection to Cloudflare's edge network.

---

## Tech stack

**Application**
- Python 3.12, Flask 3.0, Gunicorn
- `prometheus-flask-exporter` — `/metrics` endpoint for Prometheus scraping
- `flask-limiter` — rate limiting

**Pipeline — GitHub Actions**
- Bandit (SAST), Trivy (secrets + container), Checkov (IaC), OWASP ZAP (DAST)
- `docker/setup-qemu-action` + `docker/setup-buildx-action` — multi-arch builds
- `docker/build-push-action` — `linux/amd64,linux/arm64` in one manifest
- GitOps write-back commit to `gitops/manifests/flask-app/overlays/pi/patch-image.yaml`

**AWS infrastructure — Terraform**
- VPC, subnet, internet gateway, route tables
- Application Load Balancer + target group + listener
- EC2 instance (configurable via Terraform `instance_type`), security groups
- ECR with scan-on-push + lifecycle policy
- IAM role + policy + instance profile (least privilege)
- S3 remote state with versioning

**Kubernetes — Raspberry Pi 5, Ubuntu aarch64**
- k3s — lightweight Kubernetes for ARM, single-node
- ArgoCD — GitOps continuous delivery, App of Apps pattern
- Kustomize — base/overlay manifest management
- Traefik — ingress controller
- kube-prometheus-stack — Prometheus + Grafana + Alertmanager
- Cloudflare Tunnel (`cloudflared`) — public HTTPS, zero open ports

---

## Repository structure

```
devsecops-pipeline/
├── app/
│   ├── main.py                        # Flask API
│   └── requirements.txt               # Pinned dependencies
│
├── Dockerfile                         # Multi-stage, non-root, multi-arch
│
├── terraform/
│   ├── aws/
│   │   ├── main.tf                    # AWS resources
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── backend.tf                 # S3 remote state
│   │   ├── userdata.sh                # EC2 bootstrap
│   │   └── terraform-bootstrap/        # (Optional) state-bucket bootstrap module
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       └── outputs.tf
│   │
│   └── gke/
│       ├── main.tf                    # GKE Autopilot (optional)
│       ├── variables.tf
│       ├── outputs.tf
│       ├── backend.tf                 # GCS remote state
│       └── gke-setup.sh               # Helper script for GCP bootstrap
│
├── gitops/
│   ├── apps/                          # ArgoCD Application definitions
│   │   ├── app-of-apps.yaml           # Root app — manages all others
│   │   ├── flask-app.yaml             # Points at overlays/pi/
│   │   ├── monitoring.yaml            # kube-prometheus-stack via Helm
│   │   └── ingress.yaml               # Traefik via Helm
│   │
│   ├── apps-gke/                       # ArgoCD Applications for GKE (kept separate)
│   │   └── flask-app.yaml
│   │
│   └── manifests/
│       ├── flask-app/
│       │   ├── base/
│       │   └── overlays/
│       │       ├── pi/
│       │       │   ├── patch-image.yaml   # ← pipeline updates this
│       │       │   └── patch-replicas.yaml
│       │       └── gke/
│       │           ├── patch-image.yaml   # ← pipeline updates this
│       │           ├── patch-replicas.yaml
│       │           └── patch-pullsecret.yaml
│       ├── monitoring/
│       │   └── values.yaml
│       └── ingress/
│           └── values.yaml
│
├── scripts/
│   └── setup-argocd-image-updater.sh   # Optional/legacy alternative deploy mechanism
│
├── .zap/
│   └── rules.tsv                       # OWASP ZAP baseline scan rules
│
└── .github/
    └── workflows/
        └── pipeline.yaml               # Full CI/CD + security gates
```

---

## Running locally

```bash
git clone https://github.com/elorm116/devsecops-pipeline.git
cd devsecops-pipeline

pip install -r app/requirements.txt
python app/main.py
```

Or with Docker:

```bash
docker build -t devsecops-api .
docker run -p 5000:5000 devsecops-api
```

| Endpoint | Description |
|----------|-------------|
| `GET /` | Service info and environment |
| `GET /health` | Health check |
| `GET /info` | System info |
| `GET /data` | Sample data |
| `GET /metrics` | Prometheus scrape endpoint |

---

## Deploying to AWS

AWS is intentionally treated as optional: it’s common to `terraform destroy` after validation to avoid ongoing costs.

```bash
# 1. Create S3 bucket for Terraform state
#    Must match terraform/aws/backend.tf (default: mali-devsecops-pipeline-tfstate)
aws s3api create-bucket \
  --bucket mali-devsecops-pipeline-tfstate \
  --region us-east-1
aws s3api put-bucket-versioning \
  --bucket mali-devsecops-pipeline-tfstate \
  --versioning-configuration Status=Enabled

# 2. Create EC2 key pair
aws ec2 create-key-pair \
  --key-name devsecops-key \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/devsecops-key.pem && chmod 400 ~/.ssh/devsecops-key.pem

# 3. Provision everything
cd terraform
terraform init
terraform apply \
  -var="key_pair_name=devsecops-key" \
  -var="allowed_ssh_cidr=$(curl -s ifconfig.me)/32"
```

If you're using the refactored layout, run Terraform from `terraform/aws/` instead:

```bash
cd terraform/aws
terraform init
terraform apply \
  -var="key_pair_name=devsecops-key" \
  -var="allowed_ssh_cidr=$(curl -s ifconfig.me)/32"
```

GitHub Actions secrets required:

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret |
| `GITOPS_PAT` | GitHub PAT with repo write scope (pipeline commits GitOps tag updates) |

---

## Deploying the GitOps cluster (Pi)

```bash
# 1. Install k3s
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --node-ip $(ip -4 addr show wlan0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}') \
  --flannel-iface wlan0 \
  --disable traefik \
  --disable servicelb

# 2. Install ArgoCD (the only manual install)
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Create ECR pull secret
kubectl create namespace devsecops-app
kubectl create secret docker-registry ecr-secret \
  --namespace devsecops-app \
  --docker-server=393818036545.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$(aws ecr get-login-password --region us-east-1)

# 4. Apply the root application — this is the only manual kubectl apply
#    If you fork this repo, update repoURL in gitops/apps/*.yaml first.
kubectl apply -f gitops/apps/app-of-apps.yaml

# 5. Watch ArgoCD bootstrap the entire cluster from Git
kubectl -n argocd get applications -w
```

---

## Troubleshooting ledger

Five real issues encountered and resolved during the build.

### 1. Exec format error — architecture mismatch

**Symptom:** Pods on the Pi stuck in `CrashLoopBackOff` immediately after deployment.

```
exec /usr/local/bin/gunicorn: exec format error
```

**Root cause:** GitHub Actions runners are `x86_64`. The Docker image was built for Intel and cannot execute on the Pi's ARM64 processor.

**Fix:** Multi-architecture build in the pipeline:

```yaml
- uses: docker/setup-qemu-action@v4
- uses: docker/setup-buildx-action@v4
- uses: docker/build-push-action@v7
  with:
    platforms: linux/amd64,linux/arm64
    push: true
    tags: ${{ env.ECR }}:sha-${{ github.sha }}
```

---

### 2. ECR image desync — Pi not updating after a new push

**Symptom:** New image pushed to ECR. Pi kept running the old container.

**Root cause:** Kubernetes does not re-pull an image if the tag hasn't changed.

**Fix:** SHA-tagged images and a GitOps commit strategy. The pipeline tags every image with `sha-<github.sha>` and commits the new tag to `overlays/pi/patch-image.yaml`. ArgoCD detects the Git change and redeploys.

---

### 3. kubectl context collision — MacBook targeting wrong cluster

**Symptom:** `kubectl` commands from the MacBook applied to the local context instead of the Pi cluster.

**Fix:** Dedicated kubeconfig file for the Pi using its Tailscale IP:

```bash
export KUBECONFIG=~/.kube/pi-config
alias kpi="KUBECONFIG=~/.kube/pi-config kubectl"
alias klocal="KUBECONFIG=~/.kube/config kubectl"
```

---

### 4. Service port mismatch — port-forward failing

**Symptom:** `kubectl port-forward` failed with `Service does not have a service port 5000`.

**Root cause:** The Kubernetes Service maps front-end port `80` to `targetPort 5000`.

**Fix:**

```bash
kubectl port-forward svc/devsecops-api 5001:80 -n devsecops-app
```

---

### 5. readOnlyRootFilesystem blocking Gunicorn worker temp files

**Symptom:** Pods crash with:

```
FileNotFoundError: [Errno 2] No usable temporary directory found in
['/tmp', '/var/tmp', '/usr/tmp', '/app']
```

**Root cause:** `readOnlyRootFilesystem: true` locks `/tmp`, but Gunicorn needs a writable temp directory.

**Fix:** Mount a `Memory`-backed `emptyDir` at `/tmp`.

---

### 6. ECR Token Expiry & Secret Name Mismatch

**Symptom:** Pods stuck in `ImagePullBackOff` despite the image existing in ECR and a secret being present.

**Root cause:** ECR login tokens expire every 12 hours. Additionally, the Deployment manifest was hardcoded to look for `ecr-secret`, while the manual refresh script created `ecr-registry-secret`.

**Fix:** Standardized secret naming to `ecr-secret` and implemented a 12-hour refresh cycle. (Next step: Automated CronJob refresher).

### 7. ArgoCD Controller CRD Desync

**Symptom:** The `argocd-applicationset-controller` stuck in a `CrashLoopBackOff`, preventing GitOps synchronization.

**Root cause:** The controller was attempting to watch `ApplicationSet` resources, but the corresponding CRDs were missing or corrupted in the k3s API server.

**Fix:** Re-applied the official ArgoCD CRD manifests and performed a hard refresh of the Application objects.

## Known gaps and next steps

| Item | Status | Plan |
|------|--------|------|
| Flask-Limiter in-memory storage | Open | Deploy Redis to sync rate-limit state across pod replicas |
| ECR pull secret expiry | Open | Kubernetes CronJob to refresh the token on a schedule |
| Grafana persistence | Open | Persistent volume claim so dashboards survive pod restarts |
| Single-node k3s | By design | HA requires a second Pi |

---

## Author

Anthony — DevOps & Cloud Engineer

[GitHub](https://github.com/elorm116) · [LinkedIn](https://linkedin.com/inaezottor/) · [Live demo](https://web.learndevops.site)

