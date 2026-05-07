#!/bin/bash

set -e

BASE_URL="http://localhost:8000"

pass() {
    echo "✅ PASS - $1"
}

fail() {
    echo "❌ FAIL - $1"
    exit 1
}

echo "==============================="
echo "Running Integration Tests"
echo "==============================="

# ==========================================
# Test /health
# ==========================================
echo "Testing GET /health"

HEALTH_RESPONSE=$(curl -s -w "\n%{http_code}" $BASE_URL/health)

HEALTH_BODY=$(echo "$HEALTH_RESPONSE" | head -n 1)
HEALTH_CODE=$(echo "$HEALTH_RESPONSE" | tail -n 1)

if [ "$HEALTH_CODE" != "200" ]; then
    fail "/health status code"
fi

echo "$HEALTH_BODY" | grep '"status"' >/dev/null || fail "/health JSON structure"

pass "GET /health"

# ==========================================
# Test POST /services
# ==========================================
echo "Testing POST /services"

SERVICE_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{
        "name":"test-service",
        "url":"https://example.com"
    }' \
    $BASE_URL/services)

SERVICE_BODY=$(echo "$SERVICE_RESPONSE" | head -n 1)
SERVICE_CODE=$(echo "$SERVICE_RESPONSE" | tail -n 1)

if [ "$SERVICE_CODE" != "200" ]; then
    fail "POST /services"
fi

echo "$SERVICE_BODY" | grep '"id"' >/dev/null || fail "POST /services JSON"

pass "POST /services"

# ==========================================
# Duplicate Service Test
# ==========================================
echo "Testing duplicate POST /services"

DUPLICATE_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{
        "name":"test-service",
        "url":"https://example.com"
    }' \
    $BASE_URL/services)

DUPLICATE_CODE=$(echo "$DUPLICATE_RESPONSE" | tail -n 1)

if [ "$DUPLICATE_CODE" != "409" ]; then
    fail "Duplicate service check"
fi

pass "Duplicate service returns 409"

# ==========================================
# GET /services
# ==========================================
echo "Testing GET /services"

SERVICES_RESPONSE=$(curl -s -w "\n%{http_code}" \
    $BASE_URL/services)

SERVICES_BODY=$(echo "$SERVICES_RESPONSE" | head -n 1)
SERVICES_CODE=$(echo "$SERVICES_RESPONSE" | tail -n 1)

if [ "$SERVICES_CODE" != "200" ]; then
    fail "GET /services"
fi

echo "$SERVICES_BODY" | grep 'test-service' >/dev/null || fail "GET /services JSON"

pass "GET /services"

# ==========================================
# POST /incidents
# ==========================================
echo "Testing POST /incidents"

INCIDENT_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{
        "service_name":"test-service",
        "title":"Database outage",
        "description":"Connection timeout",
        "severity":"critical"
    }' \
    $BASE_URL/incidents)

INCIDENT_BODY=$(echo "$INCIDENT_RESPONSE" | head -n 1)
INCIDENT_CODE=$(echo "$INCIDENT_RESPONSE" | tail -n 1)

if [ "$INCIDENT_CODE" != "200" ]; then
    fail "POST /incidents"
fi

echo "$INCIDENT_BODY" | grep '"id"' >/dev/null || fail "POST /incidents JSON"

pass "POST /incidents"

# ==========================================
# GET /incidents
# ==========================================
echo "Testing GET /incidents"

INCIDENTS_RESPONSE=$(curl -s -w "\n%{http_code}" \
    $BASE_URL/incidents)

INCIDENTS_BODY=$(echo "$INCIDENTS_RESPONSE" | head -n 1)
INCIDENTS_CODE=$(echo "$INCIDENTS_RESPONSE" | tail -n 1)

if [ "$INCIDENTS_CODE" != "200" ]; then
    fail "GET /incidents"
fi

echo "$INCIDENTS_BODY" | grep 'Database outage' >/dev/null || fail "GET /incidents JSON"

pass "GET /incidents"

echo "==============================="
echo "🎉 ALL TESTS PASSED"
echo "==============================="