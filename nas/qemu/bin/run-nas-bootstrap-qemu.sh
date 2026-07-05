#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
NAS_DIR="$ROOT_DIR/nas"
WORKDIR="${QEMU_WORKDIR:-$NAS_DIR/qemu/work}"
HTTP_DIR="$WORKDIR/http"
LOG_DIR="$WORKDIR/logs"
SHARED_DIR="$WORKDIR/shared"
HTTP_PORT="${QEMU_HTTP_PORT:-18080}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-2222}"
OVMF_VARS="$WORKDIR/OVMF_VARS.fd"
FORCE=false
ISO_PATH=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

check_local_port() {
  local port="$1"
  python3 - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.socket() as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
PY
}

first_existing() {
  local path
  for path in "$@"; do
    if [[ -f "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

usage() {
  cat <<'EOF'
Usage:
  nas/qemu/bin/run-nas-bootstrap-qemu.sh [--force] /path/to/archlinux.iso
  ARCH_ISO=/path/to/archlinux.iso nas/qemu/bin/run-nas-bootstrap-qemu.sh --force

Options:
  --force   Delete and recreate QEMU_WORKDIR if it already exists.

Environment:
  ARCH_ISO=/path/to/archlinux.iso
  QEMU_WORKDIR=nas/qemu/work
  QEMU_HTTP_PORT=18080
  QEMU_SSH_PORT=2222
  OVMF_CODE=/path/to/OVMF_CODE.4m.fd
  OVMF_VARS_TEMPLATE=/path/to/OVMF_VARS.4m.fd
EOF
}

while (($#)); do
  case "$1" in
    --force)
      FORCE=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$ISO_PATH" ]] || die "multiple ISO paths provided"
      ISO_PATH="$1"
      shift
      ;;
  esac
done

ISO_PATH="${ISO_PATH:-${ARCH_ISO:-}}"

if [[ -z "$ISO_PATH" ]]; then
  usage
  exit 64
fi

OVMF_CODE="${OVMF_CODE:-$(first_existing \
  /usr/share/edk2/x64/OVMF_CODE.4m.fd \
  /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/ovmf/x64/OVMF_CODE.fd \
  || true)}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-$(first_existing \
  /usr/share/edk2/x64/OVMF_VARS.4m.fd \
  /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd \
  /usr/share/OVMF/OVMF_VARS.fd \
  /usr/share/ovmf/x64/OVMF_VARS.fd \
  || true)}"

[[ -f "$ISO_PATH" ]] || die "Arch ISO not found: $ISO_PATH"
[[ -f "$OVMF_CODE" ]] || die "OVMF code image not found: $OVMF_CODE"
[[ -f "$OVMF_VARS_TEMPLATE" ]] || die "OVMF vars template not found: $OVMF_VARS_TEMPLATE"

require_cmd qemu-system-x86_64
require_cmd qemu-img
require_cmd python3
require_cmd tar

if [[ -e "$WORKDIR" ]] && [[ "$FORCE" != true ]]; then
  die "$WORKDIR already exists; rerun with --force or set QEMU_WORKDIR to a new path"
fi

check_local_port "$HTTP_PORT" || die "localhost port is already in use: $HTTP_PORT"
check_local_port "$QEMU_SSH_PORT" || die "localhost port is already in use: $QEMU_SSH_PORT"

if [[ "$FORCE" == true ]]; then
  rm -rf "$WORKDIR"
fi
mkdir -p "$HTTP_DIR" "$LOG_DIR" "$SHARED_DIR"
cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"

STAGED_REPO="$HTTP_DIR/bootstrap-src"
rm -rf "$STAGED_REPO"
mkdir -p "$STAGED_REPO/nas/qemu"
cp -a "$NAS_DIR/bootstrap-nas.sh" "$STAGED_REPO/nas/bootstrap-nas.sh"
cp -a "$NAS_DIR/lib" "$STAGED_REPO/nas/lib"
cp -a "$NAS_DIR/config" "$STAGED_REPO/nas/config"
cp -a "$NAS_DIR/.env.example" "$STAGED_REPO/nas/.env.example"
cp -a "$NAS_DIR/qemu/guest/stage1.sh" "$STAGED_REPO/nas/qemu/guest/stage1.sh"
cp -a "$NAS_DIR/qemu/guest/stage2.sh" "$STAGED_REPO/nas/qemu/guest/stage2.sh"
cp -a "$NAS_DIR/qemu/checks/verify-live-target.sh" "$STAGED_REPO/nas/qemu/checks/verify-live-target.sh"
cp -a "$NAS_DIR/qemu/checks/verify-installed-health.sh" "$STAGED_REPO/nas/qemu/checks/verify-installed-health.sh"
cp -a "$NAS_DIR/qemu/qemu-nas.env" "$STAGED_REPO/nas/qemu/qemu-nas.env"
cp -a "$NAS_DIR/qemu/README.md" "$STAGED_REPO/nas/qemu/README.md"
[[ -f "$ROOT_DIR/README.md" ]] && cp -a "$ROOT_DIR/README.md" "$STAGED_REPO/README.md"
[[ -f "$ROOT_DIR/.gitignore" ]] && cp -a "$ROOT_DIR/.gitignore" "$STAGED_REPO/.gitignore"
find "$STAGED_REPO" \
  \( -name '*.qcow2' -o -name '*.iso' -o -name 'OVMF_VARS.fd' -o -name '*.out' \) \
  -delete
tar -cf "$HTTP_DIR/bootstrap.tar" -C "$STAGED_REPO" .
cp "$NAS_DIR/qemu/guest/stage1.sh" "$HTTP_DIR/stage1.sh"

qemu-img create -f qcow2 "$WORKDIR/nas-os.qcow2" 32G
qemu-img create -f qcow2 "$WORKDIR/nas-data1.qcow2" 4G
qemu-img create -f qcow2 "$WORKDIR/nas-data2.qcow2" 4G
qemu-img create -f qcow2 "$WORKDIR/nas-data3.qcow2" 4G
qemu-img create -f qcow2 "$WORKDIR/nas-parity.qcow2" 4G

python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$HTTP_DIR" \
  >"$LOG_DIR/http.log" 2>&1 &
HTTP_PID=$!
cleanup() {
  kill "$HTTP_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

qemu_accel=()
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  qemu_accel=(-enable-kvm)
else
  warn "/dev/kvm is unavailable; running QEMU without KVM acceleration"
fi

qemu_base=(
  qemu-system-x86_64
  "${qemu_accel[@]}"
  -m 4096
  -smp 4
  -no-reboot
)

qemu_uefi=(
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
  -drive "if=pflash,format=raw,file=$OVMF_VARS"
)

qemu_devices=(
  -drive "if=none,id=os,format=qcow2,file=$WORKDIR/nas-os.qcow2"
  -device "virtio-blk-pci,drive=os,serial=osdisk"
  -drive "if=none,id=data1,format=qcow2,file=$WORKDIR/nas-data1.qcow2"
  -device "virtio-blk-pci,drive=data1,serial=data1"
  -drive "if=none,id=data2,format=qcow2,file=$WORKDIR/nas-data2.qcow2"
  -device "virtio-blk-pci,drive=data2,serial=data2"
  -drive "if=none,id=data3,format=qcow2,file=$WORKDIR/nas-data3.qcow2"
  -device "virtio-blk-pci,drive=data3,serial=data3"
  -drive "if=none,id=parity,format=qcow2,file=$WORKDIR/nas-parity.qcow2"
  -device "virtio-blk-pci,drive=parity,serial=parity"
  -netdev "user,id=n0,hostfwd=tcp::$QEMU_SSH_PORT-:22"
  -device virtio-net-pci,netdev=n0
)

INSTALL_LOG="$LOG_DIR/qemu-install.log"
BOOT_LOG="$LOG_DIR/qemu-boot.log"
HEALTH_LOG="$LOG_DIR/qemu-health.log"
FINAL_LOG="$LOG_DIR/final-verification.log"

printf '== stage1: boot Arch ISO and install OS ==\n'
(
	  sleep 5
	  printf 'e console=ttyS0,115200n8\n'
	  sleep 45
	  printf 'root\n'
  sleep 5
  printf 'curl -fsSL http://10.0.2.2:%s/stage1.sh | QEMU_HTTP_PORT=%s bash\n' "$HTTP_PORT" "$HTTP_PORT"
) | timeout 90m "${qemu_base[@]}" "${qemu_uefi[@]}" "${qemu_devices[@]}" \
  -display none \
  -serial mon:stdio \
  -virtfs "local,path=$SHARED_DIR,mount_tag=hostshare,security_model=none" \
  -drive "file=$ISO_PATH,media=cdrom,readonly=on,if=ide" \
  | tee "$INSTALL_LOG"

grep -q "install post-reboot verifier" "$INSTALL_LOG" \
  || die "stage1 did not appear to complete the one-phase bootstrap install"
[[ -s "$SHARED_DIR/grub.cfg" ]] || die "stage1 did not export installed GRUB config"
grep -q "intel-ucode.img" "$SHARED_DIR/grub.cfg" || die "GRUB config is missing intel-ucode.img"
grep -q "rootflags=subvol=@" "$SHARED_DIR/grub.cfg" || die "GRUB config is missing rootflags=subvol=@"
[[ -s "$SHARED_DIR/final-verification.log" ]] || die "stage1 did not export final verification log"

printf '== stage2: boot installed system and verify final NAS state ==\n'
: >"$BOOT_LOG"
timeout 120m "${qemu_base[@]}" "${qemu_uefi[@]}" "${qemu_devices[@]}" \
  -display none \
  -serial "file:$BOOT_LOG" \
  -monitor none \
  -virtfs "local,path=$SHARED_DIR,mount_tag=hostshare,security_model=none" \
  >"$LOG_DIR/stage2-qemu.log" 2>&1

cp "$BOOT_LOG" "$HEALTH_LOG"
cp "$SHARED_DIR/final-verification.log" "$FINAL_LOG"

grep -q "nas-qemu-stage2.done" "$BOOT_LOG" \
  || die "stage2 did not reach the completion marker"
cp "$SHARED_DIR/final-verification.log" "$FINAL_LOG"
if [[ -s "$SHARED_DIR/stage2.status" ]]; then
  grep -qx "ok" "$SHARED_DIR/stage2.status" || die "stage2 exported a failing status"
elif grep -q "RESULT: HEALTHY" "$FINAL_LOG" && ! grep -q '^\[FAIL\]' "$FINAL_LOG"; then
  warn "stage2.status was empty, but final verification log is healthy; accepting QEMU stage2 result"
else
  die "stage2 did not export a usable status file"
fi
if grep -F "Unknown parameter 'category.create'" "$INSTALL_LOG" "$BOOT_LOG" "$FINAL_LOG" >/dev/null 2>&1; then
  die "previous mergerfs category.create error appeared in QEMU logs"
fi
if grep -F "Unknown parameter 'fsname'" "$INSTALL_LOG" "$BOOT_LOG" "$FINAL_LOG" >/dev/null 2>&1; then
  die "previous mergerfs fsname error appeared in QEMU logs"
fi
if grep -E "fuse[.]mergerfs" "$SHARED_DIR/target-fstab" >/dev/null 2>&1; then
  die "target fstab contains deprecated mergerfs fstype"
fi
if grep -E "fsname=merger[f]s" "$SHARED_DIR/target-fstab" >/dev/null 2>&1; then
  die "target fstab contains deprecated mergerfs fsname option"
fi

printf 'QEMU NAS bootstrap test completed. Logs: %s\n' "$LOG_DIR"
