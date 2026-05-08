# =========================
# Builder Stage
# =========================
FROM python:3.12-alpine AS builder

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache \
    gcc \
    musl-dev \
    libffi-dev \
    postgresql-dev

# Create virtual environment
RUN python -m venv /opt/venv

ENV PATH="/opt/venv/bin:$PATH"

# Upgrade pip tooling
RUN pip install --upgrade pip setuptools wheel

# Copy requirements first
COPY app/requirements.txt .

# Install dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Remove unnecessary build tooling from runtime venv
RUN rm -rf \
    /opt/venv/lib/python3.12/site-packages/pip* && \
    rm -rf \
    /opt/venv/lib/python3.12/site-packages/setuptools* && \
    rm -rf \
    /opt/venv/lib/python3.12/site-packages/wheel*

# =========================
# Runtime Stage
# =========================
FROM python:3.12-alpine

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# Update OS packages
RUN apk update && \
    apk upgrade && \
    apk add --no-cache \
    curl \
    libpq && \
    rm -rf /var/cache/apk/*

# Create non-root user
RUN addgroup -S appgroup && \
    adduser -S appuser -G appgroup

# Copy virtualenv
COPY --from=builder /opt/venv /opt/venv

# Copy application
COPY . .

# Set ownership
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
CMD curl -f http://localhost:8000/health || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]