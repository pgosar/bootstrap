#!/usr/bin/env bash
# Set up the Atuin sync server container.
# Run once on a fresh NAS. After creating the first account, set
# ATUIN_OPEN_REGISTRATION=false and recreate the container.
set -euo pipefail

ATUIN_DATA_DIR="${ATUIN_DATA_DIR:-/data/docker/appdata/atuin}"
ATUIN_PORT="${ATUIN_PORT:-8888}"
ATUIN_IMAGE="${ATUIN_IMAGE:-ghcr.io/atuinsh/atuin:latest}"

mkdir -p "$ATUIN_DATA_DIR"

if docker ps --format '{{.Names}}' | grep -qx atuin-server; then
  echo "atuin-server already running"
  exit 0
fi

docker run -d \
  --name atuin-server \
  --restart unless-stopped \
  -p "${ATUIN_PORT}:8888" \
  -v "${ATUIN_DATA_DIR}:/config" \
  -e "ATUIN_DB_URI=sqlite:///config/atuin.db" \
  -e ATUIN_HOST=0.0.0.0 \
  -e ATUIN_PORT=8888 \
  -e ATUIN_OPEN_REGISTRATION=true \
  "$ATUIN_IMAGE" start

echo "Atuin server started on port $ATUIN_PORT."
echo "Register the first account, then close registration:"
echo "  docker rm -f atuin-server"
echo "  ATUIN_OPEN_REGISTRATION=false $0"
