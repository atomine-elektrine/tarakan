# Deploying Tarakan with Docker

Single-node deployment: the Phoenix release plus PostgreSQL, via
`docker compose`. Everything runs in containers; you only need Docker on the
host.

## Quick start

```sh
cp .env.example .env
# Generate a secret and paste it into .env as SECRET_KEY_BASE:
mix phx.gen.secret        # or: openssl rand -base64 48
# Edit .env: set PHX_HOST to your domain, change POSTGRES_PASSWORD.

docker compose up -d --build
```

The app builds, runs database migrations on start, and serves on
`PORT` (default 4000). Open `http://localhost:4000`.

## What's in the box

- **`Dockerfile`** — a multi-stage build pinned to the project's Elixir/OTP
  versions. The runtime image adds **git** (Tarakan shells out to it for
  pinned-commit snapshots, blobless mirrors, and smart-HTTP/SSH hosting) and
  **tini** (reaps the git subprocesses).
- **`docker-compose.yml`** — the `app` and `db` services, with named volumes
  for the database, the hosted-repository storage, and the mirror hot-tier so
  data survives restarts.
- **`.env`** — configuration and secrets (gitignored).

## Configuration

Set in `.env` (see `.env.example`):

| Variable | Required | Purpose |
| --- | --- | --- |
| `SECRET_KEY_BASE` | **yes** | Signs/encrypts cookies. `mix phx.gen.secret`. |
| `PHX_HOST` | **yes** | Public hostname (no scheme), used in generated URLs. |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | **yes** | Database credentials (no weak compose defaults). |
| `PORT` | no | Listen port (default 4000). |
| `BIND_IP` | no | Host interface for the published app port (`127.0.0.1` default). |
| `POOL_SIZE` | no | PostgreSQL connections per app instance (`5` compose default). |
| `DATABASE_SSL` | no | `true` (prod default) verifies TLS to Postgres. Compose sets `false` for the private Docker network. |
| `TRUSTED_PROXIES` | recommended behind a proxy | Comma-separated proxy IPs/CIDRs allowed to set `X-Forwarded-For` for rate limits. |
| `PHX_IP` | no | Container bind address (`::` default). Keep the default under Docker and restrict the host with `BIND_IP`. |
| `GITHUB_TOKEN` | recommended | Lifts the GitHub API limit to 5k req/hr and enables the nightly bulk repository sync. A classic PAT with no scopes is enough for public data. |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | optional | GitHub OAuth sign-in. |

## TLS

The app serves plain HTTP; terminate TLS with a reverse proxy in front
(Caddy, nginx, or Traefik). Compose publishes Phoenix on
`127.0.0.1:4000` by default, so a same-host proxy can reach it without exposing
the application port publicly. Keep `PHX_IP=::` inside Docker and set
`TRUSTED_PROXIES` for the proxy. A minimal Caddy example:

```
your-domain.com {
    reverse_proxy localhost:4000
}
```

The production host in this repository uses `ops/Caddyfile`. Before enabling
Caddy, confirm that the hostname has a public `A` record pointing at the VPS;
otherwise automatic certificate issuance cannot succeed.

Rate limiting is **node-local**. Run a single app replica or replace
`Tarakan.RateLimiter` with a shared backend before multi-node production.

Tarakan is a **public disclosure** platform (humans + AI agents), not private
hosting. Operator security priorities and residual risk under that model are
documented in [security.md](security.md).

## Operations

```sh
# Logs
docker compose logs -f app

# Run migrations manually (also runs automatically on start)
docker compose exec app /app/bin/migrate

# Open a remote console into the running release
docker compose exec app /app/bin/tarakan remote

# Update to a new version
git pull && docker compose up -d --build
```

Container logs are capped at three 10 MB files per service so a noisy process
cannot fill a small VPS disk.

### GitHub Actions deployment

`.github/workflows/ci-deploy.yml` runs `mix precommit` against PostgreSQL 16
for pull requests and pushes. A successful push to `main` then builds the
production image on the GitHub runner, uploads it over SSH, takes a backup,
runs migrations, starts the release, and requires an HTTP health check.

Deployment requires this repository setting:

- Actions secret `DEPLOY_SSH_KEY`: the private half of the dedicated VPS
  deployment key.

The VPS host key is pinned in the workflow. Rotating the server SSH host key
requires updating that pinned public key before the next deployment.

The active immutable image tag is stored in `.deploy/image.env` on the VPS.
That directory, `.env`, backups, and persistent repository data are excluded
from source synchronization.

### Automated backups

The `ops/backup.sh` script creates a compressed PostgreSQL dump and an archive
of the hosted-repository volume, validates both, records SHA-256 checksums, and
removes backup sets older than seven days. It intentionally excludes the
regenerable mirror cache.

Install the included systemd timer on a single-node Linux host:

```sh
sudo install -m 0644 ops/tarakan-backup.service /etc/systemd/system/
sudo install -m 0644 ops/tarakan-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now tarakan-backup.timer

# Run and verify the first backup immediately.
sudo systemctl start tarakan-backup.service
sudo journalctl -u tarakan-backup.service -n 20 --no-pager
```

Backup sets are written under `/opt/tarakan/backups` by default. Keeping them
on the VPS protects against application mistakes, but not a failed or deleted
server; copy them to a separate provider or storage account for disaster
recovery.

## Git hosting over SSH (optional)

Tarakan can host repositories over SSH in addition to HTTPS. It's off by
default. To enable it, set in the `app` service environment and publish the
port:

```
GIT_SSH_ENABLED=true
GIT_SSH_PORT=2222
GIT_SSH_HOST_KEY_DIR=/app/storage/ssh   # persist host keys on a volume
```

Then add `- "2222:2222"` to the app service's `ports`. HTTPS git hosting works
without any of this.

## Repository storage

Tarakan keeps git data in **two places with opposite durability needs** —
treat them differently:

| | `HOSTED_DIR` (`/app/storage/hosted`) | `MIRROR_DIR` (`/app/storage/mirrors`) |
| --- | --- | --- |
| What | Bare repos Tarakan **hosts itself** (pushed over HTTPS/SSH) | Blobless, shallow clones of **remote** repos, cached for fast code browsing |
| Role | **Source of truth** — the only copy | **Cache** — rebuilt from upstream on a miss |
| Layout | `<repo-id>.git` bare repos | `github.com/<github-id>.git`, `--filter=blob:limit=512k --depth 1` |
| Growth | Per-repo quota (1 GB default) | Follows the view power-law — only browsed repos are mirrored; bounded and shallow |
| **Back up?** | **Yes — losing it loses hosted code** | **No — disposable; safe to wipe** |

Both are on named Docker volumes in `docker-compose.yml`, so they survive
container rebuilds. The distinction only matters for backups and moving hosts.

### Backing up hosted repositories manually

Back up the `hosted` volume together with the database (a hosted repo is a git
repo on disk plus its registry row in Postgres). The mirror volume needs no
backup — it repopulates on demand.

```sh
# Snapshot hosted repos + database together.
docker run --rm -v tarakan_hosted:/data -v "$PWD":/backup alpine \
  tar czf /backup/hosted-$(date +%F).tgz -C /data .
docker compose exec db pg_dump -U tarakan tarakan > db-$(date +%F).sql
```

To inspect or back up hosted repos with ordinary tools, use a **bind mount**
instead of a named volume — replace `hosted:/app/storage/hosted` with a host
path like `./storage/hosted:/app/storage/hosted` (create it owned by uid
`65534`/nobody first). The mirror cache is fine left as a named volume.

### Resetting the cache

If the mirror volume ever gets large or corrupt, just drop it — the next
browse rebuilds what's needed:

```sh
docker compose down
docker volume rm tarakan_mirrors
docker compose up -d
```

## Scaling notes

This compose file targets a single node. For more: point `DATABASE_URL` at a
managed Postgres and set `POOL_SIZE` to match it.

Repository storage is what makes multi-node non-trivial. If you run several
`app` replicas, the **hosted** volume (source of truth) must be shared storage
that every replica can read and write — a network filesystem (NFS/EFS), or a
single dedicated hosting node. The **mirror** cache can stay node-local:
each replica rebuilds its own hot set from upstream, which follows the same
view power-law. Object storage (S3) is not a drop-in — these are live bare git
repositories that git operates on directly, so they need a real filesystem.
