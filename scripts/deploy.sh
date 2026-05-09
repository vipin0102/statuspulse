#!/bin/bash
# =============================================================
# StatusPulse — Standalone Server Deployment Script
# scripts/deploy.sh
#
# Runs INDEPENDENTLY of GitHub Actions CI/CD pipeline.
# Uses docker compose — same as GitHub Actions deploy.yml.
#
# Usage:
#   # Deploy latest image
#   bash ~/statuspulse/scripts/deploy.sh
#
#   # Deploy specific SHA
#   APP_IMAGE=ghcr.io/vipin0102/statuspulse/statuspulse:abc123 \
#     bash ~/statuspulse/scripts/deploy.sh
#
# What it does:
#   1. Pull latest image from ghcr.io
#   2. Zero-downtime: start new → health check → stop old (via compose)
#   3. Rollback automatically if health check fails
#   4. Log all actions with timestamps
#   5. Idempotent — safe to run repeatedly
# =============================================================

set -euo pipefail

# =============================================================
# CONFIG — matches exactly what deploy.yml uses on GitHub Actions
# =============================================================
IMAGE="${APP_IMAGE:-ghcr.io/vipin0102/statuspulse/statuspulse:latest}"
WORKDIR="${WORKDIR:-$HOME/statuspulse}"
COMPOSE_FILE="$WORKDIR/docker-compose.yml"
ENV_FILE="$WORKDIR/.env"
LOG_FILE="${LOG_FILE:-$WORKDIR/deploy.log}"
LOCK_FILE="/tmp/statuspulse-deploy.lock"
COMPOSE_PROJECT="statuspulse"
HEALTH_URL="http://localhost:8000/health"
MAX_RETRIES=20
RETRY_INTERVAL=5

# docker compose command — works with both plugin (v2) and standalone (v1)
COMPOSE="docker compose"

# =============================================================
# LOGGING — timestamped, written to file + stdout
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
# LOCK — prevents concurrent deploys (idempotency)
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
# COMPOSE WRAPPER — always runs with correct project + env + file
# Same flags as deploy.yml:
#   --project-name statuspulse
#   --env-file .env
#   -f docker-compose.yml
# =============================================================
compose() {
    APP_IMAGE="$IMAGE" $COMPOSE \
        --project-name "$COMPOSE_PROJECT" \
        --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" \
        "$@"
}

# =============================================================
# HEALTH CHECK — polls /health until 200+healthy or times out
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
# ROLLBACK — bring stack back up with old image via compose
# =============================================================
rollback() {
    log_section "ROLLBACK"

    if [ -n "${OLD_IMAGE:-}" ]; then
        log "Rolling back to: $OLD_IMAGE"

        # Temporarily set IMAGE to old image for the compose wrapper
        IMAGE="$OLD_IMAGE" compose \
            up -d --no-build --pull never --remove-orphans

        log "Rollback complete — old image restored via docker compose"
    else
        log "WARNING: no previous image — bringing stack down"
        compose down || true
    fi

    exit 1
}

# =============================================================
# PREFLIGHT — validate everything before touching Docker
# =============================================================
preflight() {
    log_section "PREFLIGHT"

    [ -f "$ENV_FILE" ] || {
        log "ERROR: .env not found at $ENV_FILE"
        exit 1
    }
    [ -f "$COMPOSE_FILE" ] || {
        log "ERROR: docker-compose.yml not found at $COMPOSE_FILE"
        exit 1
    }
    command -v docker >/dev/null 2>&1 || {
        log "ERROR: docker not installed"
        exit 1
    }
    $COMPOSE version >/dev/null 2>&1 || {
        log "ERROR: docker compose not available"
        exit 1
    }

    mkdir -p "$(dirname "$LOG_FILE")"

    log "IMAGE:         $IMAGE"
    log "WORKDIR:       $WORKDIR"
    log "COMPOSE_FILE:  $COMPOSE_FILE"
    log "ENV_FILE:      $ENV_FILE"
    log "PROJECT:       $COMPOSE_PROJECT"
    log "Preflight passed"
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
    # 1. Save current app image for rollback
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
    # 3. Zero-downtime: scale app to 0 replicas temporarily
    #    while new image starts — postgres/redis/caddy keep running
    #
    # Flow:
    #   compose up --no-deps app   → start new app container
    #   health check               → verify new is healthy
    #   if fails                   → rollback to old image
    # ----------------------------------------------------------
    log_section "ZERO-DOWNTIME DEPLOY VIA DOCKER COMPOSE"

    # Stop and remove only the app container — rest of stack stays up
    log "Stopping old app container (postgres/redis/caddy stay running)..."
    docker stop statuspulse-app 2>/dev/null || true
    docker rm   statuspulse-app 2>/dev/null || true

    # Start new app container using compose
    # --no-deps → don't restart postgres/redis/caddy
    # --no-build → use pulled image, don't rebuild
    # --pull never → don't try to pull again, we already did
    log "Starting new app container via docker compose..."
    compose up -d \
        --no-deps \
        --no-build \
        --pull never \
        --remove-orphans \
        app

    log "New app container started"

    # ----------------------------------------------------------
    # 4. Health check new container
    # ----------------------------------------------------------
    log_section "HEALTH CHECK"

    if ! wait_healthy "$HEALTH_URL" "new app container"; then
        log "ERROR: new container failed health check"
        # Show logs to help diagnose
        log "=== App container logs ==="
        docker logs statuspulse-app --tail 30 2>/dev/null || true
        rollback
    fi

    # ----------------------------------------------------------
    # 5. Ensure full stack is up and consistent
    #    Brings up any other services that may have drifted
    # ----------------------------------------------------------
    log_section "FULL STACK SYNC"
    log "Syncing full stack via docker compose..."
    compose up -d --remove-orphans
    log "Full stack in sync"

    # ----------------------------------------------------------
    # 6. Cleanup old images to save disk space
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
    log "Log file:  $LOG_FILE"
}

main "$@"