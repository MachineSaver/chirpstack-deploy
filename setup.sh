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
        if [[ "$SSL_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
            break
        fi
        warn "That doesn't look like a valid email address. Try again."
    done
fi

# ── Step 4: LoRa Region ──────────────────────────────────────────────────────
header "LoRa frequency region"
echo "  [1] US915 — Americas (915 MHz)"
echo "  [2] EU868 — Europe   (868 MHz)"
echo ""
read -rp "  Select [1/2]: " REGION_CHOICE

case "$REGION_CHOICE" in
    1) LORA_REGION="US915" ;;
    2) LORA_REGION="EU868" ;;
    *)
        error "Invalid choice."
        exit 1
        ;;
esac
success "Region: $LORA_REGION"

# ── Step 5: Admin account ────────────────────────────────────────────────────
header "Admin account"
echo "  This creates the initial administrator account for the ChirpStack web UI."
echo ""
while true; do
    read -rp "  Admin email: " CHIRPSTACK_ADMIN_EMAIL
    if [[ "$CHIRPSTACK_ADMIN_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        break
    fi
    warn "Invalid email address. Try again."
done

# ── Step 6: Monitoring stack ─────────────────────────────────────────────────
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

# ── Step 7: Generate secrets ─────────────────────────────────────────────────
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

# ── Step 8: Write .env ───────────────────────────────────────────────────────
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

ENABLE_MONITORING=${ENABLE_MONITORING}
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

# ── Step 9: Generate configs ─────────────────────────────────────────────────
header "Rendering configuration files"
bash scripts/generate-config.sh

# ── Step 10: Generate Mosquitto password file ────────────────────────────────
info "Generating Mosquitto credentials..."
# Use a temp container — avoids needing mosquitto_passwd installed on the host
docker run --rm \
    -v "$SCRIPT_DIR/config/mosquitto:/mosquitto/config" \
    eclipse-mosquitto:2 \
    sh -c "mosquitto_passwd -b -c /mosquitto/config/passwd chirpstack '${MOSQUITTO_PASSWORD}'"
chmod 644 config/mosquitto/passwd
success "Mosquitto passwd file created"

# ── Step 11: SSL certificate (VPS mode) ──────────────────────────────────────
if [[ "$SSL_ENABLED" == "true" ]]; then
    header "Obtaining SSL certificate"
    info "Starting Nginx temporarily for ACME HTTP challenge..."

    # Start only nginx (in HTTP-only mode — https.conf.tmpl still has the
    # /.well-known/acme-challenge block in the HTTP server block)
    docker compose up -d nginx

    info "Running Certbot..."
    docker run --rm \
        -v "chirpstack_certbot_certs:/etc/letsencrypt" \
        -v "chirpstack_certbot_www:/var/www/certbot" \
        certbot/certbot certonly \
            --webroot \
            --webroot-path /var/www/certbot \
            --email "${SSL_EMAIL}" \
            --agree-tos \
            --no-eff-email \
            -d "${DOMAIN}"

    success "Certificate obtained for ${DOMAIN}"

    info "Reloading Nginx with HTTPS config..."
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

# ── Step 12: Start the stack ─────────────────────────────────────────────────
header "Starting ChirpStack"

COMPOSE_CMD="docker compose -f docker-compose.yml"
if [[ "$ENABLE_MONITORING" == "true" ]]; then
    COMPOSE_CMD="$COMPOSE_CMD -f docker-compose.monitoring.yml"
fi

$COMPOSE_CMD up -d

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

# ── Step 13: Print summary ───────────────────────────────────────────────────
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
echo "  Server:   ${BASE_URL/http/mqtt}:1883"
echo "  User:     chirpstack"
echo "  Password: ${MOSQUITTO_PASSWORD}"
echo ""
echo -e "${BOLD}Firewall — open these ports on your server:${NC}"
echo "  80/tcp   (HTTP)"
[[ "$SSL_ENABLED" == "true" ]] && echo "  443/tcp  (HTTPS)"
echo "  1700/udp (LoRa UDP gateway forwarder)"
echo "  1883/tcp (MQTT)"
echo "  3001/tcp (Basics Station WebSocket)"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Log in to the web UI and change your admin password"
echo "  2. Add a Network Server gateway (Gateways → Add gateway)"
echo "  3. Create a Device Profile matching your sensor's LoRaWAN version"
echo "  4. Create an Application and register your devices"
echo ""
echo "  Logs:       docker compose logs -f chirpstack"
echo "  Stop stack: docker compose down"
echo "  Restart:    docker compose up -d"
echo ""
