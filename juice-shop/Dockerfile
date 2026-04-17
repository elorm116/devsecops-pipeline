FROM node:20-bookworm-slim AS base

# 1. Install shadow tools and perform the "Identity Hijack"
# We rename 'node' to 'juicer' so UID 1000 is preserved without a new useradd
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    shadow \
    && rm -rf /var/lib/apt/lists/* \
    && usermod -l juicer node \
    && groupmod -n juicer node \
    && usermod -d /home/juicer -m juicer 

WORKDIR /juice-shop

# 2. Pull the release
ARG JUICE_SHOP_VERSION=v17.1.1
RUN curl -fsSL \
    https://github.com/juice-shop/juice-shop/releases/download/${JUICE_SHOP_VERSION}/juice-shop-${JUICE_SHOP_VERSION}_node20_linux_x64.tgz \
    | tar -xz --strip-components=1

# 3. Create data dir and fix permissions for the newly renamed 'juicer'
RUN mkdir -p /juice-shop/data && \
    chown -R juicer:juicer /juice-shop

USER juicer
EXPOSE 3000

ENV NODE_ENV=production
ENV PORT=3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:3000/rest/admin/application-version || exit 1

CMD ["node", "build/app.js"]