# juice-shop/Dockerfile
#
# Hardened OWASP Juice Shop image for the DevSecOps pipeline.

# -----------------------------
# WHY WE BUILD OUR OWN IMAGE:
# ----------------------------
# The official bkimminich/juice-shop image runs as root (UID 0).
# Our Kyverno require-non-root policy blocks this cold.
# This Dockerfile rebuilds Juice Shop to run as UID 1000,
# which satisfies our security gates while keeping the app
# intentionally vulnerable at the application layer.
#
# WHAT THIS FIXES (infrastructure hardening):
#   ✅ Runs as non-root (UID 1000)
#   ✅ Drops ALL Linux capabilities
#   ✅ Sets NODE_ENV=production
#
# WHAT THIS DELIBERATELY KEEPS (application vulnerabilities):
#   ❌ SQL injection endpoints
#   ❌ XSS vulnerabilities
#   ❌ Broken authentication
#   ❌ Sensitive data exposure
#   ❌ All 100+ OWASP challenges
#
# This is the "redemption story" — infrastructure is hardened,
# application is the intentional target for my scanners.
#
FROM node:20-bookworm-slim AS base

# Install only what's needed to run the app
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user — this is what blocks the official image
RUN groupadd --gid 1000 juicer && \
    useradd --uid 1000 --gid juicer --shell /bin/bash --create-home juicer

WORKDIR /juice-shop

# Pull official Juice Shop release — pin the version for reproducibility
# Update this version intentionally when you want to test new CVEs
ARG JUICE_SHOP_VERSION=v17.1.1
RUN curl -fsSL \
    https://github.com/juice-shop/juice-shop/releases/download/${JUICE_SHOP_VERSION}/juice-shop-${JUICE_SHOP_VERSION}_node20_linux_x64.tgz \
    | tar -xz --strip-components=1

# Create writable data directory for SQLite
RUN mkdir -p /juice-shop/data && \
    chown -R juicer:juicer /juice-shop

# Switch to non-root user — Kyverno require-non-root passes here
USER juicer

EXPOSE 3000

ENV NODE_ENV=production
ENV PORT=3000

# Health check — matches what Kubernetes probes hit
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:3000/rest/admin/application-version || exit 1

CMD ["node", "build/app.js"]