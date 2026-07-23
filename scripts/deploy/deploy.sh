#!/usr/bin/env bash
# Activate a pre-built Tarakan image on the host (called after CI rsync).
# Usage: scripts/deploy/deploy.sh IMAGE [IMAGE_ARCHIVE]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${APP_DIR:-/opt/tarakan}"
# Prefer the rsynced tree under APP_DIR; fall back to repo checkout for local runs.
if [[ -d "$APP_DIR/scripts/deploy" ]]; then
  :
elif [[ -d "$ROOT_DIR/scripts/deploy" ]]; then
  APP_DIR="$ROOT_DIR"
fi

IMAGE="${1:?usage: scripts/deploy/deploy.sh IMAGE [IMAGE_ARCHIVE]}"
IMAGE_ARCHIVE="${2:-$APP_DIR/.deploy/tarakan-image.tar.gz}"
COMPOSE_FILE="${COMPOSE_FILE:-$APP_DIR/deploy/docker/compose.yml}"

if ! printf '%s\n' "$IMAGE" | grep -Eq '^tarakan-app:[0-9a-f]{40}$'; then
  printf 'Refusing unexpected image tag: %s\n' "$IMAGE" >&2
  exit 2
fi

cd "$APP_DIR"
mkdir -p .deploy

# Protect against an Actions retry overlapping another deployment.
exec 9> .deploy/deploy.lock
flock 9

test -s "$IMAGE_ARCHIVE"
test -f "$COMPOSE_FILE"

# Back up the database and hosted repositories before migrations run.
"$APP_DIR/scripts/deploy/backup.sh"

gzip -dc "$IMAGE_ARCHIVE" | docker load
docker image inspect "$IMAGE" > /dev/null

printf 'APP_IMAGE=%s\n' "$IMAGE" > .deploy/image.env.tmp
mv .deploy/image.env.tmp .deploy/image.env

compose() {
  docker compose \
    --project-directory "$APP_DIR" \
    -f "$COMPOSE_FILE" \
    --env-file "$APP_DIR/.env" \
    --env-file "$APP_DIR/.deploy/image.env" \
    "$@"
}

compose config > /dev/null
compose up -d --no-build --remove-orphans

attempt=0
until curl --fail --silent --show-error \
  --header 'Host: localhost' \
  --output /dev/null \
  http://127.0.0.1:4000/
do
  attempt=$((attempt + 1))

  if [[ "$attempt" -ge 30 ]]; then
    compose ps >&2
    compose logs --no-color --tail=200 app >&2
    exit 1
  fi

  sleep 2
done

rm -f "$IMAGE_ARCHIVE"

# Keep active images and one week of rollback candidates.
docker image prune --all --force --filter until=168h > /dev/null

printf 'Deployed %s\n' "$IMAGE"
