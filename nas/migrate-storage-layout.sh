#!/usr/bin/env bash
# Apply the appdata-bulk/downloads retirement and make backups an ordinary,
# SnapRAID-protected pool directory. Run as root on the installed NAS.
set -euo pipefail

BOOTSTRAP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPRAID_TEMPLATE="$BOOTSTRAP_ROOT/nas/config/snapraid.conf.example"
BTRBK_TEMPLATE="$BOOTSTRAP_ROOT/nas/config/btrbk.conf.example"
SMB_TEMPLATE="$BOOTSTRAP_ROOT/nas/config/smb.conf.example"

[[ "${EUID}" -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
BACKUP_OWNER="${SUDO_USER:-chilly}:nas"

is_empty() {
  [[ -d "$1" ]] && [[ -z "$(find "$1" -mindepth 1 -print -quit)" ]]
}

remove_empty_path() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  is_empty "$target" || { echo "Refusing to remove non-empty $target" >&2; exit 1; }
  if btrfs subvolume show "$target" >/dev/null 2>&1; then
    btrfs subvolume delete "$target"
  else
    rmdir "$target"
  fi
}

for disk in 1 2 3; do
  pool="/mnt/disk${disk}/pool"
  [[ -d "$pool" ]] || { echo "Missing pool: $pool" >&2; exit 1; }
  remove_empty_path "$pool/appdata-bulk"
  remove_empty_path "$pool/downloads/torrents"
  remove_empty_path "$pool/downloads"

  # Replace the old empty backups subvolume with an ordinary directory so the
  # parent pool snapshot and SnapRAID can protect it.
  remove_empty_path "$pool/backups"
  install -d -o "${BACKUP_OWNER%%:*}" -g "${BACKUP_OWNER##*:}" -m 2770 "$pool/backups"
done

install -m 0644 "$SNAPRAID_TEMPLATE" /etc/snapraid.conf
install -d -m 0755 /etc/btrbk
install -m 0644 "$BTRBK_TEMPLATE" /etc/btrbk/btrbk.conf
install -d -m 0755 /etc/samba
install -m 0644 "$SMB_TEMPLATE" /etc/samba/smb.conf

btrbk -c /etc/btrbk/btrbk.conf dryrun
systemctl reload smb
snapraid diff
echo "Storage layout migration complete. Run 'snapraid sync' after reviewing the diff."
