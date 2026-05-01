#!/usr/bin/env bash
# Renders .tmpl files into their final config counterparts using values from .env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ ! -f "$ROOT/.env" ]]; then
    echo "ERROR: .env not found. Run ./setup.sh first." >&2
    exit 1
fi

# shellcheck disable=SC1091
set -a; source "$ROOT/.env"; set +a

# ── Region module ───────────────────────────────────────────────────────────
LORA_REGION_ID="${LORA_REGION,,}"   # e.g. US915 -> us915
REGION_DIR="$ROOT/config/regions/$LORA_REGION_ID"
REGION_METADATA="$REGION_DIR/metadata.env"
REGION_FILE="$REGION_DIR/chirpstack.toml"
REGION_CONCENTRATORS_FILE="$REGION_DIR/basics-station-concentrators.toml"

if [[ ! -d "$REGION_DIR" ]]; then
    echo "ERROR: Region module not found: $REGION_DIR" >&2
    echo "       Set LORA_REGION to one of the directories in config/regions/." >&2
    exit 1
fi

for required_file in "$REGION_METADATA" "$REGION_FILE" "$REGION_CONCENTRATORS_FILE"; do
    if [[ ! -f "$required_file" ]]; then
        echo "ERROR: Region module is missing required file: $required_file" >&2
        exit 1
    fi
done

# shellcheck disable=SC1090
source "$REGION_METADATA"

required_region_vars=(
    REGION_ID
    REGION_NAME
    REGION_DISPLAY_NAME
    REGION_SETUP_DESCRIPTION
    REGION_MENU_ORDER
    BS_REGION
    BS_FREQ_MIN
    BS_FREQ_MAX
)
for var_name in "${required_region_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
        echo "ERROR: Region metadata missing required value: $var_name ($REGION_METADATA)" >&2
        exit 1
    fi
done
if [[ "$REGION_ID" != "$LORA_REGION_ID" ]]; then
    echo "ERROR: Region metadata REGION_ID=$REGION_ID does not match directory $LORA_REGION_ID" >&2
    exit 1
fi
if ! grep -Eq "id[[:space:]]*=[[:space:]]*\"${LORA_REGION_ID}\"" "$REGION_FILE"; then
    echo "ERROR: Region TOML id does not match selected region: $REGION_FILE" >&2
    exit 1
fi
if ! grep -Fq '[[backend.basic_station.concentrators]]' "$REGION_CONCENTRATORS_FILE"; then
    echo "ERROR: Basics Station concentrator TOML has no concentrator block: $REGION_CONCENTRATORS_FILE" >&2
    exit 1
fi

BS_CONCENTRATOR_BLOCK="$(< "$REGION_CONCENTRATORS_FILE")"

# ── External MQTT block ─────────────────────────────────────────────────────
if [[ -n "${EXTERNAL_MQTT_SERVER:-}" ]]; then
    EXTERNAL_MQTT_BLOCK=$(cat <<BLOCK

[integration.mqtt_external]
  server="${EXTERNAL_MQTT_SERVER}"
  qos=0
  json=true
BLOCK
)
else
    EXTERNAL_MQTT_BLOCK=""
fi

# ── InfluxDB integration block ───────────────────────────────────────────────
if [[ "${ENABLE_MONITORING:-false}" == "true" ]]; then
    INFLUXDB_BLOCK=$(cat <<BLOCK

[integration.influxdb]
  endpoint="http://influxdb:8086/api/v2/write"
  version=2
  token="${INFLUXDB_TOKEN}"
  organization="${INFLUXDB_ORG}"
  bucket="${INFLUXDB_BUCKET}"
  precision="MS"
BLOCK
)
else
    INFLUXDB_BLOCK=""
fi

export LORA_REGION_ID EXTERNAL_MQTT_BLOCK INFLUXDB_BLOCK BS_REGION BS_FREQ_MIN BS_FREQ_MAX BS_CONCENTRATOR_BLOCK

# ── Create output directories ────────────────────────────────────────────────
mkdir -p \
    "$ROOT/generated/chirpstack" \
    "$ROOT/generated/gateway-bridge" \
    "$ROOT/generated/nginx" \
    "$ROOT/generated/grafana/provisioning/datasources"

# ── Render chirpstack.toml ───────────────────────────────────────────────────
envsubst < "$ROOT/config/chirpstack/chirpstack.toml.tmpl" \
    > "$ROOT/generated/chirpstack/chirpstack.toml"
echo "  [ok] generated/chirpstack/chirpstack.toml"

# ── Render gateway-bridge Basics Station config ──────────────────────────────
envsubst < "$ROOT/config/gateway-bridge/bs.toml.tmpl" \
    > "$ROOT/generated/gateway-bridge/bs.toml"
echo "  [ok] generated/gateway-bridge/bs.toml (${REGION_NAME})"

# ── Copy region config + inject per-region gateway backend MQTT ──────────────
# ChirpStack v4 requires gateway.backend.mqtt inside the [[regions]] block.
# The global [gateway.backend.mqtt] in chirpstack.toml is silently ignored.
cp "$REGION_FILE" "$ROOT/generated/chirpstack/region.toml"
cat >> "$ROOT/generated/chirpstack/region.toml" << TOML

  [regions.gateway]
    [regions.gateway.backend]
      enabled="mqtt"

      [regions.gateway.backend.mqtt]
        event_topic="${LORA_REGION_ID}/gateway/+/event/+"
        state_topic="${LORA_REGION_ID}/gateway/+/state/+"
        command_topic="${LORA_REGION_ID}/gateway/{{gateway_id}}/command/{{command_type}}"
        server="tcp://${MOSQUITTO_USER}:${MOSQUITTO_PASSWORD}@mosquitto:1883"
        qos=0
        clean_session=false
        client_id=""
        ca_cert=""
        tls_cert=""
        tls_key=""
TOML
echo "  [ok] generated/chirpstack/region.toml (${REGION_NAME})"

# ── Render nginx config ──────────────────────────────────────────────────────
if [[ "${SSL_ENABLED:-false}" == "true" ]]; then
    NGINX_TMPL="$ROOT/config/nginx/https.conf.tmpl"
else
    NGINX_TMPL="$ROOT/config/nginx/http.conf.tmpl"
fi
envsubst '${DOMAIN} ${GATEWAY_BS_PORT}' < "$NGINX_TMPL" \
    > "$ROOT/generated/nginx/nginx.conf"
echo "  [ok] generated/nginx/nginx.conf ($([ "${SSL_ENABLED:-false}" == "true" ] && echo HTTPS || echo HTTP))"

# ── Render Grafana datasources (substitute env vars) ─────────────────────────
if [[ "${ENABLE_MONITORING:-false}" == "true" ]]; then
    envsubst '${INFLUXDB_ORG} ${INFLUXDB_BUCKET} ${INFLUXDB_TOKEN}' \
        < "$ROOT/config/grafana/provisioning/datasources/influxdb.yml.tmpl" \
        > "$ROOT/generated/grafana/provisioning/datasources/influxdb.yml"
    echo "  [ok] generated/grafana/provisioning/datasources/influxdb.yml"

    envsubst '${POSTGRES_USER} ${POSTGRES_PASSWORD} ${POSTGRES_DB}' \
        < "$ROOT/config/grafana/provisioning/datasources/postgres.yml.tmpl" \
        > "$ROOT/generated/grafana/provisioning/datasources/postgres.yml"
    echo "  [ok] generated/grafana/provisioning/datasources/postgres.yml"
fi
