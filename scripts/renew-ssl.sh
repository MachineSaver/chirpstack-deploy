#!/usr/bin/env bash
# Renew Let's Encrypt certificates and reload Nginx.
# Run this via cron: 0 3 * * * /path/to/chirpstack-deploy/scripts/renew-ssl.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ ! -f "$ROOT/.env" ]]; then
    echo "ERROR: .env not found." >&2
    exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a

if [[ "${SSL_ENABLED:-false}" != "true" ]]; then
    echo "SSL is not enabled — nothing to renew."
    exit 0
fi

echo "Renewing certificates for ${DOMAIN}..."

CERTBOT_CERTS_VOLUME="chirpstack_certbot_certs"
CERTBOT_WWW_VOLUME="chirpstack_certbot_www"

for volume in "$CERTBOT_CERTS_VOLUME" "$CERTBOT_WWW_VOLUME"; do
    if ! docker volume inspect "$volume" >/dev/null 2>&1; then
        echo "ERROR: Docker volume not found: $volume" >&2
        echo "Run ./setup.sh in VPS mode before renewing certificates." >&2
        exit 1
    fi
done

docker run --rm \
    -v "${CERTBOT_CERTS_VOLUME}:/etc/letsencrypt" \
    -v "${CERTBOT_WWW_VOLUME}:/var/www/certbot" \
    certbot/certbot:v5.5.0 renew --webroot -w /var/www/certbot --quiet

echo "Reloading Nginx..."
docker compose -f "$ROOT/docker-compose.yml" exec nginx nginx -s reload

echo "Certificate renewal complete."
