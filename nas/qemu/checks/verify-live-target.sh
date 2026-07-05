#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
env_file="${1:-$repo_root/nas/qemu/qemu-nas.env}"

if [[ ! -d /run/archiso ]]; then
  echo "ERROR: verify-live-target.sh must run from the Arch ISO before reboot." >&2
  exit 1
fi

exec sudo "$repo_root/nas/bootstrap-nas.sh" \
  --env-file "$env_file" \
  --check-live-target
