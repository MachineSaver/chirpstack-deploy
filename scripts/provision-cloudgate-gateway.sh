#!/usr/bin/env bash
# Provision a Cloudgate gateway for ChirpStack Basics Station.
#
# This script intentionally never factory resets the gateway. Between regional
# tests, reset the gateway manually under supervision, then rerun this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

API_BASE="https://chirpstack.machinesaver.com/api"
LNS_URI="wss://chirpstack.machinesaver.com:3001"
TENANT_ID=""
GATEWAY_NAME=""
NAME_PROVIDED=false
GATEWAY_SERIAL=""
AUTH_MODE="server-tls"
DRY_RUN=false

IP_ADDRESS=""
USERNAME=""
PASSWORD=""
REGION=""

usage() {
    cat <<USAGE
Usage:
  CHIRPSTACK_API_KEY=... scripts/provision-cloudgate-gateway.sh \\
    --ip-address 10.11.0.243 \\
    --username admin \\
    --password '...' \\
    --region us915|eu868

Required:
  --ip-address         Cloudgate VPN/LAN IP address reachable by SSH
  --username           SSH username
  --password           SSH password
  --region             Repo region id: us915 or eu868
  CHIRPSTACK_API_KEY   ChirpStack API token

Optional:
  --api-base URL       ChirpStack REST API base (default: $API_BASE)
  --lns-uri URI        Basics Station LNS URI (default: $LNS_URI)
  --tenant-id ID       ChirpStack tenant id. If omitted, the first tenant is used.
  --name NAME          Gateway name. Default: Cloudgate serial number, then gateway EUI fallback.
  --auth-mode MODE     server-tls only in v1. mutual-tls is reserved.
  --dry-run            Validate inputs and print intended API/SSH writes.
  -h, --help           Show this help.

This script does not include any factory-reset command.
USAGE
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"
}

api_url() {
    local path="$1"
    printf '%s/%s' "${API_BASE%/}" "${path#/}"
}

api_get() {
    local path="$1"
    curl -fsS \
        -H "Grpc-Metadata-Authorization: Bearer ${CHIRPSTACK_API_KEY}" \
        -H "Accept: application/json" \
        "$(api_url "$path")"
}

api_post() {
    local path="$1"
    local payload="$2"
    curl -fsS -X POST \
        -H "Grpc-Metadata-Authorization: Bearer ${CHIRPSTACK_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$(api_url "$path")"
}

api_put() {
    local path="$1"
    local payload="$2"
    curl -fsS -X PUT \
        -H "Grpc-Metadata-Authorization: Bearer ${CHIRPSTACK_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$(api_url "$path")"
}

ssh_base() {
    sshpass -p "$PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "${USERNAME}@${IP_ADDRESS}" "$@"
}

ssh_read() {
    local command="$1"
    ssh_base "$command"
}

ssh_write() {
    local command="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN SSH write: $command"
    else
        ssh_base "$command"
    fi
}

ssh_read_quiet() {
    local command="$1"
    ssh_base "$command" 2>/dev/null || true
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip-address)
                IP_ADDRESS="${2:-}"; shift 2 ;;
            --username)
                USERNAME="${2:-}"; shift 2 ;;
            --password)
                PASSWORD="${2:-}"; shift 2 ;;
            --region)
                REGION="${2:-}"; shift 2 ;;
            --api-base)
                API_BASE="${2:-}"; shift 2 ;;
            --lns-uri)
                LNS_URI="${2:-}"; shift 2 ;;
            --tenant-id)
                TENANT_ID="${2:-}"; shift 2 ;;
            --name)
                GATEWAY_NAME="${2:-}"; NAME_PROVIDED=true; shift 2 ;;
            --auth-mode)
                AUTH_MODE="${2:-}"; shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                usage >&2
                die "unknown argument: $1" ;;
        esac
    done
}

validate_required_inputs() {
    [[ -n "$IP_ADDRESS" ]] || die "--ip-address is required"
    [[ -n "$USERNAME" ]] || die "--username is required"
    [[ -n "$PASSWORD" ]] || die "--password is required"
    [[ -n "$REGION" ]] || die "--region is required"
    [[ -n "${CHIRPSTACK_API_KEY:-}" ]] || die "CHIRPSTACK_API_KEY is required"
    [[ "$AUTH_MODE" == "server-tls" ]] || die "--auth-mode $AUTH_MODE is reserved for a future version; v1 supports server-tls only"

    require_cmd curl
    require_cmd jq
    require_cmd ssh
    require_cmd sshpass
}

load_region_code() {
    local supported_regions=()
    local dir
    for dir in "$ROOT"/config/regions/*; do
        [[ -f "$dir/metadata.env" ]] || continue
        supported_regions+=("$(basename "$dir")")
    done

    local metadata="$ROOT/config/regions/$REGION/metadata.env"
    [[ -f "$metadata" ]] || die "unsupported region '$REGION'. Supported repo regions: ${supported_regions[*]:-none}"

    REGION_ID=""
    REGION_NAME=""
    BS_REGION=""
    # shellcheck disable=SC1090
    source "$metadata"

    [[ "$REGION_ID" == "$REGION" ]] || die "region metadata mismatch for $REGION"

    case "$REGION" in
        us915) CLOUDGATE_REGION_CODE="915" ;;
        eu868) CLOUDGATE_REGION_CODE="868" ;;
        *) die "region '$REGION' is present in the repo but has no known Cloudgate region code" ;;
    esac
}

normalize_gateway_id() {
    local raw="$1"
    printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[:[:space:]-]//g'
}

mac_to_eui64() {
    local mac
    mac="$(normalize_gateway_id "$1")"
    [[ "$mac" =~ ^[0-9a-f]{12}$ ]] || return 1
    printf '%sfffe%s\n' "${mac:0:6}" "${mac:6:6}"
}

discover_gateway_eui() {
    local raw=""

    log "Discovering Cloudgate router ID over SSH..."
    if raw="$(ssh_read "uci get cg_conf_basicstation.general.routerid 2>/dev/null" | tr -d '\r' | tail -n 1)" && [[ -n "$raw" ]]; then
        GATEWAY_ID="$(normalize_gateway_id "$raw")"
    elif raw="$(ssh_read "cat /etc/station/routerid 2>/dev/null" | tr -d '\r' | tail -n 1)" && [[ -n "$raw" ]]; then
        GATEWAY_ID="$(normalize_gateway_id "$raw")"
    elif raw="$(ssh_read "m2m_printenv -n mac_addr 2>/dev/null" | tr -d '\r' | tail -n 1)" && [[ -n "$raw" ]]; then
        GATEWAY_ID="$(mac_to_eui64 "$raw")" || die "mac_addr did not look like a MAC address: $raw"
    else
        die "could not discover gateway EUI from UCI, /etc/station/routerid, or m2m_printenv"
    fi

    [[ "$GATEWAY_ID" =~ ^[0-9a-f]{16}$ ]] || die "discovered gateway id is not a 16-character EUI64: $GATEWAY_ID"
    log "Gateway EUI: $GATEWAY_ID"
}

discover_gateway_serial() {
    local raw=""

    if raw="$(ssh_read_quiet "m2m_printenv -n serial_nbr" | tr -d '\r' | tail -n 1)" && [[ -n "$raw" ]]; then
        GATEWAY_SERIAL="$raw"
    elif raw="$(ssh_read_quiet "m2m_printenv 2>/dev/null | awk -F= '\$1 == \"serial_nbr\" {print \$2; exit}'" | tr -d '\r' | tail -n 1)" && [[ -n "$raw" ]]; then
        GATEWAY_SERIAL="$raw"
    fi

    if [[ -n "$GATEWAY_SERIAL" ]]; then
        log "Gateway serial: $GATEWAY_SERIAL"
        [[ -n "$GATEWAY_NAME" ]] || GATEWAY_NAME="$GATEWAY_SERIAL"
    else
        warn "Could not discover Cloudgate serial; falling back to gateway EUI for name."
        [[ -n "$GATEWAY_NAME" ]] || GATEWAY_NAME="Cloudgate $GATEWAY_ID"
    fi
}

resolve_tenant() {
    if [[ -n "$TENANT_ID" ]]; then
        log "Using supplied tenant id: $TENANT_ID"
        api_get "/tenants/$TENANT_ID" >/dev/null || die "could not read supplied ChirpStack tenant $TENANT_ID"
        return
    fi

    log "Resolving first ChirpStack tenant..."
    local tenants
    tenants="$(api_get "/tenants?limit=1")" || die "could not list ChirpStack tenants"
    TENANT_ID="$(jq -r '.result[0].id // .tenants[0].id // empty' <<< "$tenants")"
    [[ -n "$TENANT_ID" ]] || die "no tenant returned by ChirpStack API"
    log "Resolved tenant id: $TENANT_ID"
}

gateway_get_json() {
    local response status body
    response="$(curl -sS -w $'\n%{http_code}' \
        -H "Grpc-Metadata-Authorization: Bearer ${CHIRPSTACK_API_KEY}" \
        -H "Accept: application/json" \
        "$(api_url "/gateways/$GATEWAY_ID")")" || die "could not query gateway $GATEWAY_ID"
    status="$(tail -n 1 <<< "$response")"
    body="$(sed '$d' <<< "$response")"

    case "$status" in
        200)
            GATEWAY_EXISTS=true
            GATEWAY_JSON="$body"
            ;;
        404)
            GATEWAY_EXISTS=false
            GATEWAY_JSON=""
            ;;
        401)
            gateway_get_json_from_tenant_list
            ;;
        *)
            printf '%s\n' "$body" >&2
            die "unexpected ChirpStack gateway lookup status: $status"
            ;;
    esac
}

gateway_get_json_from_tenant_list() {
    [[ -n "$TENANT_ID" ]] || die "gateway lookup returned 401 and no tenant id is available for fallback listing"

    log "Gateway lookup by id returned 401; falling back to tenant-scoped gateway list..."
    local list total found
    list="$(api_get "/gateways?tenantId=$TENANT_ID&limit=100")" || die "could not list gateways for tenant $TENANT_ID"
    total="$(jq -r '.totalCount // .total_count // 0' <<< "$list")"
    found="$(jq --arg gatewayId "$GATEWAY_ID" -c '
        (.result // [])
        | map(select((.gatewayId // .gateway_id // "") == $gatewayId))
        | .[0] // empty
    ' <<< "$list")"

    if [[ -n "$found" ]]; then
        die "gateway $GATEWAY_ID appears in the tenant gateway list, but GET by id returned 401; cannot safely preserve existing fields"
    fi

    if [[ "$total" =~ ^[0-9]+$ ]] && (( total >= 100 )); then
        warn "Tenant gateway list reached the 100 item fallback limit; gateway absence is not fully proven."
    fi

    GATEWAY_EXISTS=false
    GATEWAY_JSON=""
}

build_create_payload() {
    jq -n \
        --arg gatewayId "$GATEWAY_ID" \
        --arg tenantId "$TENANT_ID" \
        --arg name "$GATEWAY_NAME" \
        --arg description "Managed by scripts/provision-cloudgate-gateway.sh. Region: $REGION." \
        '{
          gateway: {
            gatewayId: $gatewayId,
            tenantId: $tenantId,
            name: $name,
            description: $description,
            statsInterval: 30
          }
        }'
}

build_update_payload() {
    jq \
        --arg fallbackName "$GATEWAY_NAME" \
        --argjson nameProvided "$NAME_PROVIDED" \
        --arg defaultEuiName "Cloudgate $GATEWAY_ID" \
        --arg regionName "$BS_REGION" \
        --arg description "Managed by scripts/provision-cloudgate-gateway.sh. Region: $REGION." \
        '
        .gateway as $gateway
        | {
            gateway: (
              $gateway
              | .name = (if ($nameProvided or (($gateway.name // "") == "") or (($gateway.name // "") == $defaultEuiName)) then $fallbackName else $gateway.name end)
              | .description = $description
              | .statsInterval = (($gateway.statsInterval // 0) as $interval | if $interval == 0 then 30 else $interval end)
              | .metadata = (
                  ($gateway.metadata // {})
                  | if ((.region_common_name // "") != "" and (.region_common_name != $regionName))
                    then del(.region_common_name)
                    else .
                    end
                )
            )
          }' <<< "$GATEWAY_JSON"
}

apply_chirpstack_registration() {
    gateway_get_json

    local payload
    if [[ "$GATEWAY_EXISTS" == "true" ]]; then
        payload="$(build_update_payload)"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "DRY-RUN ChirpStack update PUT /gateways/$GATEWAY_ID:"
            jq . <<< "$payload"
        else
            log "Updating existing ChirpStack gateway without clearing tenant/location/tags/metadata..."
            api_put "/gateways/$GATEWAY_ID" "$payload" >/dev/null
        fi
    else
        payload="$(build_create_payload)"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "DRY-RUN ChirpStack create POST /gateways:"
            jq . <<< "$payload"
        else
            log "Creating ChirpStack gateway..."
            api_post "/gateways" "$payload" >/dev/null
        fi
    fi
}

check_gateway_trust_material() {
    if [[ "$LNS_URI" != wss://* ]]; then
        return
    fi

    log "Checking Cloudgate trust material for WSS..."
    local trust_file
    trust_file="$(ssh_read "for f in /etc/ssl/certs/ca-certificates.crt /etc/station/tc.trust /etc/station/tc.trust.pem; do [ -s \"\$f\" ] && echo \"\$f\" && exit 0; done; exit 1" | tr -d '\r' | tail -n 1 || true)"
    [[ -n "$trust_file" ]] || die "wss:// requires server CA trust material on the Cloudgate. Install the server CA bundle manually, then rerun."
    log "Found gateway trust material: $trust_file"
}

configure_cloudgate() {
    warn "The live ChirpStack Gateway Bridge must already be configured for $REGION ($BS_REGION). v1 does not switch the live server region."
    warn "A region mismatch can appear as gateway disconnects after router config or no lastSeenAt update."

    check_gateway_trust_material

    log "Applying Cloudgate Basic Station UCI configuration..."
    UCI_CHANGED=false
    uci_set_if_needed "uri" "$LNS_URI"
    uci_set_if_needed "auth" "tc"
    uci_set_if_needed "region" "$CLOUDGATE_REGION_CODE"
    uci_set_if_needed "routerid" "$GATEWAY_ID"
    uci_set_if_needed "prefix" "::0"

    if [[ "$UCI_CHANGED" == "true" ]]; then
        ssh_write "uci commit cg_conf_basicstation"
        ssh_write "/etc/init.d/bstation restart"
    else
        log "Cloudgate Basic Station UCI already matches desired values; skipping commit and restart."
    fi
}

uci_set_if_needed() {
    local key="$1"
    local expected="$2"
    local current
    current="$(ssh_read_quiet "uci get cg_conf_basicstation.general.${key}" | tr -d '\r' | tail -n 1)"
    if [[ "$key" == "routerid" ]]; then
        [[ "$(normalize_gateway_id "$current")" == "$(normalize_gateway_id "$expected")" ]] && return
    elif [[ "$current" == "$expected" ]]; then
        return
    fi

    UCI_CHANGED=true
    ssh_write "uci set cg_conf_basicstation.general.${key}='${expected}'"
}

verify_level1() {
    log "Level 1 verification: Cloudgate config files and UCI values..."
    local output tc_uri station_routerid uci_region
    output="$(ssh_read "printf 'tc_uri=%s\n' \"\$(cat /etc/station/tc.uri 2>/dev/null)\"; printf 'routerid=%s\n' \"\$(cat /etc/station/routerid 2>/dev/null)\"; printf 'uci_region=%s\n' \"\$(uci get cg_conf_basicstation.general.region 2>/dev/null)\"")"
    printf '%s\n' "$output"

    tc_uri="$(awk -F= '$1=="tc_uri"{print $2}' <<< "$output" | tail -n 1)"
    station_routerid="$(awk -F= '$1=="routerid"{print $2}' <<< "$output" | tail -n 1)"
    uci_region="$(awk -F= '$1=="uci_region"{print $2}' <<< "$output" | tail -n 1)"

    [[ "$tc_uri" == "$LNS_URI" ]] || warn "Level 1: /etc/station/tc.uri did not match expected LNS URI"
    [[ "$(normalize_gateway_id "$station_routerid")" == "$GATEWAY_ID" ]] || warn "Level 1: /etc/station/routerid did not match expected gateway EUI"
    [[ "$uci_region" == "$CLOUDGATE_REGION_CODE" ]] || warn "Level 1: UCI region did not match expected Cloudgate region code"
}

verify_level2() {
    log "Level 2 verification: process and recent Basic Station/LNS logs..."
    ssh_read "ps | grep -Ei 'station|bstation|basic' | grep -v grep || true; grep -iE 'station|basic|lns|websocket|router' /log/messages 2>/dev/null | tail -40 || true"
}

verify_level3() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN: skipping ChirpStack lastSeenAt polling."
        return
    fi

    log "Level 3 verification: polling ChirpStack gateway state..."
    local attempt gateway last_seen state
    for attempt in 1 2 3 4 5 6; do
        gateway="$(api_get "/gateways/$GATEWAY_ID" || true)"
        last_seen="$(jq -r '.gateway.lastSeenAt // .lastSeenAt // empty' <<< "$gateway" 2>/dev/null || true)"
        state="$(jq -r '.gateway.state // .state // empty' <<< "$gateway" 2>/dev/null || true)"
        if [[ -n "$last_seen" && "$last_seen" != "null" ]]; then
            log "ChirpStack lastSeenAt: $last_seen"
            return
        fi
        if [[ -n "$state" && "$state" != "null" ]]; then
            log "ChirpStack state: $state"
        fi
        sleep 10
    done

    warn "Level 3 did not observe lastSeenAt. This can be normal when the live server region does not match or stats have not arrived yet."
}

main() {
    parse_args "$@"
    validate_required_inputs
    load_region_code

    log "Cloudgate provisioning target:"
    log "  IP address: $IP_ADDRESS"
    log "  Region: $REGION ($BS_REGION, Cloudgate code $CLOUDGATE_REGION_CODE)"
    log "  LNS URI: $LNS_URI"
    log "  API base: $API_BASE"
    [[ "$DRY_RUN" == "true" ]] && log "  Mode: dry-run"

    resolve_tenant
    discover_gateway_eui
    discover_gateway_serial
    apply_chirpstack_registration
    configure_cloudgate

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN complete. No ChirpStack or Cloudgate writes were performed."
        log "Manual factory reset required before the next region test. Perform the reset under supervision, then rerun this script after the gateway is reachable."
        return
    fi

    verify_level1
    verify_level2
    verify_level3

    log "Provisioning complete for gateway $GATEWAY_ID."
    log "Manual factory reset required before the next region test. Perform the reset under supervision, then rerun this script after the gateway is reachable."
}

main "$@"
