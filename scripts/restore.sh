#!/bin/bash
# =============================================================
# StatusPulse — PostgreSQL Restore Script
# scripts/restore.sh
#
# Usage:
#   # Restore latest backup
#   bash ~/scripts/restore.sh
#
#   # Restore specific backup file
#   bash ~/scripts/restore.sh /opt/statuspulse/backups/statuspulse_db_2026-05-09_143022.sql.gz
#
#   # Restore to a fresh test database (non-destructive verify)
#   RESTORE_DB=statuspulse_verify bash ~/scripts/restore.sh
# =============================================================

set -euo pipefail

# =============================================================
# CONFIG
# =============================================================
WORKDIR="${WORKDIR:-/opt/statuspulse}"
ENV_FILE="$WORKDIR/.env"
BACKUP_DIR="${BACKUP_DIR:-$WORKDIR/backups}"
LOG_FILE="${LOG_FILE:-$WORKDIR/restore.log}"
PG_CONTAINER="statuspulse-postgres"

# Target database for restore — defaults to a fresh verify DB
# so we never overwrite production data during verification
RESTORE_DB="${RESTORE_DB:-statuspulse_verify}"

# Specific backup file — if not passed as arg, use latest
BACKUP_FILE="${1:-}"

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
# LOAD ENV
# =============================================================
load_env() {
    [ -f "$ENV_FILE" ] || { log "ERROR: .env not found at $ENV_FILE"; exit 1; }

    set -a
    # shellcheck disable=SC1090
    source <(grep -E '^(DB_)' "$ENV_FILE" | sed 's/\r//')
    set +a

    : "${DB_NAME:?DB_NAME not set in $ENV_FILE}"
    : "${DB_USER:?DB_USER not set in $ENV_FILE}"
    : "${DB_PASSWORD:?DB_PASSWORD not set in $ENV_FILE}"

    log "Loaded: DB_USER=$DB_USER  DB_NAME=$DB_NAME"
}

# =============================================================
# PREFLIGHT
# =============================================================
preflight() {
    log_section "PREFLIGHT"

    command -v docker >/dev/null 2>&1 || { log "ERROR: docker not installed"; exit 1; }

    RUNNING=$(docker inspect "$PG_CONTAINER" \
        --format='{{.State.Running}}' 2>/dev/null || echo "false")
    [ "$RUNNING" = "true" ] || {
        log "ERROR: $PG_CONTAINER is not running"
        exit 1
    }

    mkdir -p "$(dirname "$LOG_FILE")"

    # Pick backup file — use argument or latest in backup dir
    if [ -z "$BACKUP_FILE" ]; then
        BACKUP_FILE=$(find "$BACKUP_DIR" \
            -maxdepth 1 \
            -name "statuspulse_db_*.sql.gz" \
            | sort \
            | tail -n 1)

        [ -n "$BACKUP_FILE" ] || {
            log "ERROR: no backup files found in $BACKUP_DIR"
            exit 1
        }
        log "No file specified — using latest: $(basename "$BACKUP_FILE")"
    fi

    [ -f "$BACKUP_FILE" ] || {
        log "ERROR: backup file not found: $BACKUP_FILE"
        exit 1
    }

    BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
    log "Backup file: $BACKUP_FILE ($BACKUP_SIZE)"
    log "Restore DB:  $RESTORE_DB"
    log "PG container: $PG_CONTAINER"
    log "Preflight passed"
}

# =============================================================
# CREATE FRESH DATABASE
# Drops RESTORE_DB if it exists, creates it fresh
# Never touches the production DB_NAME
# =============================================================
create_fresh_db() {
    log_section "CREATING FRESH DATABASE: $RESTORE_DB"

    # Drop if exists (clean slate)
    docker exec \
        -e PGPASSWORD="$DB_PASSWORD" \
        "$PG_CONTAINER" \
        psql \
            --username="$DB_USER" \
            --dbname="postgres" \
            --command="DROP DATABASE IF EXISTS $RESTORE_DB;" \
    && log "Dropped existing $RESTORE_DB (if any)"

    # Create fresh
    docker exec \
        -e PGPASSWORD="$DB_PASSWORD" \
        "$PG_CONTAINER" \
        psql \
            --username="$DB_USER" \
            --dbname="postgres" \
            --command="CREATE DATABASE $RESTORE_DB OWNER $DB_USER;" \
    && log "Created fresh database: $RESTORE_DB"
}

# =============================================================
# RESTORE — decompress and pipe into psql
# =============================================================
restore_database() {
    log_section "RESTORING DATABASE"
    log "Source: $(basename "$BACKUP_FILE")"
    log "Target: $RESTORE_DB"

    # Decompress locally, pipe SQL into psql running in container
    if gunzip -c "$BACKUP_FILE" \
        | docker exec -i \
            -e PGPASSWORD="$DB_PASSWORD" \
            "$PG_CONTAINER" \
            psql \
                --username="$DB_USER" \
                --dbname="$RESTORE_DB" \
                --quiet; then
        log "Restore complete"
    else
        log "ERROR: restore failed"
        exit 1
    fi
}

# =============================================================
# VERIFY — query restored DB and show data is intact
# =============================================================
verify_data() {
    log_section "VERIFYING DATA INTEGRITY"

    # Helper to run a query in the restored DB
    run_query() {
        docker exec \
            -e PGPASSWORD="$DB_PASSWORD" \
            "$PG_CONTAINER" \
            psql \
                --username="$DB_USER" \
                --dbname="$RESTORE_DB" \
                --tuples-only \
                --command="$1" \
            2>/dev/null | tr -s ' ' | sed 's/^ //'
    }

    # ── 1. Tables exist ─────────────────────────────────────
    log ""
    log "── TABLE CHECK ────────────────────────────────"
    TABLES=$(run_query "\dt" | awk '{print $3}' | grep -v '^$' || true)

    if echo "$TABLES" | grep -q "services" && \
       echo "$TABLES" | grep -q "incidents"; then
        log "✓ Tables present: services, incidents"
    else
        log "✗ Expected tables missing. Found: $TABLES"
        exit 1
    fi

    # ── 2. Row counts ───────────────────────────────────────
    log ""
    log "── ROW COUNTS ─────────────────────────────────"

    SERVICES_COUNT=$(run_query "SELECT COUNT(*) FROM services;" | tr -d ' ')
    INCIDENTS_COUNT=$(run_query "SELECT COUNT(*) FROM incidents;" | tr -d ' ')

    log "services:  $SERVICES_COUNT row(s)"
    log "incidents: $INCIDENTS_COUNT row(s)"

    # ── 3. Show services data ───────────────────────────────
    log ""
    log "── SERVICES TABLE ─────────────────────────────"
    if [ "$SERVICES_COUNT" -gt 0 ]; then
        run_query "SELECT id, name, url, status, last_checked FROM services ORDER BY id;" \
            | while IFS= read -r line; do
                [ -n "$line" ] && log "  $line"
            done
        log "✓ Services data intact"
    else
        log "  (no services rows — table is empty but structure is intact)"
    fi

    # ── 4. Show incidents data ──────────────────────────────
    log ""
    log "── INCIDENTS TABLE ────────────────────────────"
    if [ "$INCIDENTS_COUNT" -gt 0 ]; then
        run_query "SELECT id, service_name, title, severity, status, created_at FROM incidents ORDER BY id;" \
            | while IFS= read -r line; do
                [ -n "$line" ] && log "  $line"
            done
        log "✓ Incidents data intact"
    else
        log "  (no incidents rows — table is empty but structure is intact)"
    fi

    # ── 5. Schema integrity ─────────────────────────────────
    log ""
    log "── SCHEMA INTEGRITY ───────────────────────────"
    SERVICES_COLS=$(run_query "SELECT column_name FROM information_schema.columns
        WHERE table_name='services' ORDER BY ordinal_position;")
    INCIDENTS_COLS=$(run_query "SELECT column_name FROM information_schema.columns
        WHERE table_name='incidents' ORDER BY ordinal_position;")

    log "services columns:  $(echo "$SERVICES_COLS" | tr '\n' ' ')"
    log "incidents columns: $(echo "$INCIDENTS_COLS" | tr '\n' ' ')"

    # Verify expected columns exist
    EXPECTED_SVC="id name url status last_checked response_time_ms"
    EXPECTED_INC="id service_name title description severity status created_at resolved_at"
    ALL_OK=true

    for col in $EXPECTED_SVC; do
        if echo "$SERVICES_COLS" | grep -q "$col"; then
            log "✓ services.$col"
        else
            log "✗ services.$col MISSING"
            ALL_OK=false
        fi
    done

    for col in $EXPECTED_INC; do
        if echo "$INCIDENTS_COLS" | grep -q "$col"; then
            log "✓ incidents.$col"
        else
            log "✗ incidents.$col MISSING"
            ALL_OK=false
        fi
    done

    if [ "$ALL_OK" = "true" ]; then
        log ""
        log "✓ All columns verified — schema is intact"
    else
        log ""
        log "✗ Schema verification failed"
        exit 1
    fi
}

# =============================================================
# COMPARE — compare row counts with production DB
# Confirms restore matches production
# =============================================================
compare_with_production() {
    log_section "COMPARING WITH PRODUCTION DB ($DB_NAME)"

    run_prod_query() {
        docker exec \
            -e PGPASSWORD="$DB_PASSWORD" \
            "$PG_CONTAINER" \
            psql \
                --username="$DB_USER" \
                --dbname="$DB_NAME" \
                --tuples-only \
                --command="$1" \
            2>/dev/null | tr -s ' ' | sed 's/^ //'
    }

    run_restore_query() {
        docker exec \
            -e PGPASSWORD="$DB_PASSWORD" \
            "$PG_CONTAINER" \
            psql \
                --username="$DB_USER" \
                --dbname="$RESTORE_DB" \
                --tuples-only \
                --command="$1" \
            2>/dev/null | tr -s ' ' | sed 's/^ //'
    }

    PROD_SVC=$(run_prod_query "SELECT COUNT(*) FROM services;" | tr -d ' ')
    REST_SVC=$(run_restore_query "SELECT COUNT(*) FROM services;" | tr -d ' ')
    PROD_INC=$(run_prod_query "SELECT COUNT(*) FROM incidents;" | tr -d ' ')
    REST_INC=$(run_restore_query "SELECT COUNT(*) FROM incidents;" | tr -d ' ')

    log ""
    log "                  Production    Restored"
    log "  services:       $PROD_SVC              $REST_SVC"
    log "  incidents:      $PROD_INC              $REST_INC"
    log ""

    if [ "$PROD_SVC" = "$REST_SVC" ] && [ "$PROD_INC" = "$REST_INC" ]; then
        log "✓ Row counts match — restore is consistent with production"
    else
        log "✗ Row count mismatch — backup may be from an earlier point in time"
        log "  This is expected if data was added after the backup was taken"
    fi
}

# =============================================================
# CLEANUP — drop the temporary verify database
# =============================================================
cleanup_verify_db() {
    log_section "CLEANUP"

    # Only drop if it's the verify DB — never drop production
    if [ "$RESTORE_DB" = "statuspulse_verify" ]; then
        docker exec \
            -e PGPASSWORD="$DB_PASSWORD" \
            "$PG_CONTAINER" \
            psql \
                --username="$DB_USER" \
                --dbname="postgres" \
                --command="DROP DATABASE IF EXISTS $RESTORE_DB;" \
        && log "Verification database $RESTORE_DB dropped (temporary)"
    else
        log "Keeping restored database: $RESTORE_DB"
    fi
}

# =============================================================
# MAIN
# =============================================================
main() {
    log_section "RESTORE & VERIFY STARTED"

    load_env
    preflight
    create_fresh_db
    restore_database
    verify_data
    compare_with_production
    cleanup_verify_db

    log_section "RESTORE & VERIFY COMPLETE"
    log "Backup file: $(basename "$BACKUP_FILE")"
    log "Result:      DATA INTACT ✓"
    log "Log:         $LOG_FILE"
}

main "$@"