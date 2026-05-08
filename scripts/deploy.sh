#!/bin/bash
# =============================================================
# StatusPulse — Server Deployment Script
# scripts/deploy.sh
#
# Usage:
#   bash deploy.sh
#   APP_IMAGE=ghcr.io/user/repo:sha bash deploy.sh
#
# What it does:
#   1. Pull latest image from ghcr.io
#   2. Zero-downtime deploy: start new → health check → stop old
#   3. Rollback automatically if health check fails
#   4. Log all actions with timestamps
#   5. Idempotent — safe to run repeatedly
# =============================================================

set -euo pipefail

# =============================================================
# CONFIG — override any of these via environment variables
# =============================================================
IMAGE="${APP_IMAGE:-ghcr.io/vipin0102/statuspulse/statuspulse:latest}"
CONTAINER_NAME="statuspulse-app"
NEW_CONTAINER="statuspulse-app-new"
NETWORK="statuspulse_statuspulse-network"
ENV_FILE="${ENV_FILE:-$HOME/statuspulse/app/.env}"
LOG_FILE="${LOG_FILE:-$HOME/statuspulse/deploy.log}"
LOCK_FILE="/tmp/statuspulse-deploy.lock"
HEALTH_URL="${HEALTH_URL:-http://localhost:8000/health}"
NEW_HEALTH_URL="http://localhost:8001/health"
MAX_RETRIES=20
RETRY_INTERVAL=5

# =============================================================
# LOGGING — every line timestamped, written to file + stdout
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
# IDEMPOTENCY LOCK — prevents concurrent deploys
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
# HEALTH CHECK — polls URL until 200+healthy or times out
# =============================================================
wait_healthy() {
    local url="$1"
    local label="${2:-app}"

    log "Health check: $label ($url)"
    log "Retrying up to $MAX_RETRIES times every ${RETRY_INTERVAL}s..."

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
# ROLLBACK — restore old container if new one fails
# =============================================================
rollback() {
    log_section "ROLLBACK"

    # Remove the failed new container
    log "Removing failed new container..."
    docker stop "$NEW_CONTAINER" 2>/dev/null || true
    docker rm   "$NEW_CONTAINER" 2>/dev/null || true

    # Restore old container if it was stopped
    if [ -n "${OLD_IMAGE:-}" ]; then
        if ! docker ps -q -f name="^${CONTAINER_NAME}$" | grep -q .; then
            log "Restoring old container from image: $OLD_IMAGE"
            docker run -d \
                --name "$CONTAINER_NAME" \
                --network "$NETWORK" \
                -p 8000:8000 \
                --env-file "$ENV_FILE" \
                --restart unless-stopped \
                "$OLD_IMAGE"
            log "Old container restored on port 8000"
        else
            log "Old container still running — no restore needed"
        fi
    else
        log "WARNING: no previous image to restore — app may be down"
    fi

    log "Rollback complete"
    exit 1
}

# =============================================================
# PREFLIGHT — validate environment before doing anything
# =============================================================
preflight() {
    log_section "PREFLIGHT"

    [ -f "$ENV_FILE" ] || { log "ERROR: .env not found at $ENV_FILE"; exit 1; }

    command -v docker >/dev/null 2>&1 || { log "ERROR: docker not installed"; exit 1; }

    docker network inspect "$NETWORK" >/dev/null 2>&1 || {
        log "ERROR: Docker network '$NETWORK' not found"
        log "Make sure postgres and redis are running via docker compose first"
        exit 1
    }

    mkdir -p "$(dirname "$LOG_FILE")"

    log "ENV_FILE:  $ENV_FILE"
    log "IMAGE:     $IMAGE"
    log "NETWORK:   $NETWORK"
    log "LOG_FILE:  $LOG_FILE"
    log "Preflight passed"
}

# =============================================================
# MAIN
# =============================================================
main() {
    log_section "DEPLOYMENT STARTED"

    acquire_lock
    preflight

    # ----------------------------------------------------------
    # 1. Save current image for rollback
    # ----------------------------------------------------------
    log_section "SAVING CURRENT STATE"
    OLD_IMAGE=$(docker inspect "$CONTAINER_NAME" \
        --format='{{.Config.Image}}' 2>/dev/null || true)
    log "Current image: ${OLD_IMAGE:-none (first deploy)}"

    # ----------------------------------------------------------
    # 2. Pull latest image from ghcr.io
    # ----------------------------------------------------------
    log_section "PULLING IMAGE"
    log "Pulling: $IMAGE"
    if ! docker pull "$IMAGE"; then
        log "ERROR: failed to pull image $IMAGE"
        exit 1
    fi
    log "Pull complete"

    # ----------------------------------------------------------
    # 3. Zero-downtime: START NEW container on port 8001
    #    Old container keeps serving on 8000 during this step
    # ----------------------------------------------------------
    log_section "STARTING NEW CONTAINER"

    # Clean up any leftover new container from a previous failed run
    # (this is what makes the script idempotent)
    if docker inspect "$NEW_CONTAINER" >/dev/null 2>&1; then
        log "Removing leftover container from previous run: $NEW_CONTAINER"
        docker stop "$NEW_CONTAINER" 2>/dev/null || true
        docker rm   "$NEW_CONTAINER" 2>/dev/null || true
    fi

    docker run -d \
        --name "$NEW_CONTAINER" \
        --network "$NETWORK" \
        -p 8001:8000 \
        --env-file "$ENV_FILE" \
        --restart no \
        "$IMAGE"

    log "New container started on port 8001 (old still on 8000)"

    # ----------------------------------------------------------
    # 4. Health check the NEW container on port 8001
    #    Old container still serving — no downtime yet
    # ----------------------------------------------------------
    log_section "HEALTH CHECK — NEW CONTAINER (:8001)"

    if ! wait_healthy "$NEW_HEALTH_URL" "new container"; then
        log "ERROR: new container failed health check"
        rollback
    fi

    # ----------------------------------------------------------
    # 5. Stop OLD container → switch NEW to port 8000
    #    This is the only moment of potential downtime (~1-2s)
    # ----------------------------------------------------------
    log_section "CUTOVER"

    log "Stopping old container: $CONTAINER_NAME"
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm   "$CONTAINER_NAME" 2>/dev/null || true
    log "Old container removed"

    log "Stopping new container to re-map to port 8000..."
    docker stop "$NEW_CONTAINER"
    docker rm   "$NEW_CONTAINER"

    log "Starting new container on production port 8000..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --network "$NETWORK" \
        -p 8000:8000 \
        --env-file "$ENV_FILE" \
        --restart unless-stopped \
        "$IMAGE"

    log "New container running on port 8000"

    # ----------------------------------------------------------
    # 6. Final health check on production port 8000
    # ----------------------------------------------------------
    log_section "HEALTH CHECK — PRODUCTION (:8000)"

    if ! wait_healthy "$HEALTH_URL" "production"; then
        log "ERROR: production health check failed — rolling back"
        rollback
    fi

    # ----------------------------------------------------------
    # 7. Cleanup — remove old image to save disk space
    # ----------------------------------------------------------
    log_section "CLEANUP"
    docker image prune -f 2>/dev/null || true
    log "Old images pruned"

    # ----------------------------------------------------------
    # Done
    # ----------------------------------------------------------
    log_section "DEPLOYMENT SUCCESSFUL"
    log "Deployed image:   $IMAGE"
    log "Replaced image:   ${OLD_IMAGE:-none}"
    log "Container:        $CONTAINER_NAME"
}

main "$@"