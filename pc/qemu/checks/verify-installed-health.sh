#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PC_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

exec "$PC_ROOT/bin/bootstrap-pc.sh" --env-file "$PC_ROOT/qemu/qemu-pc.env" --check-health
