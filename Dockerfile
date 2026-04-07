# ── Stage 1: build deps ──────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /build

# Install deps into a prefix dir (keeps final image clean)
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# ── Stage 2: final image ─────────────────────────────────────
FROM python:3.12-slim

# Security: run as non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /install /usr/local

# Copy app source
COPY app/ .

# Security: drop to non-root
USER appuser

# Expose app port
EXPOSE 5000

# Health check — Docker and ECS use this
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')"

# Use gunicorn in production (not Flask dev server)
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--timeout", "60", "main:app"]