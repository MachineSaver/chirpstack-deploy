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

# ── Basics Station concentrator config (region-specific) ────────────────────
if [[ "${LORA_REGION^^}" == "US915" ]]; then
    BS_REGION="US915"
    BS_FREQ_MIN=902000000
    BS_FREQ_MAX=928000000
    # Sub-band 2: channels 8-15 (125 kHz) + channel 65 (500 kHz)
    BS_CONCENTRATOR_BLOCK='# US915 sub-band 2: channels 8-15 (125kHz) + channel 65 (500kHz)
[[backend.basic_station.concentrators]]

  [backend.basic_station.concentrators.multi_sf]
    frequencies=[
      903900000,
      904100000,
      904300000,
      904500000,
      904700000,
      904900000,
      905100000,
      905300000,
    ]

  [backend.basic_station.concentrators.lora_std]
    frequency=904600000
    bandwidth=500000
    spreading_factor=8'
else
    BS_REGION="EU868"
    BS_FREQ_MIN=863000000
    BS_FREQ_MAX=870000000
    # Standard EU868 8-channel plan
    BS_CONCENTRATOR_BLOCK='# EU868 standard 8-channel plan
[[backend.basic_station.concentrators]]

  [backend.basic_station.concentrators.multi_sf]
    frequencies=[
      868100000,
      868300000,
      868500000,
      867100000,
      867300000,
      867500000,
      867700000,
      867900000,
    ]

  [backend.basic_station.concentrators.lora_std]
    frequency=868300000
    bandwidth=250000
    spreading_factor=7

  [backend.basic_station.concentrators.fsk]
    frequency=868800000'
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
echo "  [ok] generated/gateway-bridge/bs.toml (${LORA_REGION})"

# ── Copy region config + inject per-region gateway backend MQTT ──────────────
# ChirpStack v4 requires gateway.backend.mqtt inside the [[regions]] block.
# The global [gateway.backend.mqtt] in chirpstack.toml is silently ignored.
REGION_FILE="$ROOT/config/chirpstack/regions/${LORA_REGION_ID}.toml"
if [[ ! -f "$REGION_FILE" ]]; then
    echo "ERROR: Region config not found: $REGION_FILE" >&2
    exit 1
fi
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
echo "  [ok] generated/chirpstack/region.toml (${LORA_REGION})"

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
