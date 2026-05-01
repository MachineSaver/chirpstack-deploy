#!/usr/bin/env bash
# Restore a backup created by scripts/backup.sh.
#
# This stops the Compose stack, replaces .env/generated, recreates the
# PostgreSQL volume, restores the PostgreSQL dump, restores volume snapshots,
# regenerates runtime config, and starts the restored stack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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

usage() {
    cat <<USAGE
Usage: $0 BACKUP_ARCHIVE

Restores a backup created by scripts/backup.sh.
This replaces the current .env, generated config, PostgreSQL data, and backed-up Docker volumes.
USAGE
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

BACKUP_ARCHIVE="${1:-}"
[[ -n "$BACKUP_ARCHIVE" ]] || { usage; exit 1; }
[[ -f "$BACKUP_ARCHIVE" ]] || die "backup archive not found: $BACKUP_ARCHIVE"

require_cmd docker

echo "Extracting backup..."
tar -C "$WORKDIR" -xzf "$BACKUP_ARCHIVE"

[[ -f "$WORKDIR/manifest.env" ]] || die "manifest.env missing from backup"
[[ -f "$WORKDIR/files/env" ]] || die ".env payload missing from backup"
[[ -f "$WORKDIR/files/generated.tar.gz" ]] || die "generated config payload missing from backup"
[[ -f "$WORKDIR/postgres.dump" ]] || die "postgres.dump missing from backup"

# shellcheck disable=SC1090
source "$WORKDIR/manifest.env"
[[ "${BACKUP_FORMAT:-}" == "chirpstack-compose-v1" ]] || die "unsupported backup format: ${BACKUP_FORMAT:-unknown}"

echo
echo "About to restore backup created at: ${CREATED_AT_UTC:-unknown}"
echo "This will stop the stack and replace the current deployment state."
read -r -p "Type RESTORE to continue: " CONFIRM
[[ "$CONFIRM" == "RESTORE" ]] || die "restore cancelled"

STASH_DIR="$ROOT/backups/pre-restore-$TIMESTAMP"
mkdir -p "$STASH_DIR"
if [[ -f "$ROOT/.env" ]]; then
    cp "$ROOT/.env" "$STASH_DIR/env.before-restore"
fi
if [[ -d "$ROOT/generated" ]]; then
    tar -C "$ROOT" -czf "$STASH_DIR/generated.before-restore.tar.gz" generated
fi

cp "$WORKDIR/files/env" "$ROOT/.env"
chmod 600 "$ROOT/.env"

rm -rf "$ROOT/generated"
tar -C "$ROOT" -xzf "$WORKDIR/files/generated.tar.gz"

# shellcheck disable=SC1091
set -a; source "$ROOT/.env"; set +a

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

restore_volume() {
    local name="$1"
    local archive="$WORKDIR/volumes/${name}.tar.gz"
    local volume="${PROJECT_NAME}_${name}"

    if [[ ! -f "$archive" ]]; then
        echo "  [skip] volume archive not present: $name"
        return
    fi

    echo "  [ok]   restoring volume: $volume"
    docker volume inspect "$volume" >/dev/null 2>&1 || docker volume create "$volume" >/dev/null
    docker run --rm \
        -v "$volume:/volume" \
        -v "$archive:/backup.tar.gz:ro" \
        "$ARCHIVE_IMAGE" \
        sh -c "cd /volume && tar xzf /backup.tar.gz"
}

remove_volume_if_archived() {
    local name="$1"
    if [[ -f "$WORKDIR/volumes/${name}.tar.gz" ]]; then
        docker volume rm -f "${PROJECT_NAME}_${name}" >/dev/null 2>&1 || true
    fi
}

wait_for_postgres() {
    local i
    for i in {1..60}; do
        if dc exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

echo "Stopping stack..."
dc down --remove-orphans

echo "Recreating Compose volumes..."
remove_volume_if_archived redis_data
remove_volume_if_archived mosquitto_data
remove_volume_if_archived certbot_www
remove_volume_if_archived certbot_certs
remove_volume_if_archived influxdb_data
remove_volume_if_archived influxdb_config
remove_volume_if_archived grafana_data
docker volume rm -f "${PROJECT_NAME}_postgres_data" >/dev/null 2>&1 || true
dc create >/dev/null

echo "Restoring non-PostgreSQL volumes..."
restore_volume redis_data
restore_volume mosquitto_data
restore_volume certbot_www
restore_volume certbot_certs
restore_volume influxdb_data
restore_volume influxdb_config
restore_volume grafana_data

echo "Starting PostgreSQL with recreated volume..."
dc up -d postgres
wait_for_postgres || die "postgres did not become ready"

echo "Restoring PostgreSQL dump..."
dc exec -T postgres pg_restore \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    --clean \
    --if-exists \
    --no-owner \
    < "$WORKDIR/postgres.dump"

echo "Regenerating runtime config..."
"$ROOT/scripts/generate-config.sh" >/dev/null

echo "Starting restored stack..."
dc up -d

echo
echo "Restore complete."
echo "Previous local .env/generated copies, if present, were saved under: $STASH_DIR"
