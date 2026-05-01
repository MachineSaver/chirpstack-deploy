#!/usr/bin/env bash
# Provision Machine Saver AirVibe device profiles into a running ChirpStack instance.
# Reads .env for credentials and region. Safe to re-run — skips existing profiles.
#
# Creates two profiles for the active LORA_REGION:
#   AirVibe <REGION>       — Class C (normal operation)
#   AirVibe <REGION> FUOTA — Class A (firmware update sessions)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}  ▸ $*${NC}"; }
success() { echo -e "${GREEN}  ✔ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
error()   { echo -e "${RED}  ✘ $*${NC}" >&2; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
for cmd in curl docker jq; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Required tool not found: $cmd"
        echo "  Install or enable it, then re-run this script."
        exit 1
    fi
done

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="$REPO_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    error ".env not found at $ENV_FILE — run setup.sh first."
    exit 1
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ── Codec ─────────────────────────────────────────────────────────────────────
CODEC_FILE="$REPO_DIR/assets/AirVibe_TS013_Codec_v2.1.2.js"
if [[ ! -f "$CODEC_FILE" ]]; then
    error "Codec file not found: $CODEC_FILE"
    exit 1
fi

# ── API base URL ──────────────────────────────────────────────────────────────
# ChirpStack is not exposed directly — reach it through Nginx.
# In VPS (SSL) mode, call the real domain; in local mode, call localhost.
if [[ "${SSL_ENABLED:-false}" == "true" ]]; then
    _port="${HTTPS_PORT:-443}"
    if [[ "$_port" == "443" ]]; then
        API_BASE="https://${DOMAIN}/api"
    else
        API_BASE="https://${DOMAIN}:${_port}/api"
    fi
else
    API_BASE="http://127.0.0.1:${HTTP_PORT:-80}/api"
fi

# ── Authenticate ──────────────────────────────────────────────────────────────
info "Authenticating with ChirpStack API at ${API_BASE}..."
API_KEY="${CHIRPSTACK_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    API_KEY=$(docker compose exec -T chirpstack \
        chirpstack -c /etc/chirpstack create-api-key \
        --name "provision-devices-$(date -u +%Y%m%d%H%M%S)" | \
        awk -F': ' '/^token: /{print $2; exit}')
fi

if [[ -z "$API_KEY" ]]; then
    error "No API key returned. Check that ChirpStack is running and Docker access works."
    exit 1
fi
success "Authenticated with API key"

AUTH_HEADERS=(-H "Grpc-Metadata-Authorization: Bearer $API_KEY" -H "Content-Type: application/json")

# ── Get default tenant ID ─────────────────────────────────────────────────────
info "Fetching tenant..."
TENANT_ID=$(curl -sf "${AUTH_HEADERS[@]}" \
    "${API_BASE}/tenants?limit=1" | jq -r '.result[0].id // empty')
if [[ -z "$TENANT_ID" ]]; then
    error "No tenant found in ChirpStack."
    exit 1
fi
success "Tenant: $TENANT_ID"

# ── Fetch existing profile names (for idempotency) ────────────────────────────
EXISTING_NAMES=$(curl -sf "${AUTH_HEADERS[@]}" \
    "${API_BASE}/device-profiles?tenantId=${TENANT_ID}&limit=100" | \
    jq -r '[.result[].name]')

profile_exists() {
    echo "$EXISTING_NAMES" | jq -e --arg n "$1" 'index($n) != null' &>/dev/null
}

# ── Create a device profile ───────────────────────────────────────────────────
create_profile() {
    local name="$1"
    local description="$2"
    local supports_class_c="$3"   # JSON boolean: true or false

    if profile_exists "$name"; then
        info "Already exists, skipping: ${name}"
        return 0
    fi

    local payload
    payload=$(jq -n \
        --arg  tid   "$TENANT_ID" \
        --arg  name  "$name" \
        --arg  desc  "$description" \
        --arg  rgn   "$LORA_REGION" \
        --argjson cc  "$supports_class_c" \
        --rawfile codec "$CODEC_FILE" \
        '{deviceProfile:{
            tenantId:               $tid,
            name:                   $name,
            description:            $desc,
            region:                 $rgn,
            macVersion:             "LORAWAN_1_0_4",
            regParamsRevision:      "RP002_1_0_3",
            adrAlgorithmId:         "default",
            payloadCodecRuntime:    "JS",
            payloadCodecScript:     $codec,
            flushQueueOnActivate:   true,
            uplinkInterval:         0,
            deviceStatusReqInterval:1,
            supportsOtaa:           true,
            supportsClassB:         false,
            supportsClassC:         $cc,
            classCTimeout:          0
        }}')

    curl -sf "${AUTH_HEADERS[@]}" \
        -d "$payload" \
        "${API_BASE}/device-profiles" >/dev/null || {
        error "Failed to create profile: $name"
        return 1
    }
    success "Created: ${name}"
}

# ── Provision AirVibe profiles for the active region ─────────────────────────
create_profile \
    "AirVibe ${LORA_REGION}" \
    "Machine Saver AirVibe vibration sensor — ${LORA_REGION} — Class C normal operation" \
    true

create_profile \
    "AirVibe ${LORA_REGION} FUOTA" \
    "Machine Saver AirVibe vibration sensor — ${LORA_REGION} — Class A for firmware update sessions" \
    false
