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

# shellcheck disable=SC1091
set -a; source "$ROOT/.env"; set +a

if [[ "${SSL_ENABLED:-false}" != "true" ]]; then
    echo "SSL is not enabled — nothing to renew."
    exit 0
fi

echo "Renewing certificates for ${DOMAIN}..."

docker run --rm \
    -v "$(docker volume ls -q | grep certbot_certs || echo chirpstack_certbot_certs):/etc/letsencrypt" \
    -v "$(docker volume ls -q | grep certbot_www || echo chirpstack_certbot_www):/var/www/certbot" \
    certbot/certbot renew --webroot -w /var/www/certbot --quiet

echo "Reloading Nginx..."
docker compose -f "$ROOT/docker-compose.yml" exec nginx nginx -s reload

echo "Certificate renewal complete."
