#!/usr/bin/env bash
set -euo pipefail

NAS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if (( EUID != 0 )); then
  printf 'Run this installer as root.\n' >&2
  exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_and_install() {
  local mode="$1" source="$2" destination="$3"
  if [[ -e "$destination" ]]; then
    cp -a -- "$destination" "$destination.backup.$timestamp"
  fi
  install -o root -g root -m "$mode" -- "$source" "$destination"
}

backup_and_install 0755 "$NAS_ROOT/config/snapraid-sync.sh" /usr/local/bin/snapraid-sync.sh
backup_and_install 0755 "$NAS_ROOT/config/snapraid-scrub.sh" /usr/local/bin/snapraid-scrub.sh
backup_and_install 0644 "$NAS_ROOT/config/systemd/snapraid-sync.timer" /etc/systemd/system/snapraid-sync.timer
backup_and_install 0644 "$NAS_ROOT/config/systemd/snapraid-scrub.timer" /etc/systemd/system/snapraid-scrub.timer

systemctl daemon-reload
systemctl restart snapraid-sync.timer snapraid-scrub.timer
systemctl is-active --quiet snapraid-sync.timer
systemctl is-active --quiet snapraid-scrub.timer

printf 'SnapRAID operations are serialized and the storage timers are active.\n'
systemctl list-timers snapraid-sync.timer snapraid-scrub.timer --no-pager
