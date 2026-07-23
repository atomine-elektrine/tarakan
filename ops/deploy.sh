#!/usr/bin/env bash
# Compatibility shim — prefer scripts/deploy/deploy.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/scripts/deploy/deploy.sh" "$@"
