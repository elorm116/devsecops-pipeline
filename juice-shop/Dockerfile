# Stage 1 — grab the pre-built app from the official image
# This handles ARM64/AMD64 transparently, no tarball needed
FROM bkimminich/juice-shop:v17.1.1 AS upstream

# Stage 2 — clean hardened base
FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    passwd \
    && rm -rf /var/lib/apt/lists/* \
    && usermod -l juicer node \
    && groupmod -n juicer node \
    && usermod -d /home/juicer -m juicer

# Copy app from official image — not from internet, not from tarball
COPY --from=upstream --chown=juicer:juicer /juice-shop /juice-shop

WORKDIR /juice-shop

RUN mkdir -p /juice-shop/data && \
    chown -R juicer:juicer /juice-shop

# Switch to non-root — Kyverno require-non-root passes here
# Official image runs as root (UID 0) and would be blocked
USER juicer

EXPOSE 3000
ENV NODE_ENV=production
ENV PORT=3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:3000/rest/admin/application-version || exit 1

CMD ["node", "build/app.js"]