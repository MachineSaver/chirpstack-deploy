#!/usr/bin/env bash
# Retrieve AirVibe LoRaWAN credentials from the activation API and register
# the sensors in ChirpStack. Safe to re-run: existing devices are skipped unless
# --update-keys is supplied.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AIRVIBE_API_BASE="https://ap-api.wipom.net/api"
API_BASE=""
TENANT_ID=""
APPLICATION_NAME="AirVibe Sensors"
DEVICE_PROFILE_NAME=""
DRY_RUN=false
UPDATE_KEYS=false

LOOKUP_DEV_EUI=""
LOOKUP_ACCESS_CODE=""
LOOKUP_SERIAL=""
LOOKUP_NAME=""
INPUT_FILE=""

AIRVIBE_TOKEN=""
APPLICATION_ID=""
DEVICE_PROFILE_ID=""
BATCH_MODE=false
BATCH_RESOLVED_DEV_EUIS=""

usage() {
    cat <<USAGE
Usage:
  scripts/provision-airvibe-sensors.sh --dev-eui EUI --access-code CODE [--name NAME]
  scripts/provision-airvibe-sensors.sh --serial SERIAL [--name NAME]
  scripts/provision-airvibe-sensors.sh --file sensors.tsv

Lookup modes:
  --dev-eui EUI --access-code CODE  Retrieve one AirVibe by DevEUI + access code.
  --serial SERIAL                   Retrieve one AirVibe by serial number.
  --file sensors.tsv                Batch TSV with header: dev_eui access_code serial name

Required environment or .env:
  AIRVIBE_API_LOGIN                 Activation API login.
  AIRVIBE_API_PASSWORD              Activation API password.
  CHIRPSTACK_API_KEY                ChirpStack REST API token.
  LORA_REGION                       Region used for default profile name.

Options:
  --application-name NAME           ChirpStack application (default: AirVibe Sensors).
  --device-profile-name NAME        Device profile (default: AirVibe \${LORA_REGION}).
  --tenant-id ID                    ChirpStack tenant id. If omitted, first tenant is used.
  --api-base URL                    ChirpStack REST API base. Defaults from .env.
  --airvibe-api-base URL            Activation API base (default: $AIRVIBE_API_BASE).
  --update-keys                     Replace OTAA keys for existing devices.
  --dry-run                         Authenticate and print planned writes only.
  -h, --help                        Show this help.

The script never prints API passwords, ChirpStack API keys, or LoRaWAN root keys.
USAGE
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"
}

load_env() {
    local env_file="$ROOT/.env"
    if [[ -f "$env_file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
    fi
}

resolve_api_base() {
    if [[ -n "$API_BASE" ]]; then
        API_BASE="${API_BASE%/}"
        return
    fi

    if [[ "${SSL_ENABLED:-false}" == "true" ]]; then
        [[ -n "${DOMAIN:-}" ]] || die "DOMAIN is required when SSL_ENABLED=true"
        if [[ "${HTTPS_PORT:-443}" == "443" ]]; then
            API_BASE="https://${DOMAIN}/api"
        else
            API_BASE="https://${DOMAIN}:${HTTPS_PORT}/api"
        fi
    else
        API_BASE="http://127.0.0.1:${HTTP_PORT:-80}/api"
    fi
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

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dev-eui)
                LOOKUP_DEV_EUI="${2:-}"; shift 2 ;;
            --access-code)
                LOOKUP_ACCESS_CODE="${2:-}"; shift 2 ;;
            --serial)
                LOOKUP_SERIAL="${2:-}"; shift 2 ;;
            --name)
                LOOKUP_NAME="${2:-}"; shift 2 ;;
            --file)
                INPUT_FILE="${2:-}"; shift 2 ;;
            --application-name)
                APPLICATION_NAME="${2:-}"; shift 2 ;;
            --device-profile-name)
                DEVICE_PROFILE_NAME="${2:-}"; shift 2 ;;
            --tenant-id)
                TENANT_ID="${2:-}"; shift 2 ;;
            --api-base)
                API_BASE="${2:-}"; shift 2 ;;
            --airvibe-api-base)
                AIRVIBE_API_BASE="${2:-}"; shift 2 ;;
            --update-keys)
                UPDATE_KEYS=true; shift ;;
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

validate_args() {
    require_cmd curl
    require_cmd jq

    [[ -n "${AIRVIBE_API_LOGIN:-}" ]] || die "AIRVIBE_API_LOGIN is required"
    [[ -n "${AIRVIBE_API_PASSWORD:-}" ]] || die "AIRVIBE_API_PASSWORD is required"
    [[ -n "${CHIRPSTACK_API_KEY:-}" ]] || die "CHIRPSTACK_API_KEY is required"
    [[ -n "${LORA_REGION:-}" ]] || die "LORA_REGION is required"

    AIRVIBE_API_BASE="${AIRVIBE_API_BASE%/}"
    [[ -n "$DEVICE_PROFILE_NAME" ]] || DEVICE_PROFILE_NAME="AirVibe ${LORA_REGION}"

    local modes=0
    [[ -n "$INPUT_FILE" ]] && modes=$((modes + 1))
    [[ -n "$LOOKUP_SERIAL" ]] && modes=$((modes + 1))
    [[ -n "$LOOKUP_DEV_EUI" || -n "$LOOKUP_ACCESS_CODE" ]] && modes=$((modes + 1))
    [[ "$modes" -eq 1 ]] || die "choose exactly one lookup mode: --file, --serial, or --dev-eui with --access-code"

    if [[ -n "$INPUT_FILE" ]]; then
        [[ -f "$INPUT_FILE" ]] || die "batch file not found: $INPUT_FILE"
    elif [[ -n "$LOOKUP_SERIAL" ]]; then
        [[ -z "$LOOKUP_ACCESS_CODE" && -z "$LOOKUP_DEV_EUI" ]] || die "--serial cannot be combined with --dev-eui or --access-code"
    else
        [[ -n "$LOOKUP_DEV_EUI" && -n "$LOOKUP_ACCESS_CODE" ]] || die "--dev-eui and --access-code are both required"
        LOOKUP_DEV_EUI="$(normalize_eui "$LOOKUP_DEV_EUI")" || die "invalid --dev-eui; expected 16 hex characters"
    fi
}

normalize_eui() {
    local raw="$1"
    local value
    value="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^0-9A-F]//g')"
    [[ "$value" =~ ^[0-9A-F]{16}$ ]] || return 1
    printf '%s\n' "$value"
}

normalize_key() {
    local raw="$1"
    local value
    value="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^0-9A-F]//g')"
    [[ "$value" =~ ^[0-9A-F]{32}$ ]] || return 1
    printf '%s\n' "$value"
}

json_keys_summary() {
    jq -r '
        [.. | objects | keys_unsorted[]?]
        | unique
        | sort
        | join(", ")
    ' <<< "$1"
}

airvibe_login() {
    log "Authenticating with AirVibe activation API..."
    local payload response
    payload="$(jq -n \
        --arg login "$AIRVIBE_API_LOGIN" \
        --arg password "$AIRVIBE_API_PASSWORD" \
        '{login: $login, password: $password}')"
    response="$(curl -fsS \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${AIRVIBE_API_BASE}/auth/login")" || die "AirVibe activation API login failed"

    AIRVIBE_TOKEN="$(jq -r '
        .data.accessToken //
        .data.access_token //
        .accessToken //
        .access_token //
        .token //
        empty
    ' <<< "$response")"
    [[ -n "$AIRVIBE_TOKEN" ]] || die "AirVibe login response did not include an access token. Keys: $(json_keys_summary "$response")"
    log "Authenticated with AirVibe activation API."
}

airvibe_lookup() {
    local dev_eui="$1"
    local access_code="$2"
    local serial="$3"

    if [[ -n "$serial" ]]; then
        curl -fsS -G \
            -H "Authorization: Bearer ${AIRVIBE_TOKEN}" \
            --data-urlencode "pattern=${serial}" \
            "${AIRVIBE_API_BASE}/devices/serial"
    else
        curl -fsS -G \
            -H "Authorization: Bearer ${AIRVIBE_TOKEN}" \
            --data-urlencode "eui=${dev_eui}" \
            --data-urlencode "ac=${access_code}" \
            "${AIRVIBE_API_BASE}/devices/search"
    fi
}

extract_field() {
    local json="$1"
    local aliases_json="$2"
    jq -r --argjson aliases "$aliases_json" '
        def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
        [
          .. | objects | to_entries[]?
          | select((.key | norm) as $k | $aliases | index($k))
          | .value
          | select((type == "string") or (type == "number"))
          | tostring
        ][0] // empty
    ' <<< "$json"
}

extract_airvibe_credentials() {
    local json="$1"
    local fallback_dev_eui="$2"
    local fallback_serial="$3"
    local requested_name="$4"

    local raw_dev_eui raw_join_eui raw_key raw_serial raw_name
    raw_dev_eui="$(extract_field "$json" '["deveui","deviceeui","eui","loradeveui"]')"
    raw_join_eui="$(extract_field "$json" '["joineui","appeui","applicacioneui","applicationeui"]')"
    raw_key="$(extract_field "$json" '["appkey","nwkkey","networkkey","applicationkey","lorakey","loraappkey"]')"
    raw_serial="$(extract_field "$json" '["serial","serialnumber","sn"]')"
    raw_name="$(extract_field "$json" '["name","displayname","devicename","label"]')"

    [[ -n "$raw_dev_eui" ]] || raw_dev_eui="$fallback_dev_eui"
    [[ -n "$raw_serial" ]] || raw_serial="$fallback_serial"

    DEVICE_DEV_EUI="$(normalize_eui "$raw_dev_eui")" || die "AirVibe response did not contain a valid DevEUI. Keys: $(json_keys_summary "$json")"
    DEVICE_NWK_KEY="$(normalize_key "$raw_key")" || die "AirVibe response did not contain a valid 128-bit AppKey/NwkKey. Keys: $(json_keys_summary "$json")"

    DEVICE_JOIN_EUI=""
    if [[ -n "$raw_join_eui" ]]; then
        DEVICE_JOIN_EUI="$(normalize_eui "$raw_join_eui")" || die "AirVibe response contained an invalid JoinEUI/AppEUI. Keys: $(json_keys_summary "$json")"
    fi

    DEVICE_SERIAL="$raw_serial"
    if [[ -n "$requested_name" ]]; then
        DEVICE_NAME="$requested_name"
    elif [[ -n "$raw_name" ]]; then
        DEVICE_NAME="$raw_name"
    elif [[ -n "$DEVICE_SERIAL" ]]; then
        DEVICE_NAME="AirVibe ${DEVICE_SERIAL}"
    else
        DEVICE_NAME="AirVibe ${DEVICE_DEV_EUI}"
    fi
}

resolve_tenant() {
    if [[ -n "$TENANT_ID" ]]; then
        log "Using supplied ChirpStack tenant id: $TENANT_ID"
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

resolve_application() {
    log "Resolving ChirpStack application: $APPLICATION_NAME"
    local apps app_id payload response
    apps="$(api_get "/applications?tenantId=${TENANT_ID}&limit=100")" || die "could not list ChirpStack applications"
    app_id="$(jq -r --arg name "$APPLICATION_NAME" '
        (.result // .applications // [])
        | map(select(.name == $name))
        | .[0].id // empty
    ' <<< "$apps")"

    if [[ -n "$app_id" ]]; then
        APPLICATION_ID="$app_id"
        log "Using existing application id: $APPLICATION_ID"
        return
    fi

    payload="$(jq -n \
        --arg tenantId "$TENANT_ID" \
        --arg name "$APPLICATION_NAME" \
        '{application: {tenantId: $tenantId, name: $name, description: "AirVibe sensors provisioned by scripts/provision-airvibe-sensors.sh."}}')"

    if [[ "$DRY_RUN" == "true" ]]; then
        APPLICATION_ID="DRY_RUN_APPLICATION_ID"
        log "DRY-RUN ChirpStack create POST /applications:"
        jq . <<< "$payload"
        return
    fi

    response="$(api_post "/applications" "$payload")" || die "could not create ChirpStack application"
    APPLICATION_ID="$(jq -r '.id // .application.id // empty' <<< "$response")"
    if [[ -z "$APPLICATION_ID" ]]; then
        apps="$(api_get "/applications?tenantId=${TENANT_ID}&limit=100")" || die "created application but could not list applications"
        APPLICATION_ID="$(jq -r --arg name "$APPLICATION_NAME" '(.result // []) | map(select(.name == $name)) | .[0].id // empty' <<< "$apps")"
    fi
    [[ -n "$APPLICATION_ID" ]] || die "created application but could not resolve its id"
    log "Created application id: $APPLICATION_ID"
}

resolve_device_profile() {
    log "Resolving ChirpStack device profile: $DEVICE_PROFILE_NAME"
    local profiles
    profiles="$(api_get "/device-profiles?tenantId=${TENANT_ID}&limit=100")" || die "could not list ChirpStack device profiles"
    DEVICE_PROFILE_ID="$(jq -r --arg name "$DEVICE_PROFILE_NAME" '
        (.result // .deviceProfiles // .device_profiles // [])
        | map(select(.name == $name))
        | .[0].id // empty
    ' <<< "$profiles")"
    [[ -n "$DEVICE_PROFILE_ID" ]] || die "device profile not found: $DEVICE_PROFILE_NAME. Run scripts/provision-devices.sh first or pass --device-profile-name."
    log "Using device profile id: $DEVICE_PROFILE_ID"
}

device_exists() {
    local dev_eui="$1"
    local response status
    response="$(curl -sS -w $'\n%{http_code}' \
        -H "Grpc-Metadata-Authorization: Bearer ${CHIRPSTACK_API_KEY}" \
        -H "Accept: application/json" \
        "$(api_url "/devices/$dev_eui")")" || die "could not query ChirpStack device $dev_eui"
    status="$(tail -n 1 <<< "$response")"
    case "$status" in
        200) return 0 ;;
        404) return 1 ;;
        *)
            sed '$d' <<< "$response" >&2
            die "unexpected ChirpStack device lookup status for $dev_eui: $status"
            ;;
    esac
}

build_device_payload() {
    jq -n \
        --arg applicationId "$APPLICATION_ID" \
        --arg deviceProfileId "$DEVICE_PROFILE_ID" \
        --arg devEui "$DEVICE_DEV_EUI" \
        --arg name "$DEVICE_NAME" \
        --arg serial "$DEVICE_SERIAL" \
        --arg joinEui "$DEVICE_JOIN_EUI" \
        '{
          device: {
            applicationId: $applicationId,
            deviceProfileId: $deviceProfileId,
            devEui: $devEui,
            name: $name,
            description: "AirVibe sensor provisioned by scripts/provision-airvibe-sensors.sh.",
            isDisabled: false,
            skipFcntCheck: false,
            variables: (if $serial != "" then {airvibe_serial: $serial} else {} end),
            tags: (if $joinEui != "" then {join_eui: $joinEui} else {} end)
          }
        }'
}

build_keys_payload() {
    jq -n \
        --arg devEui "$DEVICE_DEV_EUI" \
        --arg nwkKey "$DEVICE_NWK_KEY" \
        '{deviceKeys: {devEui: $devEui, nwkKey: $nwkKey}}'
}

print_sanitized_device_plan() {
    log "Planned sensor:"
    log "  DevEUI: $DEVICE_DEV_EUI"
    [[ -n "$DEVICE_SERIAL" ]] && log "  Serial: $DEVICE_SERIAL"
    [[ -n "$DEVICE_JOIN_EUI" ]] && log "  JoinEUI: $DEVICE_JOIN_EUI"
    log "  Name: $DEVICE_NAME"
    log "  OTAA key: present (hidden)"
}

register_current_device() {
    print_sanitized_device_plan

    local device_payload keys_payload
    device_payload="$(build_device_payload)"
    keys_payload="$(build_keys_payload)"

    if device_exists "$DEVICE_DEV_EUI"; then
        log "Device already exists in ChirpStack: $DEVICE_DEV_EUI"
        if [[ "$UPDATE_KEYS" != "true" ]]; then
            log "Leaving existing OTAA keys unchanged. Use --update-keys to replace them."
            return
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log "DRY-RUN ChirpStack update PUT /devices/$DEVICE_DEV_EUI/keys:"
            jq '(.deviceKeys.nwkKey = "hidden")' <<< "$keys_payload"
        else
            log "Updating OTAA keys for existing device $DEVICE_DEV_EUI..."
            api_put "/devices/$DEVICE_DEV_EUI/keys" "$keys_payload" >/dev/null
        fi
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN ChirpStack create POST /devices:"
        jq . <<< "$device_payload"
        log "DRY-RUN ChirpStack create POST /devices/$DEVICE_DEV_EUI/keys:"
        jq '(.deviceKeys.nwkKey = "hidden")' <<< "$keys_payload"
    else
        log "Creating ChirpStack device $DEVICE_DEV_EUI..."
        api_post "/devices" "$device_payload" >/dev/null
        log "Creating OTAA keys for $DEVICE_DEV_EUI..."
        api_post "/devices/$DEVICE_DEV_EUI/keys" "$keys_payload" >/dev/null
    fi
}

process_sensor() {
    local dev_eui="$1"
    local access_code="$2"
    local serial="$3"
    local name="$4"

    if [[ -n "$dev_eui" ]]; then
        dev_eui="$(normalize_eui "$dev_eui")" || die "invalid DevEUI in input: $dev_eui"
    fi
    if [[ -z "$serial" ]] && [[ -z "$dev_eui" || -z "$access_code" ]]; then
        die "each sensor needs either serial or dev_eui + access_code"
    fi

    local response
    if [[ -n "$serial" ]]; then
        log "Retrieving AirVibe credentials for serial: $serial"
    else
        log "Retrieving AirVibe credentials for DevEUI: $dev_eui"
    fi
    response="$(airvibe_lookup "$dev_eui" "$access_code" "$serial")" || die "AirVibe credential lookup failed"
    extract_airvibe_credentials "$response" "$dev_eui" "$serial" "$name"
    if [[ "$BATCH_MODE" == "true" ]]; then
        if grep -Fxq "$DEVICE_DEV_EUI" <<< "$BATCH_RESOLVED_DEV_EUIS"; then
            die "batch resolves duplicate DevEUI $DEVICE_DEV_EUI"
        fi
        BATCH_RESOLVED_DEV_EUIS+="${DEVICE_DEV_EUI}"$'\n'
    fi
    register_current_device
}

process_file() {
    local file="$1"
    local header line parsed_line line_no dev_eui access_code serial name extra normalized
    local seen_dev_euis=""

    IFS= read -r header < "$file" || die "batch file is empty: $file"
    header="${header%$'\r'}"
    [[ "$header" == $'dev_eui\taccess_code\tserial\tname' ]] || die "batch header must be exactly: dev_eui<TAB>access_code<TAB>serial<TAB>name"

    BATCH_MODE=true
    line_no=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        line="${line%$'\r'}"
        [[ -n "$line" ]] || continue
        parsed_line="${line//$'\t'/$'\037'}"
        IFS=$'\037' read -r dev_eui access_code serial name extra <<< "$parsed_line"
        [[ -z "${extra:-}" ]] || die "line $line_no has too many columns"

        if [[ -z "${serial:-}" ]] && [[ -z "${dev_eui:-}" || -z "${access_code:-}" ]]; then
            die "line $line_no needs either serial or dev_eui + access_code"
        fi
        if [[ -n "${dev_eui:-}" ]]; then
            normalized="$(normalize_eui "$dev_eui")" || die "line $line_no has invalid DevEUI"
            if grep -Fxq "$normalized" <<< "$seen_dev_euis"; then
                die "line $line_no duplicates DevEUI $normalized"
            fi
            seen_dev_euis+="${normalized}"$'\n'
        fi

        log ""
        log "Batch line $line_no"
        process_sensor "${dev_eui:-}" "${access_code:-}" "${serial:-}" "${name:-}"
    done < <(tail -n +2 "$file")
}

main() {
    load_env
    parse_args "$@"
    validate_args
    resolve_api_base

    log "AirVibe sensor provisioning target:"
    log "  ChirpStack API base: $API_BASE"
    log "  Application: $APPLICATION_NAME"
    log "  Device profile: $DEVICE_PROFILE_NAME"
    [[ "$DRY_RUN" == "true" ]] && log "  Mode: dry-run"
    [[ "$UPDATE_KEYS" == "true" ]] && log "  Existing keys: update enabled"

    airvibe_login
    resolve_tenant
    resolve_application
    resolve_device_profile

    if [[ -n "$INPUT_FILE" ]]; then
        process_file "$INPUT_FILE"
    else
        process_sensor "$LOOKUP_DEV_EUI" "$LOOKUP_ACCESS_CODE" "$LOOKUP_SERIAL" "$LOOKUP_NAME"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN complete. No ChirpStack writes were performed."
    else
        log "AirVibe sensor provisioning complete."
    fi
}

main "$@"
