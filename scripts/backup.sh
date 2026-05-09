#!/bin/bash
# =============================================================
# StatusPulse — PostgreSQL Backup Script
# scripts/backup.sh
#
# Usage:
#   bash ~/scripts/backup.sh
#
#   # With S3 upload
#   S3_BUCKET=my-bucket bash ~/scripts/backup.sh
#
#   # Custom retention
#   KEEP_BACKUPS=14 bash ~/scripts/backup.sh
#
# Cron (daily at 2 AM):
#   0 2 * * * bash /home/ubuntu/scripts/backup.sh >> /opt/statuspulse/backup.log 2>&1
# =============================================================

set -euo pipefail

# =============================================================
# CONFIG
# =============================================================
WORKDIR="${WORKDIR:-/opt/statuspulse}"
ENV_FILE="$WORKDIR/.env"
BACKUP_DIR="${BACKUP_DIR:-$WORKDIR/backups}"
LOG_FILE="${LOG_FILE:-$WORKDIR/backup.log}"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"

# PostgreSQL container name — must match docker-compose.yml
PG_CONTAINER="statuspulse-postgres"

# S3 settings — optional, only used if S3_BUCKET is set
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-statuspulse/backups}"
S3_REGION="${S3_REGION:-ap-south-1}"

# Filename with timestamp
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
BACKUP_FILENAME="statuspulse_db_${TIMESTAMP}.sql.gz"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"

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
# LOAD ENV — read DB credentials from .env file
# =============================================================
load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        log "ERROR: .env not found at $ENV_FILE"
        exit 1
    fi

    # Export only DB-related variables from .env
    set -a
    # shellcheck disable=SC1090
    source <(grep -E '^(DB_|POSTGRES_)' "$ENV_FILE" | sed 's/\r//')
    set +a

    # Validate required vars
    : "${DB_NAME:?DB_NAME not set in $ENV_FILE}"
    : "${DB_USER:?DB_USER not set in $ENV_FILE}"
    : "${DB_PASSWORD:?DB_PASSWORD not set in $ENV_FILE}"

    log "Loaded DB config: DB_NAME=$DB_NAME DB_USER=$DB_USER"
}

# =============================================================
# PREFLIGHT
# =============================================================
preflight() {
    log_section "PREFLIGHT"

    # Check docker is available
    command -v docker >/dev/null 2>&1 || {
        log "ERROR: docker not installed"
        exit 1
    }

    # Check postgres container is running
    RUNNING=$(docker inspect "$PG_CONTAINER" \
        --format='{{.State.Running}}' 2>/dev/null || echo "false")
    if [ "$RUNNING" != "true" ]; then
        log "ERROR: $PG_CONTAINER is not running"
        exit 1
    fi

    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"

    # Check S3 tools if S3 upload is requested
    if [ -n "$S3_BUCKET" ]; then
        command -v aws >/dev/null 2>&1 || {
            log "ERROR: aws CLI not installed but S3_BUCKET is set"
            log "Install: sudo apt install awscli -y"
            exit 1
        }
        log "S3 upload enabled: s3://$S3_BUCKET/$S3_PREFIX/"
    else
        log "S3 upload disabled (S3_BUCKET not set)"
    fi

    log "BACKUP_DIR:   $BACKUP_DIR"
    log "KEEP_BACKUPS: $KEEP_BACKUPS"
    log "Preflight passed"
}

# =============================================================
# DUMP — pg_dump inside the postgres container, pipe through gzip
# =============================================================
dump_database() {
    log_section "DATABASE DUMP"
    log "Starting dump: $BACKUP_FILENAME"

    # Run pg_dump inside the running postgres container
    # Output is piped through gzip for compression
    # PGPASSWORD env var avoids password prompt
    if docker exec \
        -e PGPASSWORD="$DB_PASSWORD" \
        "$PG_CONTAINER" \
        pg_dump \
            --username="$DB_USER" \
            --dbname="$DB_NAME" \
            --format=plain \
            --no-password \
        | gzip > "$BACKUP_PATH"; then

        # Verify file was actually created and has content
        if [ -s "$BACKUP_PATH" ]; then
            BACKUP_SIZE=$(du -sh "$BACKUP_PATH" | cut -f1)
            log "Dump complete: $BACKUP_PATH ($BACKUP_SIZE)"
        else
            log "ERROR: dump file is empty — something went wrong"
            rm -f "$BACKUP_PATH"
            exit 1
        fi
    else
        log "ERROR: pg_dump failed"
        rm -f "$BACKUP_PATH"
        exit 1
    fi
}

# =============================================================
# ROTATE — keep only last N backups, delete older ones
# =============================================================
rotate_backups() {
    log_section "ROTATING BACKUPS (keep last $KEEP_BACKUPS)"

    # List all backups sorted by date (oldest first)
    # Count how many exist
    BACKUP_COUNT=$(find "$BACKUP_DIR" \
        -maxdepth 1 \
        -name "statuspulse_db_*.sql.gz" \
        | wc -l)

    log "Current backup count: $BACKUP_COUNT"

    if [ "$BACKUP_COUNT" -le "$KEEP_BACKUPS" ]; then
        log "No rotation needed ($BACKUP_COUNT <= $KEEP_BACKUPS)"
        return 0
    fi

    # How many to delete
    DELETE_COUNT=$(( BACKUP_COUNT - KEEP_BACKUPS ))
    log "Deleting $DELETE_COUNT old backup(s)..."

    # Find oldest backups and delete them
    find "$BACKUP_DIR" \
        -maxdepth 1 \
        -name "statuspulse_db_*.sql.gz" \
        | sort \
        | head -n "$DELETE_COUNT" \
        | while read -r OLD_BACKUP; do
            log "Deleting: $(basename "$OLD_BACKUP")"
            rm -f "$OLD_BACKUP"
        done

    REMAINING=$(find "$BACKUP_DIR" \
        -maxdepth 1 \
        -name "statuspulse_db_*.sql.gz" \
        | wc -l)
    log "Remaining backups: $REMAINING"
}

# =============================================================
# S3 UPLOAD — only runs if S3_BUCKET is set
# =============================================================
upload_to_s3() {
    if [ -z "$S3_BUCKET" ]; then
        return 0
    fi

    log_section "S3 UPLOAD"

    S3_PATH="s3://$S3_BUCKET/$S3_PREFIX/$BACKUP_FILENAME"
    log "Uploading to: $S3_PATH"

    if aws s3 cp "$BACKUP_PATH" "$S3_PATH" \
        --region "$S3_REGION" \
        --storage-class STANDARD_IA; then
        log "S3 upload successful: $S3_PATH"
    else
        log "ERROR: S3 upload failed — local backup still kept"
        # Don't exit — local backup is still good
    fi

    # Also rotate S3 backups — delete ones older than KEEP_BACKUPS
    log "Rotating S3 backups..."
    aws s3 ls "s3://$S3_BUCKET/$S3_PREFIX/" \
        --region "$S3_REGION" \
        | grep "statuspulse_db_" \
        | sort \
        | head -n -"$KEEP_BACKUPS" \
        | awk '{print $4}' \
        | while read -r OLD_S3_FILE; do
            OLD_S3_PATH="s3://$S3_BUCKET/$S3_PREFIX/$OLD_S3_FILE"
            log "Deleting from S3: $OLD_S3_FILE"
            aws s3 rm "$OLD_S3_PATH" --region "$S3_REGION"
        done
}

# =============================================================
# SUMMARY — list all current backups
# =============================================================
show_summary() {
    log_section "BACKUP SUMMARY"
    log "Backups in $BACKUP_DIR:"

    find "$BACKUP_DIR" \
        -maxdepth 1 \
        -name "statuspulse_db_*.sql.gz" \
        | sort \
        | while read -r f; do
            SIZE=$(du -sh "$f" | cut -f1)
            log "  $(basename "$f")  ($SIZE)"
        done
}

# =============================================================
# MAIN
# =============================================================
main() {
    log_section "BACKUP STARTED"
    log "Timestamp: $TIMESTAMP"

    load_env
    preflight
    dump_database
    rotate_backups
    upload_to_s3
    show_summary

    log_section "BACKUP COMPLETE"
    log "File:     $BACKUP_PATH"
    log "Log:      $LOG_FILE"
}

main "$@"