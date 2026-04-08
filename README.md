# DevSecOps Pipeline on AWS

![Pipeline](https://img.shields.io/github/actions/workflow/status/elorm116/devsecops-pipeline/pipeline.yaml?label=pipeline&logo=githubactions&logoColor=white)
![Security](https://img.shields.io/badge/security%20gates-5%20passing-brightgreen?logo=shield)
![IaC](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform)
![Cloud](https://img.shields.io/badge/cloud-AWS-FF9900?logo=amazonaws)
![Docker](https://img.shields.io/badge/container-Docker-2496ED?logo=docker)

A production-grade DevSecOps pipeline that bakes security into every stage of the software delivery lifecycle — from first commit to live deployment on AWS. Built to demonstrate real-world security engineering, not just CI/CD basics.

---

## What this is

Most pipelines test code and deploy it. This one treats **security as a first-class citizen** — five automated security gates run on every push, infrastructure is provisioned as code, and the running application is monitored in real time.

```
Code commit → SAST → Secret scan → Docker build → Container scan → IaC scan → Deploy → DAST → Monitor
```

Every gate produces a downloadable artifact (scan report). If any gate fails, the pipeline stops. Nothing ships unless it's clean.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Actions                            │
│                                                             │
│  ┌──────────┐  ┌──────────┐                                 │
│  │  SAST    │  │ Secrets  │  ← runs in parallel             │
│  │ (Bandit) │  │ (Trivy)  │                                 │
│  └────┬─────┘  └────┬─────┘                                 │
│       └──────┬───────┘                                      │
│              ▼                                              │
│       ┌─────────────┐                                       │
│       │ Docker build│                                       │
│       └──────┬──────┘                                       │
│              ▼                                              │
│  ┌──────────────┐  ┌───────────┐                            │
│  │  Container   │  │ IaC scan  │  ← runs in parallel        │
│  │ scan (Trivy) │  │ (Checkov) │                            │
│  └──────┬───────┘  └─────┬─────┘                           │
│         └────────┬────────┘                                 │
│                  ▼                                          │
│          ┌──────────────┐                                   │
│          │  DAST        │                                   │
│          │ (OWASP ZAP)  │                                   │
│          └──────┬───────┘                                   │
└─────────────────┼───────────────────────────────────────────┘
                  ▼
┌─────────────────────────────────────────────────────────────┐
│                        AWS                                  │
│                                                             │
│   VPC → (2) Public Subnets → ALB → ASG (2x EC2) → Container │
│                           ↑                                  │
│                    ECR (image registry)                     │
│                    S3  (Terraform state)                    │
│                    IAM (least-privilege roles)              │
│                    SSM (Session Manager — no SSH)           │
└─────────────────────────────────────────────────────────────┘
                  ▼
┌─────────────────────────────────────────────────────────────┐
│                    Monitoring                               │
│         Prometheus scrape → Grafana dashboards              │
│                  AWS CloudWatch alerts                      │
└─────────────────────────────────────────────────────────────┘
```

---

## Security gates

| Gate | Tool | What it catches |
|------|------|----------------|
| SAST | Bandit | Insecure Python patterns — hardcoded secrets, unsafe `eval()`, weak crypto |
| Secret scan | Trivy (secret mode) | API keys, tokens, credentials accidentally committed |
| Container scan | Trivy (vuln mode) | CVEs in base image and installed packages |
| IaC scan | Checkov | Misconfigured Terraform — open security groups, unencrypted S3, missing IAM boundaries |
| DAST | OWASP ZAP | Runtime vulnerabilities — XSS, missing security headers, injection points, exposed endpoints |

Each scan uploads its report as a GitHub Actions artifact. Download them from the Actions tab.

---

## Tech stack

**Application**
- Python 3.12 + Flask
- Gunicorn (production WSGI server)
- Prometheus metrics (`/metrics` endpoint)
- Rate limiting via `flask-limiter`

**Pipeline**
- GitHub Actions
- Bandit (SAST)
- Trivy (secrets + container scanning)
- Checkov (IaC scanning)
- OWASP ZAP (DAST)

**Infrastructure**
- Terraform (IaC)
- AWS ALB + Auto Scaling Group (rolling updates, reduced downtime)
- AWS EC2 (instance type configurable)
- AWS ECR (container registry)
- AWS S3 (Terraform remote state)
- AWS VPC + Security Groups + IAM
- AWS SSM Session Manager (admin access without SSH)

**Monitoring**
- Prometheus
- Grafana
- AWS CloudWatch

---

## Project structure

```
devsecops-pipeline/
├── app/
│   ├── main.py              # Flask API (health, info, data, metrics endpoints)
│   └── requirements.txt     # Pinned dependencies
├── terraform-bootstrap/
│   ├── main.tf              # Creates S3 bucket used by Terraform remote state
│   ├── variables.tf         # Bootstrap inputs (bucket name/region)
│   └── outputs.tf
├── terraform/
│   ├── main.tf              # Core AWS resources
│   ├── variables.tf         # Input variables
│   ├── outputs.tf           # Output values (EC2 IP, ECR URL)
│   └── backend.tf           # S3 remote state config
├── monitoring/
│   ├── prometheus.yml       # Scrape config
│   └── grafana/
│       └── dashboard.json   # Pre-built dashboard
├── .github/
│   └── workflows/
│       └── pipeline.yaml     # Full CI/CD + security pipeline
├── Dockerfile               # Multi-stage, non-root, hardened
└── docs/
    └── security.md          # Security gate rationale
```

---

## Running locally

**Prerequisites**: Python 3.12+, Docker

```bash
git clone https://github.com/elorm116/devsecops-pipeline.git
cd devsecops-pipeline

# Run the app directly
pip install -r app/requirements.txt
python app/main.py

# Or run in Docker
docker build -t devsecops-api .
docker run -p 5000:5000 devsecops-api
```

Endpoints:

| Endpoint | Description |
|----------|-------------|
| `GET /` | Service info |
| `GET /health` | Health check (used by load balancers) |
| `GET /info` | System info |
| `GET /data` | Sample data (rate-limited to 30 req/min) |
| `GET /metrics` | Prometheus scrape endpoint |

---

## Deploying to AWS

**Prerequisites**: AWS CLI configured, Terraform installed

```bash
cd terraform-bootstrap

# 1) Create the remote state backend (S3)
terraform init
terraform apply

cd ../terraform

# 2) Initialise Terraform with the S3 backend
terraform init

# Preview what will be created
terraform plan

# Deploy
terraform apply
```

This provisions: VPC, two public subnets, ALB + Auto Scaling Group, ECR repo, IAM role with least-privilege policy, and security groups.

After `apply`, Terraform outputs an `alb_url` — use that as the primary entrypoint.

Admin access is via **SSM Session Manager** (no inbound SSH/port 22 and no key pairs).

On each push to `main`, the GitHub Actions pipeline builds the Docker image and pushes it to ECR with tags `latest` and the git SHA.

---

## Destroying AWS resources

Destroy the main infrastructure first, then (optionally) the bootstrap backend.

```bash
cd terraform
terraform destroy

cd ../terraform-bootstrap
terraform destroy
```

Note: the bootstrap S3 bucket is protected by `prevent_destroy = true` by default. To destroy it, you must remove or disable that lifecycle rule first.

---

## Key design decisions

**Multi-stage Dockerfile** — separates build-time dependencies from the runtime image. Smaller attack surface, smaller image size.

**Non-root container user** — the app runs as `appuser`, not root. Even if a vulnerability is exploited, the attacker doesn't get root access inside the container.

**Parallel security gates** — SAST and secret scanning run in parallel; container and IaC scanning run in parallel. Full security coverage without doubling pipeline time.

**DAST after deployment** — OWASP ZAP runs against the live container, not the source code. It catches runtime vulnerabilities that static analysis misses — missing security headers, exposed endpoints, injection points.

**Least-privilege IAM** — the EC2 instance role has only the permissions it needs: ECR pull, S3 read for state, CloudWatch write for metrics. No `AdministratorAccess`.

**Pinned dependencies** — `requirements.txt` uses exact versions. Trivy's CVE database can flag known vulnerabilities in specific versions — pinning makes this meaningful rather than advisory.

---

## Author

Anthony | DevOps & Cloud Engineer  
[GitHub](https://github.com/elorm116) · [LinkedIn](https://linkedin.com/in/aezottor)