#!/usr/bin/env bash
# Create a portable ChirpStack deployment backup.
#
# The archive includes:
# - .env
# - generated runtime config
# - a PostgreSQL logical dump
# - snapshots of Redis, Mosquitto, Certbot, and optional monitoring volumes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="${1:-$ROOT/backups}"
ARCHIVE_IMAGE="${ARCHIVE_IMAGE:-alpine:3.20}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORKDIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

if [[ ! -f "$ROOT/.env" ]]; then
    die ".env not found. Run ./setup.sh first."
fi

require_cmd docker

set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a

COMPOSE_FILES=(-f "$ROOT/docker-compose.yml")
if [[ "${EXPOSE_MQTT:-false}" == "true" ]]; then
    COMPOSE_FILES+=(-f "$ROOT/docker-compose.mqtt.yml")
fi
if [[ "${ENABLE_MONITORING:-false}" == "true" ]]; then
    COMPOSE_FILES+=(-f "$ROOT/docker-compose.monitoring.yml")
fi

dc() {
    docker compose --project-directory "$ROOT" "${COMPOSE_FILES[@]}" "$@"
}

compose_project_name() {
    local name
    name=$(dc config --format json 2>/dev/null | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if [[ -n "$name" ]]; then
        printf '%s\n' "$name"
    else
        basename "$ROOT"
    fi
}

PROJECT_NAME="$(compose_project_name)"

if ! dc ps --services --filter status=running | grep -qx postgres; then
    die "postgres is not running. Start the stack before taking a backup."
fi

mkdir -p "$BACKUP_DIR" "$WORKDIR/files" "$WORKDIR/volumes"
chmod 700 "$WORKDIR"

echo "Creating backup workspace..."
cp "$ROOT/.env" "$WORKDIR/files/env"
chmod 600 "$WORKDIR/files/env"
if [[ ! -d "$ROOT/generated" ]]; then
    "$ROOT/scripts/generate-config.sh" >/dev/null
fi
if [[ -d "$ROOT/generated" ]]; then
    tar -C "$ROOT" -czf "$WORKDIR/files/generated.tar.gz" generated
else
    mkdir -p "$WORKDIR/empty-generated/generated"
    tar -C "$WORKDIR/empty-generated" -czf "$WORKDIR/files/generated.tar.gz" generated
    rm -rf "$WORKDIR/empty-generated"
fi

echo "Dumping PostgreSQL..."
dc exec -T postgres pg_dump \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    --format=custom \
    --no-owner \
    --no-acl \
    > "$WORKDIR/postgres.dump"

archive_volume() {
    local name="$1"
    local volume="${PROJECT_NAME}_${name}"

    if ! docker volume inspect "$volume" >/dev/null 2>&1; then
        echo "  [skip] volume not found: $volume"
        return
    fi

    echo "  [ok]   archiving volume: $volume"
    docker run --rm \
        -v "$volume:/volume:ro" \
        -v "$WORKDIR/volumes:/backup" \
        "$ARCHIVE_IMAGE" \
        sh -c "cd /volume && tar czf /backup/${name}.tar.gz ."
}

echo "Snapshotting Redis before archiving its volume..."
dc exec -T redis redis-cli \
    -a "$REDIS_PASSWORD" \
    --no-auth-warning \
    SAVE >/dev/null

echo "Archiving Docker volumes..."
archive_volume redis_data
archive_volume mosquitto_data
archive_volume certbot_www
archive_volume certbot_certs

if [[ "${ENABLE_MONITORING:-false}" == "true" ]]; then
    archive_volume influxdb_data
    archive_volume influxdb_config
    archive_volume grafana_data
fi

cat > "$WORKDIR/manifest.env" <<MANIFEST
BACKUP_FORMAT=chirpstack-compose-v1
CREATED_AT_UTC=$TIMESTAMP
PROJECT_NAME=$PROJECT_NAME
DEPLOY_MODE=${DEPLOY_MODE:-}
LORA_REGION=${LORA_REGION:-}
SSL_ENABLED=${SSL_ENABLED:-false}
EXPOSE_MQTT=${EXPOSE_MQTT:-false}
ENABLE_MONITORING=${ENABLE_MONITORING:-false}
MANIFEST

ARCHIVE="$BACKUP_DIR/chirpstack-backup-$TIMESTAMP.tar.gz"
tar -C "$WORKDIR" -czf "$ARCHIVE" .
chmod 600 "$ARCHIVE"

echo
echo "Backup created: $ARCHIVE"
