#!/bin/bash

set -u

LOG_FILE="/var/log/statuspulse-monitor.log"

HEALTH_URL="${HEALTH_URL:-https://av-lap-pg0441tk.taildb17d2.ts.net/health}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"

DISK_THRESHOLD=80
MEMORY_THRESHOLD=90
TLS_EXPIRY_DAYS=14

EXPECTED_CONTAINERS=(
    "statuspulse-app"
    "statuspulse-postgres"
    "statuspulse-redis"
    "statuspulse-caddy"
    "statuspulse-uptime-kuma"
)

timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

log() {
    echo "[$(timestamp)] $1" | tee -a "$LOG_FILE"
}

send_alert() {
    local MESSAGE="$1"

    log "ALERT: $MESSAGE"

    if [ -z "$ALERT_WEBHOOK_URL" ]; then
        log "ALERT_WEBHOOK_URL not configured"
        return
    fi

    curl -s --max-time 10 -X POST "$ALERT_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"text\":\"$MESSAGE\"}" >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        log "Failed to send webhook alert"
    fi
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    if ! check_command "$1"; then
        log "Required command missing: $1"
        exit 1
    fi
}

check_health_endpoint() {
    log "Checking health endpoint"

    RESPONSE=$(curl -s --max-time 10 -w "HTTPSTATUS:%{http_code}" "$HEALTH_URL")
    
    if [ $? -ne 0 ]; then
        send_alert "Health endpoint request failed"
        return
    fi

    BODY=$(echo "$RESPONSE" | sed -e 's/HTTPSTATUS\:.*//g')
    STATUS=$(echo "$RESPONSE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

    if [ "$STATUS" != "200" ]; then
        send_alert "Health endpoint returned HTTP $STATUS"
        return
    fi

    echo "$BODY" | jq . >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        send_alert "Health endpoint returned invalid JSON"
        return
    fi

    log "Health endpoint OK"
}

check_disk_usage() {
    log "Checking disk usage"

    DISK_USAGE=$(df / | awk 'NR==2 {gsub("%",""); print $5}')

    if [ "$DISK_USAGE" -gt "$DISK_THRESHOLD" ]; then
        send_alert "Disk usage critical: ${DISK_USAGE}%"
    else
        log "Disk usage OK: ${DISK_USAGE}%"
    fi
}

check_memory_usage() {
    log "Checking memory usage"

    MEMORY_USAGE=$(free | awk '/Mem:/ {printf("%.0f"), $3/$2 * 100}')

    if [ "$MEMORY_USAGE" -gt "$MEMORY_THRESHOLD" ]; then
        send_alert "Memory usage critical: ${MEMORY_USAGE}%"
    else
        log "Memory usage OK: ${MEMORY_USAGE}%"
    fi
}

check_containers() {
    log "Checking Docker containers"

    for CONTAINER in "${EXPECTED_CONTAINERS[@]}"; do
        docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"

        if [ $? -ne 0 ]; then
            send_alert "Container not running: ${CONTAINER}"
        else
            log "Container running: ${CONTAINER}"
        fi
    done
}

check_tls_expiry() {
    log "Checking TLS certificate expiry"

    DOMAIN=$(echo "$HEALTH_URL" | awk -F[/:] '{print $4}')

    EXPIRY_DATE=$(echo | \
        openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | \
        openssl x509 -noout -enddate 2>/dev/null | \
        cut -d= -f2)

    if [ -z "$EXPIRY_DATE" ]; then
        send_alert "Unable to fetch TLS certificate expiry"
        return
    fi

    EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
    CURRENT_EPOCH=$(date +%s)

    DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

    if [ "$DAYS_LEFT" -lt "$TLS_EXPIRY_DAYS" ]; then
        send_alert "TLS certificate expires in ${DAYS_LEFT} days"
    else
        log "TLS certificate valid for ${DAYS_LEFT} days"
    fi
}

main() {

    require_command curl
    require_command jq
    require_command docker
    require_command openssl
    require_command df
    require_command free

    log "========================================"
    log "Starting health monitor"

    check_health_endpoint
    check_disk_usage
    check_memory_usage
    check_containers
    check_tls_expiry

    log "Health monitor completed"
}

main