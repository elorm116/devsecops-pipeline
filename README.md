# DevSecOps Pipeline — AWS + Raspberry Pi Homelab

![Pipeline](https://img.shields.io/github/actions/workflow/status/elorm116/devsecops-pipeline/pipeline.yaml?label=pipeline&logo=githubactions&logoColor=white)
![Security Gates](https://img.shields.io/badge/security%20gates-5%20passing-brightgreen?logo=shield)
![IaC](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform)
![Cloud](https://img.shields.io/badge/cloud-AWS-FF9900?logo=amazonaws)
![k8s](https://img.shields.io/badge/kubernetes-k3s-326CE5?logo=kubernetes)
![GitOps](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo)
![Multi-arch](https://img.shields.io/badge/image-amd64%20%7C%20arm64-blue?logo=docker)

A production-grade DevSecOps platform built across two environments: a cloud deployment on AWS and a self-hosted Kubernetes homelab running on a Raspberry Pi 5. Security is automated at every stage — five gates run on every commit, infrastructure is provisioned as code, and the running application is continuously monitored and GitOps-managed.

---

## What makes this different

Most pipeline projects test code and deploy it. This one treats security as a first-class citizen throughout the entire delivery lifecycle, runs a real Kubernetes cluster on physical hardware, and implements GitOps so the cluster self-heals from GitHub.

The troubleshooting section at the bottom documents four real production issues encountered and resolved during the build — architecture mismatches, image desync, kubeconfig context collisions, and service port mapping. These aren't hypothetical; they happened.

---

## Live endpoints

| Environment | URL |
|---|---|
| AWS (via ALB) | `http://devsecops-pipeline-alb-2018761014.us-east-1.elb.amazonaws.com` |
| Pi homelab (via Cloudflare Tunnel) | `https://api.nalorwu.com` |
| Health check | `/health` |
| Prometheus metrics | `/metrics` |

Note: The AWS endpoint is available only while the Terraform stack is applied (it’s common to `terraform destroy` after validation to avoid ongoing costs).

---

## Architecture

### Full system

```
┌─────────────────────────────────────────────────────────────────┐
│  Developer pushes to GitHub                                     │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│  GitHub Actions — DevSecOps Pipeline                            │
│                                                                 │
│  [SAST: Bandit] ──┐                                             │
│                   ├──▶ [Docker build] ──▶ [Container: Trivy] ──┐│
│  [Secrets: Trivy]─┘         │              [IaC: Checkov]    ──┤│
│                             │ push (amd64 + arm64)             ││
│                             ▼                                  ││
│                    [ECR — multi-arch manifest]                  ││
│                             │                                  ││
│                             ▼                                  ││
│                    [DAST: OWASP ZAP (local)]                    │
└─────────────────────────────────────────────────────────────────┘
          │                                    │
          ▼                                    ▼
┌──────────────────┐               ┌────────────────────────────┐
│  AWS             │               │  Raspberry Pi 5 Homelab    │
│                  │               │                            │
│  ALB             │               │  k3s (Kubernetes)          │
│   └▶ EC2 (TF)    │               │   ├─ devsecops-api (x2)    │
│       └▶ Docker  │               │   ├─ ArgoCD (GitOps)       │
│                  │               │   ├─ Prometheus + Grafana  │
│  ECR (registry)  │               │   └─ Traefik ingress       │
│  S3  (tf state)  │               │                            │
│  IAM (roles)     │               │  Cloudflare Tunnel         │
│  CloudWatch      │               │   └▶ api.nalorwu.com       │
└──────────────────┘               └────────────────────────────┘
```

### GitOps loop (Raspberry Pi)

```
Developer pushes k8s/ manifest change to GitHub
       │
       │  ArgoCD polls continuously
       ▼
ArgoCD detects drift between repo and cluster state
       │
       ▼
Automatic kubectl apply
       │
       ▼
Cluster converges to match repo ✓
```

---

## Security gates

| Gate | Tool | Mode | What it catches |
|------|------|------|----------------|
| SAST | Bandit | Warn | Insecure Python — unsafe `eval()`, hardcoded secrets, weak crypto, shell injection |
| Secret scan | Trivy | **Hard fail** | API keys, tokens, credentials committed to source — blocks the pipeline entirely |
| Container scan | Trivy | Warn | CVEs in base image and installed packages |
| IaC scan | Checkov | Warn | Terraform misconfigs — open security groups, unencrypted S3, overpermissive IAM |
| DAST | OWASP ZAP | Warn | Runtime vulnerabilities — missing headers, exposed endpoints, XSS, injection points |

Secret scanning is the only hard-fail gate. All other gates produce downloadable reports without blocking deploys — a pragmatic choice for a solo project where findings are reviewed rather than auto-blocked.

Every scan report is uploaded as a GitHub Actions artifact and downloadable from the Actions tab.

---

## Tech stack

**Application**
- Python 3.12, Flask, Gunicorn
- `prometheus-flask-exporter` — native `/metrics` endpoint
- `flask-limiter` — rate limiting (in-memory; Redis planned for multi-replica sync)

**Pipeline**
- GitHub Actions
- Bandit, Trivy, Checkov, OWASP ZAP
- `docker/buildx` + QEMU — multi-architecture builds (`linux/amd64` + `linux/arm64`)

**AWS infrastructure** (Terraform — 22 resources)
- EC2 `t2.micro` behind an Application Load Balancer
- ECR with scan-on-push and 10-image lifecycle policy
- VPC, public subnet, internet gateway, route tables, security groups
- IAM role with least-privilege policy (ECR pull + CloudWatch write only)
- S3 remote state with versioning enabled
- CloudWatch CPU alarm

**Kubernetes homelab** (Raspberry Pi 5 — Ubuntu 25.10 aarch64)
- k3s — lightweight Kubernetes for ARM
- ArgoCD — GitOps continuous delivery, watches `k8s/` directory
- Traefik — ingress controller on NodePort 30080
- Prometheus + Grafana via `kube-prometheus-stack`
- Cloudflare Tunnel — public HTTPS, zero open inbound ports

---

## Repository structure

```
devsecops-pipeline/
├── app/
│   ├── main.py                  # Flask API
│   └── requirements.txt         # Pinned dependencies
├── k8s/
│   ├── namespace.yaml           # devsecops-app namespace
│   ├── deployment.yaml          # 2-replica Deployment + Service
│   ├── ingress.yaml             # Traefik ingress (api.nalorwu.com)
│   └── servicemonitor.yaml      # Prometheus ServiceMonitor
├── terraform/
│   ├── main.tf                  # VPC, EC2, ECR, ALB, IAM, CloudWatch
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf               # S3 remote state
│   └── userdata.sh              # EC2 bootstrap
├── .github/
│   └── workflows/
│       └── pipeline.yaml        # Full CI + security pipeline
├── .zap/
│   └── rules.tsv                # OWASP ZAP rule configuration
└── Dockerfile                   # Multi-stage, non-root, multi-arch
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
| `GET /` | Service info |
| `GET /health` | Health check |
| `GET /info` | System info |
| `GET /data` | Sample data (rate-limited: 30 req/min) |
| `GET /metrics` | Prometheus scrape endpoint |

---

## Deploying to AWS

```bash
# 1. Create S3 bucket for Terraform state
aws s3api create-bucket \
  --bucket devsecops-pipeline-tfstate \
  --region us-east-1
aws s3api put-bucket-versioning \
  --bucket devsecops-pipeline-tfstate \
  --versioning-configuration Status=Enabled

# 2. Create EC2 key pair
aws ec2 create-key-pair \
  --key-name devsecops-key \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/devsecops-key.pem
chmod 400 ~/.ssh/devsecops-key.pem

# 3. Deploy
cd terraform
terraform init
terraform apply \
  -var="key_pair_name=devsecops-key" \
  -var="allowed_ssh_cidr=$(curl -s ifconfig.me)/32"
```

Terraform outputs the EC2 IP, ALB DNS, ECR URL, and health check URL. On every push to `main`, the pipeline builds the image, runs security gates, and publishes multi-arch images to ECR.

How the AWS deploy works:
- GitHub Actions publishes the container image to ECR.
- Terraform provisions the ALB + EC2 stack.
- On instance boot, [terraform/userdata.sh](terraform/userdata.sh) authenticates to ECR and runs the container.

Cost control:
```bash
cd terraform
terraform destroy
```

GitHub Actions secrets required (for ECR push):

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |

---

## Deploying to the Pi homelab

```bash
# Create ECR pull secret
ECR_TOKEN=$(aws ecr get-login-password --region us-east-1)
kubectl create secret docker-registry ecr-secret \
  --namespace devsecops-app \
  --docker-server=393818036545.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$ECR_TOKEN

# Apply manifests (ArgoCD manages these going forward)
kubectl apply -f k8s/
```

To manage the cluster remotely from a MacBook using Tailscale:

```bash
# Point kubectl at the Pi
export KUBECONFIG=~/.kube/pi-config
# Pi Tailscale IP: 100.78.23.120

# Convenience alias
alias kpi="KUBECONFIG=~/.kube/pi-config kubectl"
```

Test the app through Traefik directly:

```bash
curl -i -H "Host: api.nalorwu.com" http://<PI_IP>:30080/health
```

---

## Key design decisions

**Multi-architecture image** — the pipeline builds for both `linux/amd64` and `linux/arm64` in a single manifest using QEMU and Buildx. EC2 pulls `amd64`; the Pi pulls `arm64`. One tag, two platforms, zero manual steps.

**Non-root container** — the app runs as `appuser` (UID 1000). Exploiting a vulnerability doesn't grant root inside the container.

**GitOps with ArgoCD** — Kubernetes manifests live in Git. ArgoCD continuously reconciles cluster state against the repo. The cluster self-heals; manual `kubectl apply` is only used for bootstrapping.

**Cloudflare Tunnel** — the Pi has no open inbound ports. The tunnel creates an outbound-only encrypted connection to Cloudflare's edge. No home IP exposed, no firewall rules required.

**ALB over direct EC2 exposure** — the Application Load Balancer provides a stable DNS name, health-based routing, and decouples the public endpoint from the underlying instance.

**Least-privilege IAM** — the EC2 role can pull from ECR and write to CloudWatch. Nothing else.

**Parallel security gates** — SAST and secret scanning run in parallel; container and IaC scanning run in parallel after the build. Full coverage without doubling pipeline time.

---

## Troubleshooting ledger

Real issues hit during the build and how they were resolved.

### 1. Exec format error — architecture mismatch

**Symptom:** Pods on the Pi stuck in `CrashLoopBackOff`. Logs showed:
```
exec /usr/local/bin/gunicorn: exec format error
```

**Root cause:** GitHub Actions runners are `x86_64`. The image was built for Intel and couldn't execute on the Pi's ARM64 processor.

**Fix:** Added multi-architecture build to the pipeline:
```yaml
- uses: docker/setup-qemu-action@v4
- uses: docker/setup-buildx-action@v4
- uses: docker/build-push-action@v7
  with:
    platforms: linux/amd64,linux/arm64
    push: true
    tags: ${{ steps.ecr-login.outputs.registry }}/devsecops-pipeline-secure:latest
```

**Result:** A single ECR image tag now carries both architecture layers. Each environment pulls the layer it needs automatically.

---

### 2. ECR image desync — pods not updating after push

**Symptom:** New image pushed to ECR. The Pi kept running the old container.

**Root cause:** Kubernetes doesn't re-pull an image if the tag (`:latest`) hasn't changed, even if the underlying layers have.

**Immediate fix:**
```bash
kubectl rollout restart deployment devsecops-api -n devsecops-app
```

**Permanent fix:** The pipeline now tags images with both `:latest` and `:<git-sha>`. The deployment manifest references the SHA-tagged image, so every push produces a unique tag that forces a pull.

---

### 3. kubectl context collision — MacBook targeting wrong cluster

**Symptom:** `kubectl` commands from the MacBook were hitting the local context instead of the Pi cluster.

**Fix:** Dedicated kubeconfig using the Pi's Tailscale IP:
```bash
export KUBECONFIG=~/.kube/pi-config
```

Added to `~/.zshrc` with an alias so both contexts can coexist:
```bash
alias kpi="KUBECONFIG=~/.kube/pi-config kubectl"
alias klocal="KUBECONFIG=~/.kube/config kubectl"
```

---

### 4. Service port mismatch — port-forward failing

**Symptom:** `kubectl port-forward` failed with `Service does not have a service port 5000`.

**Root cause:** The Service maps front-end port `80` to `targetPort 5000`. Port-forwarding requires the Service's front-end port, not the container port.

**Fix:**
```bash
kubectl port-forward svc/devsecops-api 5001:80 -n devsecops-app
```

---

## Known gaps and next steps

| Item | Status | Plan |
|------|--------|------|
| Flask-Limiter in-memory storage | Open | Deploy Redis to sync rate-limit state across pod replicas |
| ECR pull secret expiry | Open | Kubernetes CronJob to refresh the token automatically |
| Single-node k3s | By design | HA requires a second Pi — out of scope for now |
| Terraform state locking | Open | Add DynamoDB table if the project grows to a team |

---

## Author

Anthony | DevOps & Cloud Engineer
[GitHub](https://github.com/elorm116) · [LinkedIn](https://linkedin.com/in/)

