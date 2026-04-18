# OWASP Juice Shop — DevSecOps Integration Guide

## What This Is

OWASP Juice Shop is a deliberately insecure Node.js web application used to
demonstrate security tooling. In this setup it serves two purposes:

1. **Prove the pipeline works** — ZAP, Trivy, and SAST will find 100+ real
   vulnerabilities, turning your pipeline from a demo into a proof of concept.

2. **Prove Kyverno enforces policy** — The official Juice Shop image runs as
   root and gets blocked cold by our `juice-shop-require-non-root` policy.
   Only the hardened image built by our pipeline (UID 1000) is admitted.

---

## Repository Structure

Add the following files to your repo:

```
juice-shop/                                    ← new top-level app directory
└── Dockerfile                                 ← hardened image (non-root)

gitops/
├── apps-pi/
│   └── juice-shop.yaml                        ← ArgoCD Application
└── manifests/
    ├── juice-shop/
    │   ├── base/
    │   │   ├── namespace.yaml
    │   │   ├── deployment.yaml
    │   │   ├── service.yaml
    │   │   ├── ingress.yaml
    │   │   └── kustomization.yaml
    │   └── overlays/
    │       └── pi/
    │           ├── kustomization.yaml
    │           ├── patch-image.yaml           ← pipeline writes digest here
    │           └── patch-replicas.yaml
    ├── kyverno/
    │   └── policies/
    │       ├── juice-shop-exceptions.yaml     ← NEW: add this
    │       └── kustomization.yaml             ← UPDATED: add juice-shop-exceptions
    └── utils/
        └── cloudflared/
            └── base/
                └── config.yaml               ← UPDATED: add your domain.something.com
```

---

## Step 1 — Add ECR Repository

Create a new ECR repository for Juice Shop (separate from your Flask app):

```bash
aws ecr create-repository \
  --repository-name juice-shop \
  --region us-east-1 \
  --image-scanning-configuration scanOnPush=true
```

---

## Step 2 — Add Pipeline Jobs

This repo already includes these changes in `.github/workflows/juice-shop-pipeline.yaml`.
If you’re integrating Juice Shop into a different workflow in your own repo, use the same patterns below.

### A. Build job addition — juice-shop

Add this to your existing `build` job outputs and steps. The Juice Shop build
runs in parallel with the Flask build since they are independent:

```yaml
# In the build job outputs block — add:
outputs:
  ecr-digest: ${{ steps.build-ecr.outputs.digest }}
  gar-digest: ${{ steps.build-gar.outputs.digest }}
  juice-shop-digest: ${{ steps.build-juice-shop.outputs.digest }}  # ADD THIS

# Add this step after your ECR login step:
- name: Build and push Juice Shop to ECR
  if: github.ref == 'refs/heads/main'
  id: build-juice-shop
  uses: docker/build-push-action@v7
  with:
    context: ./juice-shop          # Our hardened Dockerfile lives here
    platforms: linux/amd64,linux/arm64
    push: true
    provenance: false
    tags: |
      ${{ steps.ecr-login.outputs.registry }}/juice-shop:${{ github.sha }}
      ${{ steps.ecr-login.outputs.registry }}/juice-shop:sha-${{ github.sha }}
      ${{ steps.ecr-login.outputs.registry }}/juice-shop:latest
    cache-from: type=gha
    cache-to: type=gha,mode=max

# Sign Juice Shop image by digest (recommended) — add to your existing signing step:
- name: Sign all images by digest
  if: github.ref == 'refs/heads/main'
  env:
    COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}
    COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
    JUICE_REF: ${{ steps.ecr-login.outputs.registry }}/juice-shop@${{ steps.build-juice-shop.outputs.digest }}
  run: |
    echo "$COSIGN_PRIVATE_KEY" > cosign.key
    cosign sign --key cosign.key $JUICE_REF
    rm -f cosign.key
```

### B. DAST job — point ZAP at Juice Shop too

Update your `dast` job to also scan Juice Shop. This is where it gets
interesting — ZAP against Juice Shop will find SQL injection, XSS,
broken auth, and more:

```yaml
dast:
  name: DAST — OWASP ZAP
  needs: [container-scan, iac-scan]
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: actions/download-artifact@v4
      with: { name: docker-image, path: /tmp }
    - run: docker load -i /tmp/image.tar

    # Scan Flask app (existing)
    - name: Start Flask staging app
      run: |
        docker run -d --name staging-app \
          -p ${{ env.CONTAINER_PORT }}:${{ env.CONTAINER_PORT }} \
          ${{ env.IMAGE_NAME }}:${{ github.sha }}
        sleep 10
    - name: ZAP Scan — Flask App
      uses: zaproxy/action-baseline@v0.15.0
      with:
        target: http://localhost:${{ env.CONTAINER_PORT }}
        rules_file_name: .zap/rules.tsv
        cmd_options: -I

    # Scan Juice Shop (new) — use full scan not baseline for more findings
    # Recommended: run against the locally-built image artifact so this job
    # does not require AWS credentials to pull from ECR.
    - uses: actions/download-artifact@v4
      with: { name: juice-shop-image, path: /tmp }
    - run: docker load -i /tmp/juice-shop.tar
    - name: Start Juice Shop staging
      run: |
        docker run -d --name juice-staging \
          -p 3000:3000 \
          -e NODE_ENV=production \
          juice-shop:${{ github.sha }}
        sleep 30  # Node.js needs longer to start
    - name: ZAP Full Scan — Juice Shop
      uses: zaproxy/action-full-scan@v0.11.0   # Full scan vs baseline for more findings
      with:
        target: http://localhost:3000
        cmd_options: -I                         # Don't fail pipeline on findings (report only)
      continue-on-error: true                   # Findings are expected — don't block deployment

    - name: Cleanup
      if: always()
      run: |
        docker rm -f staging-app juice-staging || true
```

### C. Deploy job — update Juice Shop manifest

Add to your existing `Update Both Overlays` step:

```bash
# Juice Shop (AWS ECR)
PATCH_JUICE=gitops/manifests/juice-shop/overlays/pi/patch-image.yaml
JUICE_URL="393818036545.dkr.ecr.us-east-1.amazonaws.com/juice-shop"
JUICE_DIGEST="${{ needs.build.outputs.juice-shop-digest }}"
sed -i -E "s|^([[:space:]]*)image:.*juice-shop.*|\1image: $JUICE_URL@$JUICE_DIGEST|" "$PATCH_JUICE"
git add "$PATCH_JUICE"
```

---

## Step 3 — Cloudflare DNS

Add a CNAME record in your Cloudflare dashboard:

| Type  | Name  | Target                    |
|-------|-------|---------------------------|
| CNAME | juice | `<your-tunnel-id>.cfargotunnel.com` |

Then add a **Cloudflare Access policy** on `domain.something.com` to
restrict access to yourself only. Juice Shop is intentionally vulnerable —
you don't want it publicly accessible without authentication in front of it.

---

## Step 4 — Update verify-image-signature policy

Add Juice Shop to your Kyverno image verification policy so unsigned
Juice Shop images are also blocked:

```yaml
verifyImages:
  - imageReferences:
      - "393818036545.dkr.ecr.us-east-1.amazonaws.com/devsecops-pipeline-secure*"
      - "393818036545.dkr.ecr.us-east-1.amazonaws.com/juice-shop*"   # ADD THIS
      - "me-west1-docker.pkg.dev/*/devsecops-pipeline-secure/*"
    imageRegistryCredentials:
      secrets:
        - name: regcred
    attestors:
      - count: 1
        entries:
          - keys:
              publicKeys: |-
                -----BEGIN PUBLIC KEY-----
                MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEOI3OsCbTvpBB5jbMi7hQnwzkr2MT
                fCJua07ps2P9UvLkJE20QPMkNoZ7tr5R8itACOTUE/bc0LVz3yIc1L6juw==
                -----END PUBLIC KEY-----
```

---

## The DevSecOps Story This Tells

### What your pipeline FINDS (scan results):
- **Trivy**: dozens of CVEs in npm dependencies (lodash, express, etc.)
- **ZAP Full Scan**: SQL injection, XSS, broken auth, IDOR, and more
- **SAST**: hardcoded secrets in Juice Shop source, eval() usage, etc.

### What Kyverno BLOCKS:
```
# Try to deploy the official image directly:
kubectl run test --image=bkimminich/juice-shop -n juice-shop
# → blocked by juice-shop-require-non-root (runs as root)

# Try to deploy with privileged: true:
# → blocked by juice-shop-disallow-privileged

# Try to deploy an unsigned image:
# → blocked by verify-image-signature
```

### What only passes:
The pipeline-built image signed with your Cosign key, running as UID 1000,
with resource limits set. Everything else is rejected.

---

## Memory Impact on Pi

| Component          | Idle RAM  | During ZAP Scan |
|--------------------|-----------|-----------------|
| Juice Shop pod     | ~280MB    | ~400MB          |
| Your current total | ~5,140MB  | ~5,140MB        |
| New total (idle)   | ~5,420MB  | ~5,540MB        |
| Remaining headroom | ~2,330MB  | ~2,210MB        |

You have comfortable headroom. The ZAP scan spike is temporary and
contained by the 512Mi memory limit on the pod.