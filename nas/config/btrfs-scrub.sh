#!/usr/bin/env bash
set -uo pipefail

disk="${1:-}"
case "$disk" in
  disk1|disk2|disk3) ;;
  *)
    printf 'Usage: %s disk1|disk2|disk3\n' "$0" >&2
    exit 2
    ;;
esac

path="/mnt/$disk"
lock_file=/run/lock/snapraid-operation.lock
exec 9>"$lock_file"
if ! flock -n 9; then
  printf 'Another parity operation is active; skipping Btrfs scrub for %s.\n' "$disk"
  exit 0
fi

if ! mountpoint -q "$path"; then
  printf '%s is not mounted; refusing to scrub.\n' "$path" >&2
  exit 1
fi

if ! /usr/bin/btrfs scrub start -B -r "$path"; then
  /usr/local/sbin/nas-notify btrfs-scrub \
    "Btrfs scrub failed for $path. The scheduled scrub is non-repairing; inspect the status and repair manually if needed." || true
  exit 1
fi
