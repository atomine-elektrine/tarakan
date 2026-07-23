#!/usr/bin/env bash
# Dump Postgres and hosted bare repos under APP_DIR/backups.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${APP_DIR:-/opt/tarakan}"
if [[ -d "$APP_DIR/scripts/deploy" ]]; then
  :
elif [[ -d "$ROOT_DIR/scripts/deploy" ]]; then
  APP_DIR="$ROOT_DIR"
fi

BACKUP_DIR="${BACKUP_DIR:-$APP_DIR/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
COMPOSE_FILE="${COMPOSE_FILE:-$APP_DIR/deploy/docker/compose.yml}"

cd "$APP_DIR"
# Backups are shared only between the service account and the deployment
# account through the private linuxuser group.
umask 007

set -a
# shellcheck disable=SC1091
. "$APP_DIR/.env"
set +a

mkdir -p "$BACKUP_DIR"
test -f "$COMPOSE_FILE"

# The systemd timer and a deployment can request a backup at the same time.
exec 8> "$BACKUP_DIR/.backup.lock"
flock 8

timestamp="$(date -u +%Y%m%dT%H%M%S%NZ)"
partial="$BACKUP_DIR/.backup-$timestamp.partial"
complete="$BACKUP_DIR/backup-$timestamp"

rm -rf "$partial"
mkdir "$partial"

cleanup() {
  rm -rf "$partial"
}
trap cleanup EXIT HUP INT TERM

compose() {
  docker compose \
    --project-directory "$APP_DIR" \
    -f "$COMPOSE_FILE" \
    --env-file "$APP_DIR/.env" \
    "$@"
}

compose exec -T db pg_dump \
  --username "$POSTGRES_USER" \
  --dbname "${POSTGRES_DB:-tarakan}" \
  --format custom \
  --compress 6 \
  > "$partial/database.dump"

compose exec -T db pg_restore --list \
  < "$partial/database.dump" \
  > /dev/null

compose exec -T app tar \
  --create \
  --gzip \
  --file - \
  --directory /app/storage/hosted \
  . \
  > "$partial/hosted.tar.gz"

tar --list --gzip --file "$partial/hosted.tar.gz" > /dev/null

(
  cd "$partial"
  sha256sum database.dump hosted.tar.gz > SHA256SUMS
)

mv "$partial" "$complete"
trap - EXIT HUP INT TERM

find "$BACKUP_DIR" \
  -mindepth 1 \
  -maxdepth 1 \
  -type d \
  -name 'backup-*' \
  -mtime "+$RETENTION_DAYS" \
  -exec rm -rf -- {} +

printf 'Created %s\n' "$complete"
