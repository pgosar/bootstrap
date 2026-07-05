#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/tmp/pc-qemu-stage2.log"
exec > >(tee -a "$LOG_FILE") 2>&1

REPO_ROOT="/repo"
PC_ROOT="$REPO_ROOT/pc"

mkdir -p "$REPO_ROOT"
if [[ ! -x "$PC_ROOT/bin/bootstrap-pc.sh" ]]; then
  modprobe 9pnet_virtio 2>/dev/null || true
  mount -t 9p -o trans=virtio,version=9p2000.L repo "$REPO_ROOT"
fi

cd "$REPO_ROOT"
exec "$PC_ROOT/bin/bootstrap-pc.sh" --env-file "$PC_ROOT/qemu/qemu-pc.env" --check-health
