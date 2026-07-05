#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  printf 'Usage: %s /path/to/archlinux.iso\n' "$0" >&2
  exit 1
fi

ISO_PATH="$1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PC_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd -- "$PC_ROOT/.." && pwd)"
WORKDIR="$PC_ROOT/qemu/work"
LOGDIR="$WORKDIR/logs"
HTTPDIR="$WORKDIR/http"
AUTOBoot_DIR="$WORKDIR/autoboot-iso"
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
HTTP_PORT="${HTTP_PORT:-18080}"
SSH_PORT="${SSH_PORT:-2233}"
ARCHISO_UUID="${ARCHISO_UUID:-2026-02-01-08-05-47-00}"
ARCHISO_LABEL="${ARCHISO_LABEL:-ARCH_202602}"

[[ -f "$ISO_PATH" ]] || { printf 'ISO not found: %s\n' "$ISO_PATH" >&2; exit 1; }
[[ -f "$OVMF_CODE" ]] || { printf 'OVMF code file not found: %s\n' "$OVMF_CODE" >&2; exit 1; }
[[ -f "$OVMF_VARS_TEMPLATE" ]] || { printf 'OVMF vars template not found: %s\n' "$OVMF_VARS_TEMPLATE" >&2; exit 1; }
command -v qemu-img >/dev/null 2>&1 || { printf 'qemu-img not found\n' >&2; exit 1; }
command -v grub-mkstandalone >/dev/null 2>&1 || { printf 'grub-mkstandalone not found\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'python3 not found\n' >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { printf 'ssh not found\n' >&2; exit 1; }
command -v ssh-keygen >/dev/null 2>&1 || { printf 'ssh-keygen not found\n' >&2; exit 1; }

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR" "$LOGDIR" "$HTTPDIR" "$AUTOBoot_DIR/EFI/BOOT"
cp "$OVMF_VARS_TEMPLATE" "$WORKDIR/OVMF_VARS.fd"

qemu-img create -f qcow2 "$WORKDIR/pc-os.qcow2" 64G >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$WORKDIR/id_ed25519"
cp "$WORKDIR/id_ed25519.pub" "$HTTPDIR/id_ed25519.pub"
cp "$PC_ROOT/qemu/guest/stage1.sh" "$HTTPDIR/pc-stage1.sh"

if [[ -c /dev/kvm ]]; then
  KVM_ARGS=(-enable-kvm)
else
  KVM_ARGS=()
fi

cat >"$WORKDIR/grub-auto.cfg" <<EOF
set timeout=0
set default=0

menuentry 'Automated Arch PC bootstrap' {
  search --no-floppy --label --set=archiso $ARCHISO_LABEL
  linux (\$archiso)/arch/boot/x86_64/vmlinuz-linux archisobasedir=arch archisosearchuuid=$ARCHISO_UUID ip=dhcp console=ttyS0,115200n8
  initrd (\$archiso)/arch/boot/x86_64/initramfs-linux.img
}
EOF

grub-mkstandalone \
  -O x86_64-efi \
  --modules="part_gpt part_msdos fat iso9660 udf search search_label linux normal configfile echo" \
  -o "$AUTOBoot_DIR/EFI/BOOT/BOOTX64.EFI" \
  "boot/grub/grub.cfg=$WORKDIR/grub-auto.cfg" >/dev/null

python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$HTTPDIR" >"$LOGDIR/http.log" 2>&1 &
HTTP_PID=$!
cleanup() {
  kill "$HTTP_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

base_qemu_args=(
  "${KVM_ARGS[@]}" \
  -m 4096 \
  -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$WORKDIR/OVMF_VARS.fd" \
  -virtfs local,path="$REPO_ROOT",mount_tag=repo,security_model=none,readonly=on \
  -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 \
  -device virtio-net-pci,netdev=net0 \
  -display none
)

printf 'Running automated live ISO install...\n'
"$QEMU_BIN" \
  "${base_qemu_args[@]}" \
  -device qemu-xhci \
  -drive if=none,id=autofat,format=raw,readonly=on,file=fat:ro:"$AUTOBoot_DIR" \
  -device usb-storage,drive=autofat,bootindex=1 \
  -drive if=none,id=archiso,file="$ISO_PATH",format=raw,readonly=on \
  -device usb-storage,drive=archiso,bootindex=3 \
  -drive if=none,id=osdisk,file="$WORKDIR/pc-os.qcow2",format=qcow2 \
  -device virtio-blk-pci,drive=osdisk,bootindex=2 \
  -serial unix:"$WORKDIR/install-serial.sock",server=on,wait=off \
  -pidfile "$WORKDIR/qemu-install.pid" \
  -no-reboot \
  -daemonize

python3 "$PC_ROOT/qemu/lib/drive-serial.py" \
  "$WORKDIR/install-serial.sock" \
  "$LOGDIR/qemu-install-serial.log" \
  "curl -fsSL http://10.0.2.2:$HTTP_PORT/pc-stage1.sh | bash"

printf 'Booting installed system for health check...\n'
"$QEMU_BIN" \
  "${base_qemu_args[@]}" \
  -drive if=none,id=osdisk,file="$WORKDIR/pc-os.qcow2",format=qcow2 \
  -device virtio-blk-pci,drive=osdisk,bootindex=1 \
  -serial file:"$LOGDIR/qemu-boot-serial.log" \
  -pidfile "$WORKDIR/qemu.pid" \
  -daemonize

SSH_OPTS=(
  -i "$WORKDIR/id_ed25519"
  -p "$SSH_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile="$WORKDIR/known_hosts"
  -o ConnectTimeout=5
)

ssh_ready=false
for _ in $(seq 1 240); do
  if ssh "${SSH_OPTS[@]}" root@127.0.0.1 true >/dev/null 2>&1; then
    ssh_ready=true
    break
  fi
  sleep 2
done
[[ "$ssh_ready" == true ]] || {
  printf 'Installed VM did not become reachable over SSH on port %s\n' "$SSH_PORT" >&2
  exit 1
}

ssh "${SSH_OPTS[@]}" root@127.0.0.1 \
  "mkdir -p /repo && mount -t 9p -o trans=virtio,version=9p2000.L repo /repo && /repo/pc/qemu/guest/stage2.sh" \
  | tee "$LOGDIR/qemu-health.log"
ssh "${SSH_OPTS[@]}" root@127.0.0.1 "poweroff" >/dev/null 2>&1 || true

if [[ -f "$WORKDIR/qemu.pid" ]]; then
  QEMU_PID="$(cat "$WORKDIR/qemu.pid")"
  for _ in $(seq 1 60); do
    kill -0 "$QEMU_PID" >/dev/null 2>&1 || break
    sleep 1
  done
fi

printf 'QEMU PC validation complete. Logs: %s\n' "$LOGDIR"
