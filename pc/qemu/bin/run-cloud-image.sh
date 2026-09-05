#!/usr/bin/env bash
# Disposable boot from a prepared base. All guest writes disappear on exit.
set -euo pipefail
if [[ $# -lt 1 || "${1:-}" == --help ]]; then
  printf 'Usage: %s /absolute/checksum-base.qcow2 [cloud-init-seed.iso]\nBoots a disposable KVM guest on the serial console. Ctrl-a x exits.\nOptional seed supplies cloud-init users/keys. No host ports are published.\n' "$0"
  exit 0
fi
base="$(realpath "$1")"
[[ -f "$base" ]]
work="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-cloud-boot.XXXXXX")"
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$work/vars.fd"
extra=()
if [[ -n "${2:-}" ]]; then
  seed="$(realpath "$2")"
  [[ -f "$seed" ]]
  extra=(-drive "file=$seed,format=raw,media=cdrom,readonly=on")
fi
printf 'Temporary firmware state: %s\n' "$work" >&2
exec qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 \
  -drive file=/usr/share/edk2/x64/OVMF_CODE.4m.fd,if=pflash,format=raw,readonly=on \
  -drive "file=$work/vars.fd,if=pflash,format=raw" \
  -drive "file=$base,format=qcow2,if=virtio,snapshot=on" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -nographic -no-reboot "${extra[@]}"
