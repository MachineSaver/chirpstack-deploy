#!/usr/bin/env bash
# ChirpStack v4 — Interactive Setup Script
# Guides users through configuration and starts the stack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}  ▸ $*${NC}"; }
success() { echo -e "${GREEN}  ✔ $*${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
error()   { echo -e "${RED}  ✘ $*${NC}" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }
valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

discover_regions() {
    REGION_IDS=()
    REGION_NAMES=()
    REGION_DISPLAY_NAMES=()

    local dir metadata
    while IFS='|' read -r _order region_id region_name display_name _setup_description; do
        REGION_IDS+=("$region_id")
        REGION_NAMES+=("$region_name")
        REGION_DISPLAY_NAMES+=("$display_name")
    done < <(
        for dir in "$SCRIPT_DIR"/config/regions/*; do
            [[ -d "$dir" ]] || continue
            metadata="$dir/metadata.env"
            [[ -f "$metadata" ]] || continue

            REGION_ID=""
            REGION_NAME=""
            REGION_DISPLAY_NAME=""
            REGION_SETUP_DESCRIPTION=""
            REGION_MENU_ORDER=""
            # shellcheck disable=SC1090
            source "$metadata"

            [[ -n "$REGION_ID" ]] || continue
            [[ -n "$REGION_NAME" ]] || continue
            [[ -n "$REGION_DISPLAY_NAME" ]] || continue
            [[ -n "$REGION_SETUP_DESCRIPTION" ]] || continue
            [[ -n "$REGION_MENU_ORDER" ]] || continue
            [[ "$REGION_ID" == "$(basename "$dir")" ]] || continue

            printf '%s|%s|%s|%s|%s\n' "$REGION_MENU_ORDER" "$REGION_ID" "$REGION_NAME" "$REGION_DISPLAY_NAME" "$REGION_SETUP_DESCRIPTION"
        done | sort -n -t '|' -k1,1
    )

    if [[ "${#REGION_IDS[@]}" -eq 0 ]]; then
        error "No valid region modules found in config/regions."
        exit 1
    fi
}

# ── Step 1: Prerequisites ────────────────────────────────────────────────────
header "Checking prerequisites"

check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        error "Required tool not found: $1"
        echo "  Please install Docker and Docker Compose v2, then re-run this script."
        echo "  → https://docs.docker.com/engine/install/"
        exit 1
    fi
}

check_cmd docker
check_cmd openssl
check_cmd envsubst

# Ensure Docker Compose v2 (plugin style)
if ! docker compose version &>/dev/null 2>&1; then
    error "Docker Compose v2 plugin not found."
    echo "  Install it with: apt-get install docker-compose-plugin"
    echo "  → https://docs.docker.com/compose/install/"
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    error "Docker daemon is not running, or you don't have permission."
    echo "  Try: sudo usermod -aG docker \$USER  (then log out and back in)"
    exit 1
fi

success "Docker $(docker --version | awk '{print $3}' | tr -d ',')"
success "Docker Compose $(docker compose version --short)"

if [[ -f .env ]]; then
    header "Existing configuration detected"
    warn ".env already exists. Re-running setup will generate new secrets."
    warn "Use scripts/generate-config.sh if you only need to re-render config files."
    echo ""
    read -rp "  Type OVERWRITE to replace .env, or press Enter to exit: " OVERWRITE_CONFIRM
    if [[ "$OVERWRITE_CONFIRM" != "OVERWRITE" ]]; then
        info "Setup cancelled. Existing .env was left unchanged."
        exit 0
    fi
    ENV_BACKUP=".env.$(date -u +%Y%m%d%H%M%S).bak"
    cp .env "$ENV_BACKUP"
    success "Backed up existing .env to ${ENV_BACKUP}"
fi

# ── Step 2: Deployment type ──────────────────────────────────────────────────
header "Deployment type"
echo "  [1] VPS with domain name  (HTTPS via Let's Encrypt — recommended for internet-facing servers)"
echo "  [2] Local network         (HTTP only — home lab, office network, no domain needed)"
echo ""
read -rp "  Select [1/2]: " DEPLOY_CHOICE

case "$DEPLOY_CHOICE" in
    1)
        DEPLOY_MODE="vps"
        SSL_ENABLED="true"
        ;;
    2)
        DEPLOY_MODE="local"
        SSL_ENABLED="false"
        ;;
    *)
        error "Invalid choice. Run the script again."
        exit 1
        ;;
esac

# ── Step 3: Domain & email (VPS only) ────────────────────────────────────────
DOMAIN=""
SSL_EMAIL=""

if [[ "$DEPLOY_MODE" == "vps" ]]; then
    header "Domain configuration"
    echo "  Enter the domain name pointing to this server."
    echo "  Example: chirpstack.example.com"
    echo ""
    while true; do
        read -rp "  Domain: " DOMAIN
        # Basic validation: must contain a dot and no spaces
        if [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        fi
        warn "That doesn't look like a valid domain name. Try again."
    done

    echo ""
    echo "  Email address for Let's Encrypt certificate notifications:"
    while true; do
        read -rp "  Email: " SSL_EMAIL
        if valid_email "$SSL_EMAIL"; then
            break
        fi
        warn "That doesn't look like a valid email address. Try again."
    done
fi

# ── Step 4: LoRa Region ──────────────────────────────────────────────────────
header "LoRa frequency region"
discover_regions
for idx in "${!REGION_IDS[@]}"; do
    printf '  [%d] %s\n' "$((idx + 1))" "${REGION_DISPLAY_NAMES[$idx]}"
done
echo ""
read -rp "  Select [1-${#REGION_IDS[@]}]: " REGION_CHOICE

if [[ ! "$REGION_CHOICE" =~ ^[0-9]+$ ]] ||
    (( REGION_CHOICE < 1 || REGION_CHOICE > ${#REGION_IDS[@]} )); then
    error "Invalid choice."
    exit 1
fi
LORA_REGION="${REGION_NAMES[$((REGION_CHOICE - 1))]}"
success "Region: $LORA_REGION"

# ── Step 5: Admin account ────────────────────────────────────────────────────
header "Admin account"
echo "  This creates the initial administrator account for the ChirpStack web UI."
echo ""
while true; do
    read -rp "  Admin email: " CHIRPSTACK_ADMIN_EMAIL
    if valid_email "$CHIRPSTACK_ADMIN_EMAIL"; then
        break
    fi
    warn "Invalid email address. Try again."
done

# ── Step 6: Optional host MQTT access ────────────────────────────────────────
header "Optional MQTT host access"
echo "  ChirpStack uses Mosquitto internally either way."
echo "  Expose port 1883 only if external MQTT clients must connect directly."
echo ""
read -rp "  Expose MQTT on the host? [y/N]: " MQTT_CHOICE
if [[ "${MQTT_CHOICE,,}" == "y" ]]; then
    EXPOSE_MQTT="true"
else
    EXPOSE_MQTT="false"
fi

# ── Step 7: Monitoring stack ─────────────────────────────────────────────────
header "Optional monitoring (Grafana + InfluxDB)"
echo "  Adds a Grafana dashboard and InfluxDB metrics database."
echo "  Accessible at http(s)://HOST/grafana/ after setup."
echo ""
read -rp "  Enable monitoring? [y/N]: " MON_CHOICE
if [[ "${MON_CHOICE,,}" == "y" ]]; then
    ENABLE_MONITORING="true"
else
    ENABLE_MONITORING="false"
fi

if [[ "$SSL_ENABLED" == "true" ]]; then
    GRAFANA_ROOT_URL="https://${DOMAIN}/grafana/"
else
    GRAFANA_ROOT_URL="http://localhost/grafana/"
fi

# ── Step 8: Generate secrets ─────────────────────────────────────────────────
header "Generating secrets"

gen_secret() { openssl rand -hex "$1"; }
gen_pass()   { openssl rand -base64 "$1" | tr -dc 'A-Za-z0-9' | head -c "$1"; }

POSTGRES_PASSWORD="$(gen_secret 16)"
REDIS_PASSWORD="$(gen_secret 16)"
MOSQUITTO_PASSWORD="$(gen_secret 16)"
CHIRPSTACK_SECRET="$(gen_secret 32)"
CHIRPSTACK_ADMIN_PASSWORD="$(gen_pass 16)"
INFLUXDB_ADMIN_PASSWORD="$(gen_pass 16)"
INFLUXDB_TOKEN="$(gen_secret 32)"

success "All secrets generated"

# ── Step 9: Write .env ───────────────────────────────────────────────────────
header "Writing configuration"

cat > .env <<EOF
# Generated by setup.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# Do not commit this file to version control.

DEPLOY_MODE=${DEPLOY_MODE}
DOMAIN=${DOMAIN}
SSL_EMAIL=${SSL_EMAIL}
SSL_ENABLED=${SSL_ENABLED}

LORA_REGION=${LORA_REGION}

POSTGRES_USER=chirpstack
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=chirpstack

REDIS_PASSWORD=${REDIS_PASSWORD}

MOSQUITTO_USER=chirpstack
MOSQUITTO_PASSWORD=${MOSQUITTO_PASSWORD}

CHIRPSTACK_SECRET=${CHIRPSTACK_SECRET}
CHIRPSTACK_ADMIN_EMAIL=${CHIRPSTACK_ADMIN_EMAIL}
CHIRPSTACK_ADMIN_PASSWORD=${CHIRPSTACK_ADMIN_PASSWORD}

EXTERNAL_MQTT_SERVER=
EXPOSE_MQTT=${EXPOSE_MQTT}

ENABLE_MONITORING=${ENABLE_MONITORING}
GRAFANA_ROOT_URL=${GRAFANA_ROOT_URL}
INFLUXDB_ADMIN_USER=admin
INFLUXDB_ADMIN_PASSWORD=${INFLUXDB_ADMIN_PASSWORD}
INFLUXDB_ORG=chirpstack
INFLUXDB_BUCKET=chirpstack
INFLUXDB_TOKEN=${INFLUXDB_TOKEN}

HTTP_PORT=80
HTTPS_PORT=443
MQTT_PORT=1883
GATEWAY_UDP_PORT=1700
GATEWAY_BS_PORT=3001
EOF

success ".env written"

# ── Step 10: Generate configs ────────────────────────────────────────────────
header "Rendering configuration files"
bash scripts/generate-config.sh

# ── Step 11: Generate Mosquitto password file ────────────────────────────────
info "Generating Mosquitto credentials..."
mkdir -p "$SCRIPT_DIR/generated/mosquitto"
# Use a temp container — avoids needing mosquitto_passwd installed on the host
docker run --rm \
    -v "$SCRIPT_DIR/generated/mosquitto:/mosquitto/config" \
    eclipse-mosquitto:2.0.22 \
    sh -c "mosquitto_passwd -b -c /mosquitto/config/passwd chirpstack '${MOSQUITTO_PASSWORD}'"
chmod 644 "$SCRIPT_DIR/generated/mosquitto/passwd"
success "Mosquitto passwd file created"

# ── Step 12: SSL certificate (VPS mode) ──────────────────────────────────────
if [[ "$SSL_ENABLED" == "true" ]]; then
    header "Obtaining SSL certificate"
    info "Starting Nginx temporarily for ACME HTTP challenge..."

    # Start Nginx with an HTTP-only config for first issuance. The normal HTTPS
    # config references certificate files that do not exist until Certbot runs.
    envsubst '${DOMAIN} ${GATEWAY_BS_PORT}' < "$SCRIPT_DIR/config/nginx/http.conf.tmpl" \
        > "$SCRIPT_DIR/generated/nginx/nginx.conf"
    docker compose up -d nginx

    info "Running Certbot..."
    docker run --rm \
        -v "chirpstack_certbot_certs:/etc/letsencrypt" \
        -v "chirpstack_certbot_www:/var/www/certbot" \
        certbot/certbot:v5.5.0 certonly \
            --webroot \
            --webroot-path /var/www/certbot \
            --email "${SSL_EMAIL}" \
            --agree-tos \
            --no-eff-email \
            -d "${DOMAIN}"

    success "Certificate obtained for ${DOMAIN}"

    info "Reloading Nginx with HTTPS config..."
    bash scripts/generate-config.sh
    docker compose exec nginx nginx -s reload 2>/dev/null || docker compose restart nginx

    # Set up auto-renewal cron (if crontab is available)
    if command -v crontab &>/dev/null; then
        CRON_CMD="0 3 * * * ${SCRIPT_DIR}/scripts/renew-ssl.sh >> /var/log/chirpstack-ssl-renew.log 2>&1"
        ( crontab -l 2>/dev/null | grep -v "renew-ssl.sh"; echo "$CRON_CMD" ) | crontab -
        success "Auto-renewal cron job added (daily at 03:00)"
    else
        warn "crontab not available — remember to schedule scripts/renew-ssl.sh to run periodically."
    fi
fi

# ── Step 13: Start the stack ─────────────────────────────────────────────────
header "Starting ChirpStack"

COMPOSE_CMD=(docker compose -f docker-compose.yml)
if [[ "$EXPOSE_MQTT" == "true" ]]; then
    COMPOSE_CMD+=(-f docker-compose.mqtt.yml)
fi
if [[ "$ENABLE_MONITORING" == "true" ]]; then
    COMPOSE_CMD+=(-f docker-compose.monitoring.yml)
fi

"${COMPOSE_CMD[@]}" up -d

# Wait for ChirpStack health endpoint
info "Waiting for ChirpStack to be ready..."
READY=false
for i in $(seq 1 20); do
    if docker compose exec -T chirpstack wget -qO- http://127.0.0.1:8070/health &>/dev/null; then
        READY=true
        break
    fi
    echo -n "."
    sleep 3
done
echo ""

if [[ "$READY" != "true" ]]; then
    warn "ChirpStack did not respond within 60 seconds."
    warn "Check logs with: docker compose logs chirpstack"
else
    success "ChirpStack is up"
fi

# ── Step 14: Set admin credentials ──────────────────────────────────────────
# ChirpStack seeds a default admin user (email: admin, password: admin).
# We update it to match the values collected above.
if [[ "$READY" == "true" ]]; then
    header "Configuring admin account"

    ADMIN_OK=true

    # Copy the generated password into the service container; remove it when done.
    # Use Compose service addressing instead of assuming a container name.
    if ! printf '%s' "${CHIRPSTACK_ADMIN_PASSWORD}" | docker compose exec -T chirpstack sh -c 'cat > /tmp/cs-admin-pw'; then
        warn "Could not copy admin password into the ChirpStack container."
        ADMIN_OK=false
    fi

    # Set password on the seeded 'admin' account
    if [[ "$ADMIN_OK" == "true" ]] && ! docker compose exec -T chirpstack \
            chirpstack -c /etc/chirpstack set-password \
            --email admin \
            --password-file /tmp/cs-admin-pw; then
        warn "Could not set admin password — account may still use the default password."
        ADMIN_OK=false
    fi

    # Update email in the database. Admin email validation above restricts this
    # to conventional address characters before it reaches SQL.
    UPDATED_EMAIL=""
    if ! UPDATED_EMAIL=$(docker compose exec -T postgres \
            psql -U "${POSTGRES_USER}" "${POSTGRES_DB}" -tAc \
            "UPDATE \"user\" SET email='${CHIRPSTACK_ADMIN_EMAIL}' WHERE is_admin=true RETURNING email;"); then
        warn "Could not update admin email — account may still be reachable as 'admin'."
        ADMIN_OK=false
    elif [[ "$UPDATED_EMAIL" != "$CHIRPSTACK_ADMIN_EMAIL" ]]; then
        warn "Admin email update did not affect the expected admin account."
        ADMIN_OK=false
    fi

    docker compose exec -T chirpstack rm -f /tmp/cs-admin-pw 2>/dev/null || true

    if [[ "$ADMIN_OK" == "true" ]]; then
        success "Admin account configured: ${CHIRPSTACK_ADMIN_EMAIL}"
    else
        warn "Admin setup had errors — log in as 'admin' / '${CHIRPSTACK_ADMIN_PASSWORD}'"
        warn "Then set email to '${CHIRPSTACK_ADMIN_EMAIL}' under Profile in the web UI."
    fi
fi

# ── Step 15: Provision AirVibe device profiles ───────────────────────────────
if [[ "${READY:-false}" == "true" ]] && [[ "${ADMIN_OK:-false}" == "true" ]]; then
    header "Provisioning AirVibe device profiles"
    if bash "$SCRIPT_DIR/scripts/provision-devices.sh"; then
        success "AirVibe device profiles ready"
    else
        warn "Device profile provisioning failed — run manually after setup:"
        warn "  bash scripts/provision-devices.sh"
        warn "(Requires: sudo apt-get install curl jq)"
    fi
fi

# ── Step 16: Print summary ───────────────────────────────────────────────────
if [[ "$SSL_ENABLED" == "true" ]]; then
    BASE_URL="https://${DOMAIN}"
else
    HOST_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "YOUR_SERVER_IP")
    BASE_URL="http://${HOST_IP}"
fi

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║          ChirpStack is ready!                        ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Web UI:${NC}         ${BASE_URL}/"
echo -e "${BOLD}REST API:${NC}       ${BASE_URL}/api/"
[[ "$ENABLE_MONITORING" == "true" ]] && \
echo -e "${BOLD}Grafana:${NC}        ${BASE_URL}/grafana/"
echo ""
echo -e "${BOLD}Admin email:${NC}    ${CHIRPSTACK_ADMIN_EMAIL}"
echo -e "${BOLD}Admin password:${NC} ${CHIRPSTACK_ADMIN_PASSWORD}"
echo ""
echo -e "${BOLD}Gateway endpoints:${NC}"
if [[ "$SSL_ENABLED" == "true" ]]; then
    echo "  Semtech UDP:    ${DOMAIN}:1700  (UDP)"
    echo "  Basics Station: wss://${DOMAIN}:3001"
else
    echo "  Semtech UDP:    ${HOST_IP:-YOUR_IP}:1700  (UDP)"
    echo "  Basics Station: ws://${HOST_IP:-YOUR_IP}:3001"
fi
echo ""
echo -e "${BOLD}MQTT (for integrations):${NC}"
if [[ "$EXPOSE_MQTT" == "true" ]]; then
    echo "  Server:   ${BASE_URL/http/mqtt}:1883"
    echo "  User:     chirpstack"
    echo "  Password: ${MOSQUITTO_PASSWORD}"
else
    echo "  Host access disabled. Internal MQTT is still available to stack services."
    echo "  Set EXPOSE_MQTT=true and include docker-compose.mqtt.yml to allow direct clients."
fi
echo ""
echo -e "${BOLD}Firewall — open these ports on your server:${NC}"
echo "  80/tcp   (HTTP)"
[[ "$SSL_ENABLED" == "true" ]] && echo "  443/tcp  (HTTPS)"
echo "  1700/udp (LoRa UDP gateway forwarder)"
[[ "$EXPOSE_MQTT" == "true" ]] && echo "  1883/tcp (MQTT, optional host access)"
echo "  3001/tcp (Basics Station WebSocket)"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Log in to the web UI with the credentials above"
echo "  2. Add a gateway (Gateways → Add gateway)"
echo "  3. Create an Application and register your AirVibe devices"
echo "     Device profiles 'AirVibe ${LORA_REGION}' and 'AirVibe ${LORA_REGION} FUOTA' are pre-provisioned."
echo "     Use the FUOTA profile only when running a firmware update session."
echo ""
echo "  Logs:       docker compose logs -f chirpstack"
echo "  Stop stack: docker compose down"
echo "  Restart:    ${COMPOSE_CMD[*]} up -d"
echo ""
