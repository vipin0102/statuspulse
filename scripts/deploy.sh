#!/bin/bash
# =============================================================
# StatusPulse — Standalone Server Deployment Script
# scripts/deploy.sh
#
# Uses docker compose — same as GitHub Actions deploy.yml.
#
# Usage:
#   bash ~/scripts/deploy.sh
#   APP_IMAGE=ghcr.io/vipin0102/statuspulse/statuspulse:abc123 bash ~/scripts/deploy.sh
# =============================================================

set -euo pipefail

# =============================================================
# CONFIG
# =============================================================
IMAGE="${APP_IMAGE:-ghcr.io/vipin0102/statuspulse/statuspulse:latest}"
WORKDIR="${WORKDIR:-/opt/statuspulse}"
COMPOSE_FILE="$WORKDIR/docker-compose.yml"
ENV_FILE="$WORKDIR/.env"
LOG_FILE="${LOG_FILE:-$WORKDIR/deploy.log}"
LOCK_FILE="/tmp/statuspulse-deploy.lock"
COMPOSE_PROJECT="statuspulse"
HEALTH_URL="http://localhost:8000/health"
MAX_RETRIES=24
RETRY_INTERVAL=5
GHCR_USER="${GHCR_USER:-}"
GHCR_PAT="${GHCR_PAT:-}"

# =============================================================
# LOGGING
# =============================================================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_section() {
    log "======================================="
    log "  $1"
    log "======================================="
}

# =============================================================
# LOCK — prevents concurrent deploys
# =============================================================
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        LOCK_PID=$(cat "$LOCK_FILE")
        if kill -0 "$LOCK_PID" 2>/dev/null; then
            log "ERROR: deploy already running (PID $LOCK_PID) — exiting"
            exit 1
        fi
        log "WARNING: stale lock from PID $LOCK_PID — removing"
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    log "Lock acquired (PID $$)"
}

release_lock() {
    rm -f "$LOCK_FILE"
    log "Lock released"
}

trap release_lock EXIT

# =============================================================
# COMPOSE WRAPPER — same flags as deploy.yml on GitHub Actions
# =============================================================
compose() {
    APP_IMAGE="$IMAGE" docker compose \
        --project-name "$COMPOSE_PROJECT" \
        --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" \
        "$@"
}

# =============================================================
# HEALTH CHECK
# =============================================================
wait_healthy() {
    local url="$1"
    local label="${2:-app}"

    log "Health check: $label ($url)"
    log "Max $MAX_RETRIES attempts every ${RETRY_INTERVAL}s..."

    for ((i=1; i<=MAX_RETRIES; i++)); do
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
        if [ "$HTTP" = "200" ]; then
            BODY=$(curl -s "$url" 2>/dev/null || true)
            if echo "$BODY" | grep -q '"healthy"'; then
                log "Health check passed (attempt $i/$MAX_RETRIES)"
                return 0
            fi
            log "Attempt $i/$MAX_RETRIES — HTTP $HTTP but not healthy yet"
        else
            log "Attempt $i/$MAX_RETRIES — HTTP $HTTP"
        fi
        sleep "$RETRY_INTERVAL"
    done

    log "ERROR: health check failed after $MAX_RETRIES attempts"
    return 1
}

# =============================================================
# ROLLBACK — restore old image via compose
# =============================================================
rollback() {
    log_section "ROLLBACK"

    if [ -n "${OLD_IMAGE:-}" ]; then
        log "Rolling back to: $OLD_IMAGE"
        APP_IMAGE="$OLD_IMAGE" docker compose \
            --project-name "$COMPOSE_PROJECT" \
            --env-file "$ENV_FILE" \
            -f "$COMPOSE_FILE" \
            up -d --no-build --pull never --remove-orphans
        log "Rollback complete"
    else
        log "WARNING: no previous image — stack left as-is"
    fi

    exit 1
}

# =============================================================
# PREFLIGHT
# =============================================================
preflight() {
    log_section "PREFLIGHT"

    [ -f "$ENV_FILE" ]     || { log "ERROR: .env not found at $ENV_FILE";        exit 1; }
    [ -f "$COMPOSE_FILE" ] || { log "ERROR: docker-compose.yml not found at $COMPOSE_FILE"; exit 1; }
    command -v docker >/dev/null 2>&1 || { log "ERROR: docker not installed";    exit 1; }
    docker compose version >/dev/null 2>&1 || { log "ERROR: docker compose not available"; exit 1; }

    mkdir -p "$(dirname "$LOG_FILE")"

    # GHCR login if credentials provided
    if [ -n "$GHCR_PAT" ] && [ -n "$GHCR_USER" ]; then
        log "Logging in to GHCR as $GHCR_USER..."
        echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
        log "GHCR login successful"
    else
        log "Using saved docker login credentials"
    fi

    log "IMAGE:        $IMAGE"
    log "WORKDIR:      $WORKDIR"
    log "COMPOSE_FILE: $COMPOSE_FILE"
    log "ENV_FILE:     $ENV_FILE"
    log "PROJECT:      $COMPOSE_PROJECT"
    log "Preflight passed"
}

# =============================================================
# ENSURE DEPENDENCIES — postgres + redis must be running
# before app starts. On first deploy, start full stack.
# =============================================================
ensure_dependencies() {
    log_section "CHECKING DEPENDENCIES"

    POSTGRES_RUNNING=$(docker inspect statuspulse-postgres \
        --format='{{.State.Running}}' 2>/dev/null || echo "false")
    REDIS_RUNNING=$(docker inspect statuspulse-redis \
        --format='{{.State.Running}}' 2>/dev/null || echo "false")

    if [ "$POSTGRES_RUNNING" = "true" ] && [ "$REDIS_RUNNING" = "true" ]; then
        log "postgres: running ✓"
        log "redis:    running ✓"
        return 0
    fi

    log "postgres: $POSTGRES_RUNNING"
    log "redis:    $REDIS_RUNNING"
    log "Dependencies not running — starting full stack first..."

    # Start everything except app (app will be started separately with new image)
    compose up -d --remove-orphans postgres redis

    log "Waiting for postgres and redis to be healthy..."
    local retries=20
    for ((i=1; i<=retries; i++)); do
        PG=$(docker inspect statuspulse-postgres \
            --format='{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
        RD=$(docker inspect statuspulse-redis \
            --format='{{.State.Health.Status}}' 2>/dev/null || echo "unknown")

        log "Attempt $i/$retries — postgres: $PG | redis: $RD"

        if [ "$PG" = "healthy" ] && [ "$RD" = "healthy" ]; then
            log "postgres: healthy ✓"
            log "redis:    healthy ✓"
            return 0
        fi
        sleep 5
    done

    log "ERROR: dependencies failed to become healthy"
    exit 1
}

# =============================================================
# MAIN
# =============================================================
main() {
    log_section "DEPLOYMENT STARTED"
    log "Image: $IMAGE"

    acquire_lock
    preflight

    cd "$WORKDIR"

    # ----------------------------------------------------------
    # 1. Save current image for rollback
    # ----------------------------------------------------------
    log_section "SAVING CURRENT STATE"
    OLD_IMAGE=$(docker inspect statuspulse-app \
        --format='{{.Config.Image}}' 2>/dev/null || true)
    log "Current image: ${OLD_IMAGE:-none (first deploy)}"

    # ----------------------------------------------------------
    # 2. Pull latest image from ghcr.io
    # ----------------------------------------------------------
    log_section "PULLING IMAGE"
    log "Pulling: $IMAGE"
    if ! docker pull "$IMAGE"; then
        log "ERROR: failed to pull $IMAGE"
        exit 1
    fi
    log "Pull complete"

    # ----------------------------------------------------------
    # 3. Ensure postgres + redis are running before deploying app
    # ----------------------------------------------------------
    ensure_dependencies

    # ----------------------------------------------------------
    # 4. Zero-downtime: stop only app, start new via compose
    #    postgres/redis/caddy/uptime-kuma stay running
    # ----------------------------------------------------------
    log_section "ZERO-DOWNTIME DEPLOY VIA DOCKER COMPOSE"

    log "Stopping old app container..."
    docker stop statuspulse-app 2>/dev/null || true
    docker rm   statuspulse-app 2>/dev/null || true
    log "Old app container removed"

    log "Starting new app container via docker compose..."
    compose up -d \
        --no-deps \
        --no-build \
        --pull never \
        --remove-orphans \
        app

    log "New app container started — waiting 10s for startup..."
    sleep 10

    # ----------------------------------------------------------
    # 5. Health check
    # ----------------------------------------------------------
    log_section "HEALTH CHECK"

    if ! wait_healthy "$HEALTH_URL" "new app container"; then
        log "=== App container logs ==="
        docker logs statuspulse-app --tail 50 2>/dev/null || true
        log "=== Postgres logs ==="
        docker logs statuspulse-postgres --tail 20 2>/dev/null || true
        log "=== Redis logs ==="
        docker logs statuspulse-redis --tail 20 2>/dev/null || true
        rollback
    fi

    # ----------------------------------------------------------
    # 6. Bring up any remaining services (caddy, uptime-kuma)
    # ----------------------------------------------------------
    log_section "FULL STACK SYNC"
    log "Ensuring full stack is running..."
    compose up -d --remove-orphans
    log "Full stack in sync"

    # ----------------------------------------------------------
    # 7. Cleanup
    # ----------------------------------------------------------
    log_section "CLEANUP"
    docker image prune -f 2>/dev/null || true
    log "Old images pruned"

    # ----------------------------------------------------------
    # Done
    # ----------------------------------------------------------
    log_section "DEPLOYMENT SUCCESSFUL"
    log "Deployed:  $IMAGE"
    log "Replaced:  ${OLD_IMAGE:-none}"
    log "Log:       $LOG_FILE"
}

main "$@"  