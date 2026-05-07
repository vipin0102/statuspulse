# =========================
# Builder Stage
# =========================
FROM python:3.11-alpine AS builder

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

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

# Copy requirements first (better caching)
COPY requirements.txt .

# Install dependencies
RUN pip install --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# =========================
# Runtime Stage
# =========================
FROM python:3.11-alpine

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# Install only runtime packages
RUN apk add --no-cache \
    curl \
    libpq

# Create non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Copy virtual environment from builder
COPY --from=builder /opt/venv /opt/venv

# Copy application code
COPY . .

# Set permissions
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8000

# Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
CMD curl -f http://localhost:8000/health || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]