#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NAS_ROOT="$SCRIPT_DIR"
REPO_ROOT="$(cd -- "$NAS_ROOT/.." && pwd)"

for lib in \
  00-defaults.sh \
  10-utils.sh \
  20-config.sh \
  30-install-arch.sh \
  40-packages.sh \
  50-storage.sh \
  60-services.sh \
  70-checks.sh \
  90-main.sh; do
  # shellcheck source=/dev/null
  source "$NAS_ROOT/lib/$lib"
done

main "$@"
