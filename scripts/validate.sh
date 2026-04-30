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

# ── 1. Shell linting ─────────────────────────────────────────────────────────
section "Shell linting"

if command -v shellcheck &>/dev/null; then
    for f in "$ROOT/setup.sh" "$ROOT/scripts/generate-config.sh" "$ROOT/scripts/renew-ssl.sh"; do
        if shellcheck "$f"; then
            ok "shellcheck $(basename "$f")"
        else
            fail "shellcheck $(basename "$f")"
        fi
    done
else
    skip "shellcheck not installed (apt-get install shellcheck)"
fi

# ── 2. Template rendering ─────────────────────────────────────────────────────
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
ENABLE_MONITORING=${monitoring}
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
    local label="$1"
    local out
    if out=$(bash "$ROOT/scripts/generate-config.sh" 2>&1); then
        ok "render: $label"
    else
        fail "render: $label"
        printf '%s\n' "$out" >&2
    fi
}

write_env US915 false false;                   render "US915 / local / no-monitoring"
write_env EU868 false false;                   render "EU868 / local / no-monitoring"
write_env US915 true  true  cs.example.com;    render "US915 / vps  / monitoring"
write_env EU868 true  true  cs.example.com;    render "EU868 / vps  / monitoring"

# ── 3. YAML syntax ───────────────────────────────────────────────────────────
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

if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
    validate_yaml "$ROOT/docker-compose.yml"
    validate_yaml "$ROOT/docker-compose.monitoring.yml"
    validate_yaml "$ROOT/config/grafana/provisioning/dashboards/dashboards.yml"
    # Validate rendered datasource (written only when monitoring=true)
    if [[ -f "$ROOT/generated/grafana/provisioning/datasources/influxdb.yml" ]]; then
        validate_yaml "$ROOT/generated/grafana/provisioning/datasources/influxdb.yml"
    fi
else
    skip "python3 + pyyaml not available (pip install pyyaml)"
fi

# ── 4. Docker Compose config validation ──────────────────────────────────────
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
    dc_validate "monitoring stack" -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.monitoring.yml"
else
    skip "docker not available for Compose validation"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n── Results: %d passed  %d failed  %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
