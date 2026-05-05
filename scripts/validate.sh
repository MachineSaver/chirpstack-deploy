#!/usr/bin/env bash
# Validates shell scripts, templates, and Compose files without requiring a
# running stack. Run before committing changes to any of these.
#
# Exit codes: 0 = all checks passed, 1 = one or more checks failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; SKIP=0

ok()      { echo "  [ok]   $*"; PASS=$((PASS + 1)); }
fail()    { echo "  [FAIL] $*" >&2; FAIL=$((FAIL + 1)); }
skip()    { echo "  [skip] $*"; SKIP=$((SKIP + 1)); }
section() { printf '\n── %s\n' "$*"; }

usage() {
    cat <<USAGE
Usage:
  scripts/validate.sh
  scripts/validate.sh --live-gateway-status

The default mode is offline validation. --live-gateway-status requires a
running stack and an online gateway with non-null ChirpStack last_seen_at.
USAGE
}

live_gateway_status() {
    section "Live gateway status"

    if [[ ! -f "$ROOT/.env" ]]; then
        fail ".env not found"
        printf '\n── Results: %d passed  %d failed  %d skipped\n' "$PASS" "$FAIL" "$SKIP"
        [[ "$FAIL" -eq 0 ]]
        return
    fi
    if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null 2>&1; then
        fail "docker compose is required for live gateway status"
        printf '\n── Results: %d passed  %d failed  %d skipped\n' "$PASS" "$FAIL" "$SKIP"
        [[ "$FAIL" -eq 0 ]]
        return
    fi

    set -a
    # shellcheck disable=SC1091
    source "$ROOT/.env"
    set +a

    local sql result status
    sql="select encode(gateway_id, 'hex') || '|' || name || '|online'
from gateway
where last_seen_at is not null
  and (now() - make_interval(secs => stats_interval_secs * 2)) <= last_seen_at
order by last_seen_at desc
limit 1;"

    if result=$(docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" exec -T postgres \
        psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -c "$sql" 2>&1); then
        if [[ -n "$result" ]]; then
            IFS='|' read -r gateway_id name status <<< "$result"
            ok "online gateway: ${gateway_id} ${name} (${status})"
        else
            fail "no gateway with non-null last_seen_at currently computes as online"
        fi
    else
        fail "query live gateway status"
        printf '%s\n' "$result" >&2
    fi

    printf '\n── Results: %d passed  %d failed  %d skipped\n' "$PASS" "$FAIL" "$SKIP"
    [[ "$FAIL" -eq 0 ]]
}

case "${1:-}" in
    "")
        ;;
    --live-gateway-status)
        live_gateway_status
        exit $?
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac

# ── Stash and restore .env and generated/ around the render tests ────────────
ENV_STASH=""; GEN_STASH=""

stash() {
    if [[ -f "$ROOT/.env" ]]; then
        ENV_STASH=$(mktemp)
        cp "$ROOT/.env" "$ENV_STASH"
    fi
    if [[ -d "$ROOT/generated" ]]; then
        GEN_STASH=$(mktemp -d)
        cp -r "$ROOT/generated/." "$GEN_STASH/"
    fi
}

restore() {
    if [[ -n "$ENV_STASH" ]]; then
        cp "$ENV_STASH" "$ROOT/.env"
        rm -f "$ENV_STASH"
    else
        rm -f "$ROOT/.env"
    fi
    if [[ -n "$GEN_STASH" ]]; then
        rm -rf "$ROOT/generated"
        mkdir -p "$ROOT/generated"
        cp -r "$GEN_STASH/." "$ROOT/generated/"
        rm -rf "$GEN_STASH"
    else
        rm -rf "$ROOT/generated"
    fi
}

trap restore EXIT

REGION_IDS=()
REGION_NAMES=()

load_region_metadata() {
    local region_dir="$1"
    local metadata="$region_dir/metadata.env"

    REGION_ID=""
    REGION_NAME=""
    # shellcheck disable=SC2034
    REGION_DISPLAY_NAME=""
    # shellcheck disable=SC2034
    REGION_SETUP_DESCRIPTION=""
    REGION_MENU_ORDER=""
    BS_REGION=""
    BS_FREQ_MIN=""
    BS_FREQ_MAX=""

    if [[ ! -f "$metadata" ]]; then
        return 1
    fi

    # shellcheck disable=SC1090
    source "$metadata"
}

validate_region_modules() {
    local dir region_id
    local required_vars=(
        REGION_ID
        REGION_NAME
        REGION_DISPLAY_NAME
        REGION_SETUP_DESCRIPTION
        REGION_MENU_ORDER
        BS_REGION
        BS_FREQ_MIN
        BS_FREQ_MAX
    )

    REGION_IDS=()
    REGION_NAMES=()

    for dir in "$ROOT"/config/regions/*; do
        [[ -d "$dir" ]] || continue

        if ! load_region_metadata "$dir"; then
            fail "region module metadata: $(basename "$dir")"
            continue
        fi

        region_id="$(basename "$dir")"
        local valid=true
        local var_name
        for var_name in "${required_vars[@]}"; do
            if [[ -z "${!var_name:-}" ]]; then
                fail "region metadata $(basename "$dir"): missing $var_name"
                valid=false
            fi
        done
        if [[ "$valid" != "true" ]]; then
            continue
        fi

        if [[ "$REGION_ID" != "$region_id" ]]; then
            fail "region metadata $(basename "$dir"): REGION_ID does not match directory"
            continue
        fi
        if [[ ! "$REGION_MENU_ORDER" =~ ^[0-9]+$ ]]; then
            fail "region metadata $region_id: REGION_MENU_ORDER must be numeric"
            continue
        fi
        if [[ ! "$BS_FREQ_MIN" =~ ^[0-9]+$ || ! "$BS_FREQ_MAX" =~ ^[0-9]+$ ]]; then
            fail "region metadata $region_id: frequency bounds must be numeric"
            continue
        fi
        if (( BS_FREQ_MIN >= BS_FREQ_MAX )); then
            fail "region metadata $region_id: BS_FREQ_MIN must be lower than BS_FREQ_MAX"
            continue
        fi
        if [[ ! -f "$dir/chirpstack.toml" ]]; then
            fail "region module $region_id: missing chirpstack.toml"
            continue
        fi
        if ! grep -Eq "id[[:space:]]*=[[:space:]]*\"${region_id}\"" "$dir/chirpstack.toml"; then
            fail "region module $region_id: chirpstack.toml id mismatch"
            continue
        fi
        if ! grep -Eq "name[[:space:]]*=[[:space:]]*\"${BS_REGION}\"" "$dir/chirpstack.toml"; then
            fail "region module $region_id: chirpstack.toml band name mismatch"
            continue
        fi
        if ! grep -Eq "common_name[[:space:]]*=[[:space:]]*\"${BS_REGION}\"" "$dir/chirpstack.toml"; then
            fail "region module $region_id: chirpstack.toml common_name mismatch"
            continue
        fi
        if [[ ! -s "$dir/basics-station-concentrators.toml" ]]; then
            fail "region module $region_id: missing Basics Station concentrator TOML"
            continue
        fi
        if ! grep -Fq '[[backend.basic_station.concentrators]]' "$dir/basics-station-concentrators.toml"; then
            fail "region module $region_id: Basics Station concentrator block missing"
            continue
        fi

        REGION_IDS+=("$region_id")
        REGION_NAMES+=("$REGION_NAME")
        ok "region module: $region_id"
    done

    if [[ "${#REGION_IDS[@]}" -eq 0 ]]; then
        fail "no valid region modules found"
    fi
}

# ── 1. Shell linting ─────────────────────────────────────────────────────────
section "Shell linting"

if command -v shellcheck &>/dev/null; then
    for f in \
        "$ROOT/setup.sh" \
        "$ROOT/scripts/generate-config.sh" \
        "$ROOT/scripts/validate.sh" \
        "$ROOT/scripts/renew-ssl.sh" \
        "$ROOT/scripts/backup.sh" \
        "$ROOT/scripts/restore.sh" \
        "$ROOT/scripts/provision-airvibe-sensors.sh"; do
        if shellcheck "$f"; then
            ok "shellcheck $(basename "$f")"
        else
            fail "shellcheck $(basename "$f")"
        fi
    done
else
    skip "shellcheck not installed (apt-get install shellcheck)"
fi

# ── 2. Region modules ────────────────────────────────────────────────────────
section "Region modules"

validate_region_modules

# ── 3. Template rendering ─────────────────────────────────────────────────────
section "Template rendering"

stash

write_env() {
    local region="$1" ssl="$2" monitoring="$3" domain="${4:-}"
    cat > "$ROOT/.env" <<ENV
DEPLOY_MODE=$([ "$ssl" = "true" ] && echo vps || echo local)
DOMAIN=${domain}
SSL_EMAIL=$([ -n "$domain" ] && echo admin@example.com || echo "")
SSL_ENABLED=${ssl}
LORA_REGION=${region}
POSTGRES_USER=chirpstack
POSTGRES_PASSWORD=testpassword
POSTGRES_DB=chirpstack
REDIS_PASSWORD=testpassword
MOSQUITTO_USER=chirpstack
MOSQUITTO_PASSWORD=testpassword
CHIRPSTACK_SECRET=0000000000000000000000000000000000000000000000000000000000000000
CHIRPSTACK_ADMIN_EMAIL=admin@example.com
CHIRPSTACK_ADMIN_PASSWORD=testadminpassword
EXTERNAL_MQTT_SERVER=
EXPOSE_MQTT=false
ENABLE_MONITORING=${monitoring}
GRAFANA_ROOT_URL=$([ -n "$domain" ] && echo "https://${domain}/grafana/" || echo "http://localhost/grafana/")
INFLUXDB_ADMIN_USER=admin
INFLUXDB_ADMIN_PASSWORD=testpassword
INFLUXDB_ORG=chirpstack
INFLUXDB_BUCKET=chirpstack
INFLUXDB_TOKEN=0000000000000000000000000000000000000000000000000000000000000000
HTTP_PORT=80
HTTPS_PORT=443
MQTT_PORT=1883
GATEWAY_UDP_PORT=1700
GATEWAY_BS_PORT=3001
ENV
}

render() {
    local label="$1" region_id="$2"
    local out
    if out=$(bash "$ROOT/scripts/generate-config.sh" 2>&1); then
        ok "render: $label"
        validate_rendered_region "$region_id"
    else
        fail "render: $label"
        printf '%s\n' "$out" >&2
    fi
}

validate_rendered_region() {
    local region_id="$1"
    local region_dir="$ROOT/config/regions/$region_id"
    local chirpstack="$ROOT/generated/chirpstack/chirpstack.toml"
    local region="$ROOT/generated/chirpstack/region.toml"
    local bs="$ROOT/generated/gateway-bridge/bs.toml"
    local expected_concentrators rendered_concentrators

    load_region_metadata "$region_dir"

    if grep -Fq "\"${region_id}\"" "$chirpstack"; then
        ok "rendered enabled region: $region_id"
    else
        fail "rendered enabled region: $region_id"
    fi
    if grep -Fq "event_topic=\"${region_id}/gateway/+/event/+\"" "$region" &&
        grep -Fq "state_topic=\"${region_id}/gateway/+/state/+\"" "$region" &&
        grep -Fq "command_topic=\"${region_id}/gateway/{{gateway_id}}/command/{{command}}\"" "$region"; then
        ok "rendered MQTT topics: $region_id"
    else
        fail "rendered MQTT topics: $region_id"
    fi
    if grep -Fq "region=\"${BS_REGION}\"" "$bs" &&
        grep -Fq "frequency_min=${BS_FREQ_MIN}" "$bs" &&
        grep -Fq "frequency_max=${BS_FREQ_MAX}" "$bs"; then
        ok "rendered Basics Station metadata: $region_id"
    else
        fail "rendered Basics Station metadata: $region_id"
    fi
    expected_concentrators="$(mktemp)"
    rendered_concentrators="$(mktemp)"
    sed -n '/^\[\[backend.basic_station.concentrators\]\]/,$p' \
        "$region_dir/basics-station-concentrators.toml" | sed '/^$/d' > "$expected_concentrators"
    sed -n '/^\[\[backend.basic_station.concentrators\]\]/,/^\[integration\]/{/^\[integration\]/!p}' \
        "$bs" | sed '/^$/d' > "$rendered_concentrators"
    if cmp -s "$expected_concentrators" "$rendered_concentrators"; then
        ok "rendered Basics Station concentrators: $region_id"
    else
        fail "rendered Basics Station concentrators: $region_id"
    fi
    rm -f "$expected_concentrators" "$rendered_concentrators"
}

for idx in "${!REGION_IDS[@]}"; do
    write_env "${REGION_NAMES[$idx]}" false false
    render "${REGION_NAMES[$idx]} / local / no-monitoring" "${REGION_IDS[$idx]}"

    write_env "${REGION_NAMES[$idx]}" true true cs.example.com
    render "${REGION_NAMES[$idx]} / vps  / monitoring" "${REGION_IDS[$idx]}"
done

# ── 4. YAML syntax ───────────────────────────────────────────────────────────
section "YAML syntax"

validate_yaml() {
    local f="$1"
    local err
    if err=$(python3 - "$f" 2>&1 <<'PY'
import yaml, sys
try:
    yaml.safe_load(open(sys.argv[1]))
except yaml.YAMLError as e:
    print(e, file=sys.stderr)
    sys.exit(1)
PY
    ); then
        ok "yaml: $(basename "$f")"
    else
        fail "yaml: $(basename "$f")"
        printf '%s\n' "$err" >&2
    fi
}

validate_json() {
    local f="$1"
    local err
    if err=$(python3 -m json.tool "$f" 2>&1 >/dev/null); then
        ok "json: $(basename "$f")"
    else
        fail "json: $(basename "$f")"
        printf '%s\n' "$err" >&2
    fi
}

validate_gateway_dashboard_sources() {
    local err
    if err=$(python3 - "$ROOT/config/grafana/provisioning/dashboard-files/chirpstack-overview.json" 2>&1 <<'PY'
import json, sys
path = sys.argv[1]
dashboard = json.load(open(path))
panels = {p.get("title"): p for p in dashboard.get("panels", [])}

def datasource_uid(obj):
    ds = obj.get("datasource")
    if isinstance(ds, dict):
        return ds.get("uid")
    return ds

online = panels.get("Gateways Online")
last_seen = panels.get("Gateway Last Seen")
if online is None:
    raise SystemExit("missing Gateways Online panel")
if last_seen is None:
    raise SystemExit("missing Gateway Last Seen panel")
if datasource_uid(online) != "chirpstack-postgres":
    raise SystemExit("Gateways Online panel is not bound to PostgreSQL")
if datasource_uid(last_seen) != "chirpstack-postgres":
    raise SystemExit("Gateway Last Seen panel is not bound to PostgreSQL")
for panel in (online, last_seen):
    for target in panel.get("targets", []):
        if datasource_uid(target) == "chirpstack-influxdb":
            raise SystemExit(f"{panel['title']} target still uses InfluxDB")
        sql = target.get("rawSql", "")
        if "from gateway" not in sql.lower():
            raise SystemExit(f"{panel['title']} target does not query gateway table")
PY
    ); then
        ok "dashboard: gateway status uses PostgreSQL"
    else
        fail "dashboard: gateway status uses PostgreSQL"
        printf '%s\n' "$err" >&2
    fi
}

if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
    validate_yaml "$ROOT/docker-compose.yml"
    validate_yaml "$ROOT/docker-compose.mqtt.yml"
    validate_yaml "$ROOT/docker-compose.monitoring.yml"
    validate_yaml "$ROOT/config/grafana/provisioning/dashboards/dashboards.yml"
    validate_json "$ROOT/config/grafana/provisioning/dashboard-files/chirpstack-overview.json"
    validate_gateway_dashboard_sources
    # Validate rendered datasource (written only when monitoring=true)
    if [[ -f "$ROOT/generated/grafana/provisioning/datasources/influxdb.yml" ]]; then
        validate_yaml "$ROOT/generated/grafana/provisioning/datasources/influxdb.yml"
    fi
    if [[ -f "$ROOT/generated/grafana/provisioning/datasources/postgres.yml" ]]; then
        validate_yaml "$ROOT/generated/grafana/provisioning/datasources/postgres.yml"
    fi
else
    skip "python3 + pyyaml not available (pip install pyyaml)"
fi

# ── 5. Docker Compose config validation ──────────────────────────────────────
section "Docker Compose config"

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    dc_validate() {
        local label="$1"; shift
        local err
        if err=$(docker compose --project-directory "$ROOT" "$@" config --quiet 2>&1); then
            ok "compose config: $label"
        else
            fail "compose config: $label"
            printf '%s\n' "$err" >&2
        fi
    }
    dc_validate "base stack"       -f "$ROOT/docker-compose.yml"
    dc_validate "mqtt stack"       -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.mqtt.yml"
    dc_validate "monitoring stack" -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.monitoring.yml"
    dc_validate "mqtt + monitoring stack" -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.mqtt.yml" -f "$ROOT/docker-compose.monitoring.yml"
else
    skip "docker not available for Compose validation"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n── Results: %d passed  %d failed  %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
