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

# ── Region ID (lowercase for TOML key) ──────────────────────────────────────
LORA_REGION_ID="${LORA_REGION,,}"   # e.g. US915 → us915

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

export LORA_REGION_ID EXTERNAL_MQTT_BLOCK INFLUXDB_BLOCK

# ── Render chirpstack.toml ───────────────────────────────────────────────────
envsubst < "$ROOT/config/chirpstack/chirpstack.toml.tmpl" \
    > "$ROOT/config/chirpstack/chirpstack.toml"
echo "  [ok] config/chirpstack/chirpstack.toml"

# ── Copy region config ───────────────────────────────────────────────────────
REGION_FILE="$ROOT/config/chirpstack/regions/${LORA_REGION_ID}.toml"
if [[ ! -f "$REGION_FILE" ]]; then
    echo "ERROR: Region config not found: $REGION_FILE" >&2
    exit 1
fi
cp "$REGION_FILE" "$ROOT/config/chirpstack/region.toml"
echo "  [ok] config/chirpstack/region.toml (${LORA_REGION})"

# ── Render nginx config ──────────────────────────────────────────────────────
if [[ "${SSL_ENABLED:-false}" == "true" ]]; then
    NGINX_TMPL="$ROOT/config/nginx/https.conf.tmpl"
else
    NGINX_TMPL="$ROOT/config/nginx/http.conf.tmpl"
fi
envsubst '${DOMAIN} ${GATEWAY_BS_PORT}' < "$NGINX_TMPL" \
    > "$ROOT/config/nginx/nginx.conf"
echo "  [ok] config/nginx/nginx.conf ($([ "${SSL_ENABLED:-false}" == "true" ] && echo HTTPS || echo HTTP))"

# ── Render Grafana datasource (substitute env vars) ──────────────────────────
if [[ "${ENABLE_MONITORING:-false}" == "true" ]]; then
    envsubst '${INFLUXDB_ORG} ${INFLUXDB_BUCKET} ${INFLUXDB_TOKEN}' \
        < "$ROOT/config/grafana/provisioning/datasources/influxdb.yml" \
        > "$ROOT/config/grafana/provisioning/datasources/influxdb.generated.yml"
    echo "  [ok] config/grafana/provisioning/datasources/influxdb.generated.yml"
fi
