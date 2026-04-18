# DevSecOps Pipeline — AWS + Raspberry Pi Homelab

![Pipeline](https://img.shields.io/github/actions/workflow/status/elorm116/devsecops-pipeline/juice-shop-pipeline.yaml?label=pipeline&logo=githubactions&logoColor=white)
![Security Gates](https://img.shields.io/badge/security%20gates-6%20passing-brightgreen?logo=shield)
![IaC](https://img.shields.io/badge/IaC-Terraform-7B42BC?logo=terraform)
![Cloud](https://img.shields.io/badge/cloud-AWS-FF9900?logo=amazonaws)
![Kubernetes](https://img.shields.io/badge/kubernetes-k3s-326CE5?logo=kubernetes)
![GitOps](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo)
![Multi-arch](https://img.shields.io/badge/image-amd64%20%7C%20arm64-blue?logo=docker)
![Kustomize](https://img.shields.io/badge/config-Kustomize-FF6C37)

A production-grade DevSecOps platform built and debugged from scratch across cloud and edge environments. It implements a comprehensive CI/CD pipeline for a multi-architecture (`linux/amd64` + `linux/arm64`) Flask API and OWASP Juice Shop, with security controls enforced across the full software delivery lifecycle. Infrastructure is code. Deployments are Git commits. The cluster manages itself.

Everything in this repo was built, broken, and fixed in real conditions. The troubleshooting ledger at the bottom documents fourteen production issues encountered and resolved during the build — not hypothetical, not from a tutorial.

---

## Live endpoints

| Environment | URL | Status | Notes |
|---|---|---|---|
| Pi homelab — Flask API | `https://web.learndevops.site` | Stable | k3s on Raspberry Pi 5, Cloudflare Tunnel, zero open ports |
| Pi homelab — Juice Shop | `https://juice.learndevops.site` | Stable | Intentionally vulnerable app, Cloudflare Access restricted |
| Pi homelab — ArgoCD | `https://pi-argo.learndevops.site` | Stable | GitOps control plane |
| AWS cloud | `terraform output -raw alb_url` | On-Demand | Provisioned via Terraform for validation (often destroyed to avoid cost) |

---

## What this project demonstrates

This is not a tutorial deployment. It is a working system that proves the following:

**The pipeline catches real things.** OWASP Juice Shop is intentionally vulnerable — when ZAP scans it, it finds SQL injection, XSS, broken authentication, and 100+ other findings. When Trivy scans the npm dependency tree, it surfaces real CVEs. The security tools are not running against a clean demo app — they are doing actual work.

**Kyverno enforces, not just reports.** The official Juice Shop image (`bkimminich/juice-shop`) runs as root (UID 0). Our `juice-shop-require-non-root` ClusterPolicy blocks it cold at admission. Only the pipeline-built hardened image — signed with our Cosign key, running as UID 1000 — is admitted to the cluster. Try to deploy the official image directly and Kyverno rejects it with a policy violation message.

**Every deployment is a Git commit.** There is no manual `kubectl apply` in the delivery loop after bootstrap. Push code → pipeline builds and signs the image → pipeline commits the digest to `patch-image.yaml` → ArgoCD detects the commit and syncs → Kyverno verifies the signature → rolling deploy. Rollback is `git revert`.

**Immutable image references.** Manifests reference images by digest (`@sha256:...`) not by tag. A digest is the SHA256 of the image manifest itself and cannot be spoofed or overwritten. Kyverno verifies the Cosign signature against this exact digest.

---

## How the system works

### The full delivery loop

```
Developer pushes to GitHub
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│  GitHub Actions — DevSecOps Pipeline                        │
│                                                             │
│  [SAST: Bandit] ──────────────────────────────┐             │
│                                               ├─▶ PASS      │
│  [Secrets: Trivy filesystem scan] ────────────┘             │
│            │ (parallel, both must pass)                     │
│            ▼                                                │
│  [Build Flask image — amd64 for scanning]                   │
│  [Build Juice Shop image — amd64 for scanning]              │
│  [Generate SBOMs — CycloneDX for both images]               │
│  [Push Flask to ECR + GAR — amd64/arm64]                    │
│  [Push Juice Shop to ECR — amd64/arm64]                     │
│  [Sign all images with Cosign — by digest]                  │
│            │                                                │
│            ▼                                                │
│  [Trivy: Flask — SARIF report + CRITICAL gate]  ─┐          │
│  [Trivy: Juice Shop — SARIF report only]         ├─▶ PASS   │
│  [Checkov: IaC scan — Terraform]                 ─┘          │
│            │ (parallel)                                     │
│            ▼                                                │
│  [ZAP Baseline — Flask staging container]                   │
│  [ZAP Full Scan — Juice Shop staging container]             │
│            │                                                │
│            ▼                                                │
│  [Commit @sha256 digest to patch-image.yaml files]          │
└─────────────────────────────────────────────────────────────┘
         │
         ▼
ArgoCD detects Git commit → Kustomize renders manifests
         │
         ▼
Kyverno admission webhook:
  ✓ Image signed by trusted Cosign key?
  ✓ Running as non-root?
  ✓ No privileged containers?
  ✓ Read-only root filesystem?
  ✓ Resource limits declared?
         │
         ▼
Rolling deploy → new pod Running → old pod Terminated
Cluster state matches Git state ✓
```

### The GitOps loop — how the Pi stays in sync

```
git push
    │
    ▼
Pipeline builds image → pushes to ECR with sha tag
    │
    ▼
Pipeline signs image by digest with Cosign
    │
    ▼
Pipeline commits digest to:
  gitops/manifests/flask-app/overlays/pi/patch-image.yaml
  gitops/manifests/juice-shop/overlays/pi/patch-image.yaml
    │
    ▼
ArgoCD detects the Git commit (polls every 3 minutes)
    │
    ▼
Kustomize renders base/ + overlays/pi/ patches
    │
    ▼
Kyverno verifies image signature + all pod security policies
    │
    ▼
kubectl apply → zero-downtime rolling deploy
Every deploy is a Git commit. Every rollback is git revert.
```

### The "Direct" architecture (Pi ingress)

`cloudflared` runs as an in-cluster Deployment. Public traffic flows:

```
Internet → Cloudflare Edge → Tunnel (outbound-only from Pi)
    → cloudflared pod → internal Service → application pod
```

Zero open inbound ports on the Pi. No NAT rules. No port forwarding. The Pi initiates the tunnel connection outbound and Cloudflare proxies requests back through it.

---

## Security gates

| Gate | Tool | Failure mode | What it catches |
|------|------|-------------|----------------|
| SAST | Bandit | Warn + artifact | Insecure Python patterns — `eval()`, shell injection, weak crypto |
| Secret scan | Trivy (filesystem) | **Hard fail** | Credentials, API keys, tokens committed to source |
| Container scan — Flask | Trivy + SARIF | **Hard fail on CRITICAL** | CVEs in image layers (blocks build on unfixable criticals) |
| Container scan — Juice Shop | Trivy + SARIF | Report only | CVEs in npm tree (expected — intentionally vulnerable) |
| IaC scan | Checkov | Warn + artifact | Terraform misconfigurations — open security groups, broad IAM |
| DAST — Flask | OWASP ZAP baseline | Warn + artifact | Missing headers, weak hardening, exposed attack surface |
| DAST — Juice Shop | OWASP ZAP full scan | Report only | 100+ OWASP Top 10 findings (expected — intentionally vulnerable) |
| Image signing | Cosign + Kyverno | **Hard fail at admission** | Blocks any unsigned or tampered image from running in cluster |
| Pod security | Kyverno ClusterPolicies | **Hard fail at admission** | Root containers, privileged mode, missing limits |

Hard-fail gates: secret scanning, CRITICAL container vulnerabilities (Flask only), unsigned images, and policy-violating pod specs. Juice Shop scans are report-only because findings are the point, not the gate.

---

## OWASP Juice Shop — the DevSecOps demonstration app

Juice Shop is a deliberately insecure Node.js application maintained by OWASP. It exists in this project to prove the pipeline does real work.

### Why it is here

Running security scanners against a clean Flask health-check endpoint is a demo. Running them against Juice Shop is a proof of concept. ZAP discovers SQL injection, XSS, and broken authentication on every scan. Trivy surfaces real CVEs in the npm dependency tree. The SBOM captures a dependency graph with known vulnerabilities. This is what the tools look like when they find something.

### The Kyverno redemption story

```bash
# Try to deploy the official image directly — runs as root (UID 0)
kubectl run test --image=bkimminich/juice-shop:latest -n juice-shop

# Kyverno blocks it immediately:
# Error: admission webhook "validate.kyverno.svc-fail" denied the request:
# resource Pod/juice-shop/test was blocked due to the following policies
# juice-shop-require-non-root:
#   check-non-root: The official Juice Shop image runs as root and is blocked.
#   Only the pipeline-hardened image (runAsUser: 1000) is admitted.
```

Only the image built by our pipeline — signed with the Cosign key, running as UID 1000, with all capabilities dropped — passes admission.

### What is hardened vs what is intentionally left vulnerable

| Layer | Status | Detail |
|-------|--------|--------|
| Runs as non-root | ✅ Fixed | UID 1000 — upstream image uses root |
| No privilege escalation | ✅ Fixed | `allowPrivilegeEscalation: false` |
| All capabilities dropped | ✅ Fixed | `capabilities.drop: [ALL]` |
| Resource limits | ✅ Fixed | 512Mi/500m limits enforced by Kyverno |
| Image signed | ✅ Fixed | Cosign signature verified by Kyverno |
| SQL injection endpoints | ❌ Intentional | ZAP will find these |
| XSS vulnerabilities | ❌ Intentional | ZAP will find these |
| Broken authentication | ❌ Intentional | ZAP will find these |
| npm CVEs | ❌ Intentional | Trivy will surface these |

### Memory impact on the Pi

| Component | Idle | During ZAP scan |
|-----------|------|-----------------|
| Juice Shop pod | ~280MB | ~400MB |
| Existing cluster total | ~5,140MB | ~5,140MB |
| New total | ~5,420MB | ~5,540MB |
| Remaining headroom | ~2,330MB | ~2,210MB |

---

## How to verify the pipeline is working

### 1. Verify the pipeline ran end to end

```bash
# Check the latest GitHub Actions run — all jobs should be green
# Actions tab → Juice Shop DevSecOps Pipeline → latest run

# Confirm the deploy job committed a digest to the manifests
git log --oneline | head -5
# Should show: chore(gitops): deploy sha-<commit> to all clusters [skip ci]

# Confirm the manifest contains a digest reference (not a tag)
cat gitops/manifests/flask-app/overlays/pi/patch-image.yaml
# Should show: image: 393818036545.dkr.ecr.us-east-1.amazonaws.com/...@sha256:...

cat gitops/manifests/juice-shop/overlays/pi/patch-image.yaml
# Same — should show @sha256 not :sha-
```

### 2. Verify ArgoCD synced

```bash
# All apps should be Synced + Healthy
kubectl get apps -n argocd

# If flask-app or juice-shop shows OutOfSync or Degraded:
kubectl describe app flask-app -n argocd | grep -A5 "Message:"
kubectl describe app juice-shop -n argocd | grep -A5 "Message:"
```

### 3. Verify Kyverno admitted the pods

```bash
# Pods should be Running — if Kyverno blocked them they will be missing entirely
kubectl get pods -n devsecops-app
kubectl get pods -n juice-shop

# Check for any Kyverno admission denials in the last hour
kubectl get events -n devsecops-app | grep -i kyverno
kubectl get events -n juice-shop | grep -i kyverno

# Check Kyverno policy reports
kubectl get policyreport -n devsecops-app
kubectl get policyreport -n juice-shop
```

### 4. Verify image signatures

Cosign needs to pull the signature object from ECR to verify. Authenticate first or you may get a `401 Unauthorized` even though the signature is valid.

Kyverno embeds the public key in `gitops/manifests/kyverno/policies/verify-image-signature.yaml`. To verify from your workstation, save that key to `cosign.pub` (or use your existing public key file).

```bash
# Step 1 — authenticate to ECR (token expires every 12 hours)
aws ecr get-login-password --region us-east-1 \
  | docker login \
    --username AWS \
    --password-stdin \
    393818036545.dkr.ecr.us-east-1.amazonaws.com

# Verify the Flask image signature
FLASK_DIGEST=$(kubectl get pod -n devsecops-app \
  -o jsonpath='{.items[0].spec.containers[0].image}' | cut -d@ -f2)
cosign verify \
  --key cosign.pub \
  393818036545.dkr.ecr.us-east-1.amazonaws.com/devsecops-pipeline-secure@$FLASK_DIGEST

# Verify the Juice Shop image signature
JUICE_DIGEST=$(kubectl get pod -n juice-shop \
  -o jsonpath='{.items[0].spec.containers[0].image}' | cut -d@ -f2)
cosign verify \
  --key cosign.pub \
  393818036545.dkr.ecr.us-east-1.amazonaws.com/juice-shop@$JUICE_DIGEST

# Both should return: Verification for ... -- The following checks were performed...
```

### 5. Prove Kyverno blocks the official Juice Shop image

```bash
# This should be blocked — the official image runs as root
kubectl run kyverno-test \
  --image=bkimminich/juice-shop:latest \
  --namespace=juice-shop \
  --restart=Never

# Expected output:
# Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
# juice-shop-require-non-root: The official Juice Shop image runs as root and is blocked.

# Clean up the failed attempt
kubectl delete pod kyverno-test -n juice-shop --ignore-not-found=true
```

### 6. Verify the ECR token refreshers are running

```bash
# CronJobs should show a recent last schedule time
kubectl get cronjob -n devsecops-app
kubectl get cronjob -n kyverno

# Check last job runs
kubectl get jobs -n devsecops-app
kubectl get jobs -n kyverno

# Image pull secrets
kubectl get secret ecr-secret -n devsecops-app
kubectl get secret regcred -n devsecops-app
kubectl get secret regcred -n juice-shop
kubectl get secret regcred -n kyverno
```

### 7. Verify the applications are reachable

```bash
# Flask API health check
curl -s https://web.learndevops.site/health
# Expected: {"status": "healthy"}

# Juice Shop (requires Cloudflare Access login)
curl -I https://juice.learndevops.site
# Expected: 200 OK (after auth)

# Check resource usage — Pi should have headroom
kubectl top nodes
kubectl top pods -A --sort-by=memory
```

### 8. Verify scan artifacts are in GitHub

After a pipeline run, check the Actions run artifacts:
- `bandit-report` — SAST findings for the Flask app
- `final-sbom` — CycloneDX SBOM for Flask
- `juice-shop-sbom` — CycloneDX SBOM for Juice Shop (the interesting one)

And in the GitHub Security tab (repository → Security → Code scanning):
- Flask app findings under category `flask-app`
- Juice Shop findings under category `juice-shop`
- Both should show HIGH/CRITICAL findings from Trivy

---

## Implemented security features

### 1. Shift-left security (CI stage)

- **SAST (Bandit):** automated Python static analysis to catch insecure code patterns early in CI.
- **Secret scanning (Trivy):** repository scan runs as a blocking gate to prevent leaked credentials from entering the delivery path.
- **SCA and SBOM (Syft):** the pipeline generates CycloneDX SBOMs for both the Flask app and Juice Shop. The Juice Shop SBOM captures a real vulnerable dependency graph.

### 2. Container integrity and signing

- **Multi-arch builds:** Docker Buildx publishes `linux/amd64` and `linux/arm64` images for cloud and edge runtime compatibility.
- **Vulnerability enforcement gate:** Trivy performs both report generation (SARIF) and enforcement (`CRITICAL` findings fail the Flask build). Juice Shop is report-only by design.
- **Image signing (Cosign):** all images signed by digest for ECR and GAR. Kyverno verifies the signature at admission — unsigned images cannot run.
- **Immutable references:** GitOps manifests use `@sha256:` digest references, not mutable tags.

### 3. Continuous deployment and GitOps

- **Automated manifest updates:** GitHub Actions patches GitOps manifests with `@sha256` digests on every push to main.
- **ArgoCD orchestration:** pull-based sync continuously reconciles cluster state to Git state.
- **Traceable rollbacks:** every deploy is a Git commit; rollback is a standard `git revert`.

### 4. Cluster-side enforcement (admission control)

- **Kyverno policy engine:** runtime policy-as-code enforcement in-cluster.
- **Signature verification:** `verify-image-signature` ClusterPolicy blocks unsigned or untrusted images.
- **Pod security controls:** policies enforce non-root, disallow privileged containers, and require resource limits — applied to both `devsecops-app` and `juice-shop` namespaces with intentional scoping.
- **Automated cleanup:** ClusterCleanupPolicy prunes `PolicyReport` objects every 24h.

---

## Infrastructure overview

- **Cloud:** AWS (ECR/EC2/ALB via Terraform) and GCP (GAR path retained for multi-cloud pipeline support).
- **Edge:** Raspberry Pi 5 running k3s as the primary live cluster.
- **Ingress:** Cloudflare Tunnel via in-cluster `cloudflared` Deployment — zero open inbound ports.
- **Security toolchain:** Cosign, Kyverno, Trivy, Bandit, Checkov, OWASP ZAP, Syft.

---

## Architecture decisions

**GitOps with pipeline-driven digest commits** — ArgoCD Image Updater was evaluated but the simplest, most auditable pattern is having the pipeline commit the new image digest directly to `patch-image.yaml`. Every deploy is a traceable Git commit with author, timestamp, and SHA. Rollback is `git revert`.

**Digest over tag** — manifests reference `image@sha256:...` not `image:tag`. A tag is mutable — it can be overwritten to point to a different image. A digest is the SHA256 of the image manifest and is cryptographically immutable. Kyverno's `verifyImages` resolves the digest and checks the Cosign signature against it. Using a tag caused Kyverno lookup failures under load — switching to digest fixed this permanently.

**Sign by digest not tag** — Cosign signatures are attached to the digest, not the tag. This is what Kyverno actually verifies. Signing a tag is misleading because the tag can move after signing.

**Kustomize over Helm for application manifests** — Kustomize is built into kubectl and ArgoCD natively. The base/overlay pattern keeps canonical manifests and applies environment patches on top. The pipeline only ever touches `patch-image.yaml`.

**App of Apps pattern** — the Pi cluster uses a root ArgoCD Application that manages all child applications from `gitops/apps-pi/`. One `kubectl apply` at bootstrap, then Git drives everything.

**Hardened pod security context** — containers run as non-root (UID 1000), with `readOnlyRootFilesystem: true` (Flask), `allowPrivilegeEscalation: false`, and all Linux capabilities dropped. Juice Shop gets a scoped exception for `readOnlyRootFilesystem` because its SQLite database and Express server require a writable filesystem — documented and enforced via a namespace-scoped policy exception.

**Cloudflare Tunnel over port forwarding** — the Pi has zero open inbound ports. The tunnel creates an outbound-only encrypted connection to Cloudflare's edge.

---

## Tech stack

**Applications**
- Flask API: Python 3.12, Flask 3.0, Gunicorn, `prometheus-flask-exporter`, `flask-limiter`
- Juice Shop: Node.js 20, Express, SQLite — OWASP intentionally vulnerable app, hardened image

**Pipeline — GitHub Actions**
- Bandit (SAST), Trivy (secrets + container), Syft (SBOM), Cosign (signing), Checkov (IaC), OWASP ZAP (DAST)
- `docker/build-push-action` — `linux/amd64,linux/arm64` multi-arch builds
- GitOps digest write-back to overlay `patch-image.yaml` files

**AWS infrastructure — Terraform**
- VPC, ALB, EC2, ECR (scan-on-push), IAM (least privilege), S3 remote state

**Kubernetes — Raspberry Pi 5**
- k3s, ArgoCD (App of Apps), Kustomize, Kyverno, kube-prometheus-stack, Cloudflare Tunnel

---

## Repository structure

```
devsecops-pipeline/
├── app/
│   ├── main.py                        # Flask API
│   └── requirements.txt
│
├── juice-shop/
│   ├── Dockerfile                     # Hardened Juice Shop image (non-root, UID 1000)
│   └── SETUP.md                       # Implementation notes
│
├── Dockerfile                         # Flask — multi-stage, non-root, multi-arch
│
├── terraform/
│   ├── aws/                           # VPC, ALB, EC2, ECR, IAM, S3 state
│   └── gke/                           # GKE Autopilot (optional)
│
├── gitops/
│   ├── bootstrap/
│   │   └── pi-infra.yaml              # Root app — the only manual kubectl apply
│   │
│   ├── apps-pi/                       # ArgoCD Applications for the Pi cluster
│   │   ├── flask-app.yaml
│   │   ├── juice-shop.yaml            # Juice Shop ArgoCD Application
│   │   ├── apps-shared.yaml
│   │   ├── cloudflared-app.yaml
│   │   ├── kyverno-refresher-app.yaml # ECR token refresher for Kyverno namespace
│   │   └── sealed-secrets-app.yaml
│   │
│   ├── apps-shared/
│   │   ├── monitoring.yaml
│   │   ├── kyverno.yaml
│   │   └── kyverno-policies.yaml
│   │
│   └── manifests/
│       ├── flask-app/
│       │   ├── base/
│       │   └── overlays/
│       │       ├── pi/
│       │       │   └── patch-image.yaml   # ← pipeline writes @sha256 digest here
│       │       └── gke/
│       │           └── patch-image.yaml   # ← pipeline writes @sha256 digest here
│       │
│       ├── juice-shop/
│       │   ├── base/
│       │   └── overlays/pi/
│       │       ├── patch-image.yaml       # ← pipeline writes @sha256 digest here
│       │       └── patch-replicas.yaml
│       │
│       ├── kyverno/
│       │   ├── values.yaml
│       │   └── policies/
│       │       ├── verify-image-signature.yaml
│       │       ├── disallow-privileged.yaml
│       │       ├── require-non-root.yaml
│       │       ├── require-readonly-fs.yaml
│       │       ├── require-resource-limits.yaml
│       │       ├── juice-shop-exceptions.yaml
│       │       └── cleanup-policy.yaml
│       │
│       └── utils/
│           ├── cloudflared/
│           ├── ecr-refresher/             # ECR token refresher for devsecops-app
│           ├── kyverno-ecr-refresher/     # ECR token refresher for kyverno + regcred propagation
│           └── sealed-secrets/
│
├── .zap/
│   └── rules.tsv
│
└── .github/
    └── workflows/
        └── juice-shop-pipeline.yaml
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

```bash
# 1. Create S3 bucket for Terraform state
aws s3api create-bucket \
  --bucket mali-devsecops-pipeline-tfstate \
  --region us-east-1
aws s3api put-bucket-versioning \
  --bucket mali-devsecops-pipeline-tfstate \
  --versioning-configuration Status=Enabled

# 2. Create ECR repositories
aws ecr create-repository --repository-name devsecops-pipeline-secure --region us-east-1
aws ecr create-repository --repository-name juice-shop --region us-east-1

# 3. Create EC2 key pair
aws ec2 create-key-pair \
  --key-name devsecops-key \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/devsecops-key.pem && chmod 400 ~/.ssh/devsecops-key.pem

# 4. Provision everything
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
| `COSIGN_PRIVATE_KEY` | Cosign private key (from `cosign generate-key-pair`) |
| `COSIGN_PASSWORD` | Cosign key password |
| `GITOPS_PAT` | GitHub PAT with repo write scope |
| `SLACK_WEBHOOK` | Slack incoming webhook URL |

Optional (only if you want GAR pushes enabled):

| Secret | Value |
|--------|-------|
| `GCP_PROJECT_ID` | GCP project id |
| `GCP_PROJECT_NUMBER` | GCP project number |
| `GCP_WORKLOAD_IDENTITY_POOL` | WIF pool name |
| `GCP_SERVICE_ACCOUNT` | Service account email for WIF |

---

## Deploying the GitOps cluster (Pi)

```bash
# 1. Install k3s
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable servicelb

# 2. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Create initial ECR pull secrets (CronJobs maintain these after bootstrap)
kubectl create namespace devsecops-app
kubectl create secret docker-registry ecr-secret \
  --namespace devsecops-app \
  --docker-server=393818036545.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$(aws ecr get-login-password --region us-east-1)

kubectl create namespace juice-shop
kubectl create secret docker-registry regcred \
  --namespace juice-shop \
  --docker-server=393818036545.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$(aws ecr get-login-password --region us-east-1)

# 4. Apply the root application — only manual kubectl apply needed
kubectl apply -f gitops/bootstrap/pi-infra.yaml

# 5. Watch ArgoCD bootstrap the cluster from Git
kubectl -n argocd get applications -w

# 6. After kyverno-ecr-refresher syncs, trigger the initial job
#    (the CronJob runs every 6h but you may want regcred in kyverno ns now)
kubectl create job ecr-token-refresher-init \
  --from=cronjob/kyverno-ecr-token-refresher \
  -n kyverno
```

---

## Troubleshooting ledger

Fourteen real issues encountered and resolved during the build.

### 1. Exec format error — architecture mismatch

**Symptom:** Pods on the Pi stuck in `CrashLoopBackOff`.

```
exec /usr/local/bin/gunicorn: exec format error
```

**Root cause:** GitHub Actions runners are `x86_64`. The image was built for Intel only.

**Fix:** Multi-architecture build using QEMU and Buildx:

```yaml
- uses: docker/setup-qemu-action@v4
- uses: docker/setup-buildx-action@v4
- uses: docker/build-push-action@v7
  with:
    platforms: linux/amd64,linux/arm64
```

---

### 2. ECR image desync — Pi not updating after a new push

**Symptom:** New image pushed to ECR. Pi kept running the old container.

**Root cause:** Kubernetes does not re-pull an image if the tag hasn't changed.

**Fix:** SHA-tagged images committed to GitOps manifests. The pipeline commits the new digest to `patch-image.yaml`. ArgoCD detects the Git change and redeploys.

---

### 3. kubectl context collision — MacBook targeting wrong cluster

**Symptom:** `kubectl` commands from the MacBook applied to the local context.

**Fix:**

```bash
export KUBECONFIG=~/.kube/pi-config
alias kpi="KUBECONFIG=~/.kube/pi-config kubectl"
```

---

### 4. Service port mismatch — port-forward failing

**Symptom:** `kubectl port-forward` failed with `Service does not have a service port 5000`.

**Root cause:** The Service maps port `80` → `targetPort 5000`.

**Fix:**

```bash
kubectl port-forward svc/devsecops-api 5001:80 -n devsecops-app
```

---

### 5. readOnlyRootFilesystem blocking Gunicorn worker temp files

**Symptom:**

```
FileNotFoundError: [Errno 2] No usable temporary directory found in ['/tmp', ...]
```

**Root cause:** `readOnlyRootFilesystem: true` locks `/tmp`. Gunicorn needs writable temp space.

**Fix:** Mount a `Memory`-backed `emptyDir` at `/tmp`:

```yaml
volumeMounts:
  - name: tmp
    mountPath: /tmp
volumes:
  - name: tmp
    emptyDir:
      medium: Memory
      sizeLimit: 32Mi
```

---

### 6. ECR token expiry and secret name mismatch

**Symptom:** Pods stuck in `ImagePullBackOff`.

**Root cause:** ECR tokens expire every 12 hours. Secret name mismatch between Deployment (`ecr-secret`) and what the refresh script created (`ecr-registry-secret`).

**Fix:** Standardized secret naming and deployed CronJobs to refresh tokens every 6 hours automatically.

---

### 7. ArgoCD controller CRD desync

**Symptom:** `argocd-applicationset-controller` stuck in `CrashLoopBackOff`.

**Root cause:** `ApplicationSet` CRDs were missing or corrupted.

**Fix:** Re-applied official ArgoCD CRD manifests and hard-refreshed Application objects.

---

### 8. Helm schema type mismatch — expose field

**Symptom:** ArgoCD sync failing with `cannot overwrite table with non table`.

**Root cause:** Traefik Helm chart v26+ changed `expose` from boolean to object.

**Fix:**

```yaml
expose:
  default: true   # object, not true
```

---

### 9. Kyverno missing digest — mutable tag rejected at admission

**Symptom:** ArgoCD sync failed with Kyverno admission denial:

```
missing digest for ...devsecops-pipeline-secure:sha-a08d2f6...
```

**Root cause:** Manifests referenced mutable tags (`:sha-...`). Kyverno's `verifyImages` tries to resolve the tag to a digest and verify the Cosign signature. Under load or network lag this lookup fails or returns an unexpected result.

**Fix:** Pipeline now captures image digests from `docker/build-push-action` outputs and commits `@sha256:...` digest references to manifests. Cosign signatures are also attached to the digest, not the tag.

---

### 10. Kyverno 401 Unauthorized — no ECR credentials in kyverno namespace

**Symptom:**

```
failed to verify image: GET https://393818036545.dkr.ecr.us-east-1.amazonaws.com/...:
unexpected status code 401 Unauthorized (retried 5 times)
```

**Root cause:** Kyverno's admission webhook runs in its own namespace and has no ECR credentials. It cannot pull the image manifest to verify the Cosign signature.

**Fix:** Deployed a separate `kyverno-ecr-token-refresher` CronJob in the `kyverno` namespace to maintain the `regcred` pull secret, which Kyverno uses via `imageRegistryCredentials`.

---

### 11. ArgoCD repo-server pod stuck in Unknown state

**Symptom:** All ArgoCD applications showing `Unknown` sync status. `pi-infra` showed:

```
dial tcp 10.43.154.152:8081: connect: connection refused
```

**Root cause:** The `argocd-repo-server` pod got stuck in `Unknown` state after a node instability event. Without the repo-server, ArgoCD cannot render manifests or compute target state.

**Fix:** Force delete the stuck pod and let Kubernetes recreate it:

```bash
kubectl delete pod -n argocd argocd-repo-server-<pod-id> --force --grace-period=0
```

---

### 12. Juice Shop Dockerfile — GID 1000 conflict and no ARM64 tarball

**Symptom 1:** `groupadd: GID 1000 is already in use` (exit code 4).

**Root cause:** `node:20-bookworm-slim` ships with a built-in `node` group at GID 1000.

**Symptom 2:** `curl: (22) The requested URL returned error: 404` when downloading the release tarball.

**Root cause:** Juice Shop release assets use `_node20_linux_x64.tgz` — no ARM64 tarball exists.

**Fix:** Multi-stage Dockerfile using `COPY --from` to pull the pre-built app from the official image (which handles ARM64 via Docker's multi-arch manifest), then rename the existing `node` user instead of creating a new one:

```dockerfile
FROM bkimminich/juice-shop:v17.1.1 AS upstream
FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates passwd \
    && rm -rf /var/lib/apt/lists/* \
    && usermod -l juicer node \
    && groupmod -n juicer node \
    && usermod -d /home/juicer -m juicer

COPY --from=upstream --chown=juicer:juicer /juice-shop /juice-shop
USER juicer
```

---

### 13. Juice Shop CrashLoopBackOff — emptyDir wiping data/static

**Symptom:**

```
ENOENT: no such file or directory,
copyfile 'data/static/botDefaultTrainingData.json' -> 'data/chatbot/botDefaultTrainingData.json'
```

**Root cause:** The deployment mounted an `emptyDir` at `/juice-shop/data`, which replaced the entire `data/` directory including `data/static/` — files Juice Shop needs at startup.

**Fix:** Scoped the `emptyDir` mount to `/juice-shop/data/chatbot` only:

```yaml
volumeMounts:
  - name: juice-shop-data
    mountPath: /juice-shop/data/chatbot   # scoped — data/static remains intact
```

---

### 14. Cloudflare Tunnel error 1033 — broken ingress rules

**Symptom:** `Rule #3 is matching the hostname '', but this will match every hostname`.

**Root cause:** A comment block in `config.yaml` was indented incorrectly, placing the Juice Shop rule outside the `ingress` block — after the `http_status:404` catch-all.

**Fix:** Fixed indentation and ensured Juice Shop rule appears before the catch-all:

```yaml
ingress:
  - hostname: juice.learndevops.site
    service: http://juice-shop.juice-shop.svc.cluster.local:80
    originRequest:
      httpHostHeader: juice-shop.juice-shop.svc.cluster.local
  - service: http_status:404   # catch-all must always be last
```

---

## Known gaps and next steps

| Item | Status | Plan |
|------|--------|------|
| Flask-Limiter in-memory storage | Open | Deploy Redis to sync rate-limit state across pod replicas |
| ECR pull secret rotation | ✅ Resolved | CronJobs running in `devsecops-app` and `kyverno` namespaces |
| Grafana persistence | Open | Persistent volume claim so dashboards survive pod restarts |
| Single-node k3s | By design | HA requires a second Pi |
| Juice Shop Cloudflare Access | Recommended | Add Access policy on `juice.learndevops.site` — it is intentionally vulnerable |
| Kyverno OutOfSync | Open | Kyverno ArgoCD app shows OutOfSync — CRD drift investigation pending |

---

## Author

Anthony — DevOps & Cloud Engineer

[GitHub](https://github.com/elorm116) · [LinkedIn](https://linkedin.com/inaezottor/) · [Live demo](https://web.learndevops.site) · [Juice Shop](https://juice.learndevops.site)

