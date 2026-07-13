#!/bin/sh
set -eu

APP_DIR=${APP_DIR:-/opt/tarakan}
IMAGE=${1:?usage: deploy.sh IMAGE [IMAGE_ARCHIVE]}
IMAGE_ARCHIVE=${2:-$APP_DIR/.deploy/tarakan-image.tar.gz}

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

# Back up the database and hosted repositories before migrations run.
"$APP_DIR/ops/backup.sh"

gzip -dc "$IMAGE_ARCHIVE" | docker load
docker image inspect "$IMAGE" > /dev/null

printf 'APP_IMAGE=%s\n' "$IMAGE" > .deploy/image.env.tmp
mv .deploy/image.env.tmp .deploy/image.env

compose() {
  docker compose --env-file .env --env-file .deploy/image.env "$@"
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

  if [ "$attempt" -ge 30 ]; then
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
