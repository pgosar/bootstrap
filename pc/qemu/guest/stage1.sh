#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/tmp/pc-qemu-stage1.log"
exec > >(tee -a "$LOG_FILE") 2>&1

stage_status=0
on_exit() {
  stage_status=$?
  if [[ "$stage_status" -eq 0 ]]; then
    printf '[pc-qemu-stage1] complete; powering off VM\n'
  else
    printf '[pc-qemu-stage1] FAILED with exit code %s; powering off VM\n' "$stage_status"
  fi
  sync || true
  systemctl poweroff || poweroff || true
}
trap on_exit EXIT

REPO_ROOT="/repo"
PC_ROOT="$REPO_ROOT/pc"
ENV_FILE="$PC_ROOT/qemu/qemu-pc.env"
PUBKEY_URL="${PC_QEMU_SSH_PUBKEY_URL:-http://10.0.2.2:18080/id_ed25519.pub}"

printf '[pc-qemu-stage1] starting live ISO install stage\n'
timedatectl set-ntp true || true

mkdir -p "$REPO_ROOT"
if [[ ! -x "$PC_ROOT/bin/bootstrap-pc.sh" ]]; then
  modprobe 9pnet_virtio 2>/dev/null || true
  mount -t 9p -o trans=virtio,version=9p2000.L repo "$REPO_ROOT"
fi

cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$ENV_FILE"

bash -n "$PC_ROOT/bin/bootstrap-pc.sh"
"$PC_ROOT/bin/bootstrap-pc.sh" --help >/dev/null
"$PC_ROOT/bin/bootstrap-pc.sh" --list-disks

printf '%s\n' 'yes, do as I say' | "$PC_ROOT/bin/bootstrap-pc.sh" \
  --env-file "$ENV_FILE" \
  --target-mode live \
  --target-root /mnt \
  --apply \
  --all

install -d -m 0700 /mnt/root/.ssh
if curl -fsSL "$PUBKEY_URL" -o /mnt/root/.ssh/authorized_keys; then
  chmod 0600 /mnt/root/.ssh/authorized_keys
fi

"$PC_ROOT/bin/bootstrap-pc.sh" \
  --env-file "$ENV_FILE" \
  --check-live-target
