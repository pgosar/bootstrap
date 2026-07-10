#!/usr/bin/env bash
set -euo pipefail

NAS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="/etc/nas-notify.env"

if (( EUID != 0 )); then
  printf 'Run this installer as root.\n' >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]] || ! grep -Eq '^NAS_NOTIFY_DISCORD_WEBHOOK_URL=.+$' "$ENV_FILE"; then
  printf 'Create %s from config/nas-notify.env.example and add the Discord webhook first.\n' "$ENV_FILE" >&2
  exit 2
fi

env_uid="$(stat -c %u "$ENV_FILE")"
env_mode="$(stat -c %a "$ENV_FILE")"
if [[ "$env_uid" != 0 ]] || (( (8#$env_mode & 8#077) != 0 )); then
  printf '%s must be owned by root and inaccessible to group/other users (mode 0600).\n' "$ENV_FILE" >&2
  exit 2
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_and_install() {
  local mode="$1" source="$2" destination="$3"
  if [[ -e "$destination" ]]; then
    cp -a -- "$destination" "$destination.backup.$timestamp"
  fi
  install -o root -g root -m "$mode" -- "$source" "$destination"
}

backup_and_install 0755 "$NAS_ROOT/config/nas-notify" /usr/local/sbin/nas-notify
backup_and_install 0755 "$NAS_ROOT/config/snapraid-scrub.sh" /usr/local/bin/snapraid-scrub.sh
backup_and_install 0644 "$NAS_ROOT/config/smartd.conf" /etc/smartd.conf
backup_and_install 0644 "$NAS_ROOT/config/systemd/snapraid-scrub.service" /etc/systemd/system/snapraid-scrub.service
install -o root -g root -m 0600 -- "$NAS_ROOT/config/nas-notify.env.example" /etc/nas-notify.env.example

systemctl daemon-reload
smartd -q showtests -c /etc/smartd.conf >/dev/null
systemctl restart smartd.service
systemctl is-active --quiet smartd.service
/usr/local/sbin/nas-notify setup 'SMART and SnapRAID scrub failure alerts are active.'

printf 'Monitoring alerts installed; smartd is active and the test notification was sent.\n'
