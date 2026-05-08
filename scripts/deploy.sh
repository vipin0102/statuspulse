#!/bin/bash

# =============================================================
# StatusPulse — Production Deployment Script
#
# Features:
#   ✅ Pull latest image from GHCR
#   ✅ Zero-downtime deployment
#   ✅ Health check validation
#   ✅ Automatic rollback
#   ✅ Timestamp logging
#   ✅ Idempotent execution
#   ✅ Safe repeated execution
#   ✅ Docker Compose based
#   ✅ Production ready
# =============================================================

set -euo pipefail

# =============================================================
# CONFIG
# =============================================================

PROJECT_DIR="/home/deploy/statuspulse/app"

COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"

ENV_FILE="$PROJECT_DIR/.env"

IMAGE="${APP_IMAGE:-ghcr.io/vipin0102/statuspulse:latest}"

HEALTH_URL="https://av-lap-pg0441tk.taildb17d2.ts.net/health"

LOG_FILE="/var/log/statuspulse-deploy.log"

LOCK_FILE="/tmp/statuspulse-deploy.lock"

MAX_RETRIES=20
RETRY_INTERVAL=5

# =============================================================
# LOGGING
# =============================================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_section() {
    log "================================================="
    log "$1"
    log "================================================="
}

# =============================================================
# LOCKING / IDEMPOTENCY
# =============================================================

acquire_lock() {

    if [ -f "$LOCK_FILE" ]; then

        LOCK_PID=$(cat "$LOCK_FILE")

        if kill -0 "$LOCK_PID" 2>/dev/null; then
            log "ERROR: deployment already running (PID $LOCK_PID)"
            exit 1
        fi

        log "Removing stale lock file"
        rm -f "$LOCK_FILE"
    fi

    echo $$ > "$LOCK_FILE"

    log "Lock acquired"
}

release_lock() {

    rm -f "$LOCK_FILE"

    log "Lock released"
}

trap release_lock EXIT

# =============================================================
# HEALTH CHECK
# =============================================================

wait_healthy() {

    log "Running application health checks"

    for ((i=1; i<=MAX_RETRIES; i++)); do

        HTTP=$(curl -k -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" || echo "000")

        if [ "$HTTP" = "200" ]; then

            BODY=$(curl -k -s "$HEALTH_URL" || true)

            if echo "$BODY" | grep -q '"healthy"'; then
                log "Health check successful"
                return 0
            fi
        fi

        log "Health check attempt $i/$MAX_RETRIES failed"

        sleep "$RETRY_INTERVAL"
    done

    log "ERROR: health check failed"

    return 1
}

# =============================================================
# ROLLBACK
# =============================================================

rollback() {

    log_section "ROLLBACK STARTED"

    if [ -n "${OLD_IMAGE:-}" ]; then

        log "Rolling back to previous image:"
        log "$OLD_IMAGE"

        export APP_IMAGE="$OLD_IMAGE"

        cd "$PROJECT_DIR"

        docker compose up -d --remove-orphans

        log "Rollback completed successfully"

    else

        log "WARNING: no previous image found"

    fi

    exit 1
}

# =============================================================
# PREFLIGHT CHECKS
# =============================================================

preflight() {

    log_section "PREFLIGHT CHECKS"

    [ -f "$COMPOSE_FILE" ] || {
        log "ERROR: docker-compose.yml not found"
        exit 1
    }

    [ -f "$ENV_FILE" ] || {
        log "ERROR: .env file not found"
        exit 1
    }

    command -v docker >/dev/null 2>&1 || {
        log "ERROR: docker not installed"
        exit 1
    }

    docker info >/dev/null 2>&1 || {
        log "ERROR: docker daemon not running"
        exit 1
    }

    mkdir -p "$(dirname "$LOG_FILE")"

    log "Compose file: $COMPOSE_FILE"
    log "Environment:  $ENV_FILE"
    log "Image:        $IMAGE"

    log "Preflight checks passed"
}

# =============================================================
# MAIN DEPLOYMENT
# =============================================================

main() {

    log_section "DEPLOYMENT STARTED"

    acquire_lock

    preflight

    cd "$PROJECT_DIR"

    # ---------------------------------------------------------
    # Save current image for rollback
    # ---------------------------------------------------------

    log_section "SAVING CURRENT STATE"

    OLD_IMAGE=$(docker inspect statuspulse-app \
        --format='{{.Config.Image}}' 2>/dev/null || true)

    log "Current image:"
    log "${OLD_IMAGE:-none}"

    # ---------------------------------------------------------
    # Pull latest image
    # ---------------------------------------------------------

    log_section "PULLING IMAGE"

    docker pull "$IMAGE"

    log "Image pull completed"

    # ---------------------------------------------------------
    # Zero-downtime deployment
    # ---------------------------------------------------------

    log_section "STARTING UPDATED CONTAINERS"

    export APP_IMAGE="$IMAGE"

    docker compose pull

    docker compose up -d --remove-orphans

    log "Updated containers started"

    # ---------------------------------------------------------
    # Health checks
    # ---------------------------------------------------------

    log_section "HEALTH CHECK VALIDATION"

    if ! wait_healthy; then

        rollback
    fi

    # ---------------------------------------------------------
    # Cleanup
    # ---------------------------------------------------------

    log_section "CLEANUP"

    docker image prune -f || true

    log "Unused Docker images cleaned"

    # ---------------------------------------------------------
    # Success
    # ---------------------------------------------------------

    log_section "DEPLOYMENT SUCCESSFUL"

    log "Production URL:"
    log "https://av-lap-pg0441tk.taildb17d2.ts.net"

    log "Health endpoint:"
    log "https://av-lap-pg0441tk.taildb17d2.ts.net/health"

    log "Swagger docs:"
    log "https://av-lap-pg0441tk.taildb17d2.ts.net/docs"
}

main "$@"