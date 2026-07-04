#!/usr/bin/env bash
set -euo pipefail

mount_host_share() {
  mkdir -p /host
  modprobe 9pnet_virtio || true
  if ! mountpoint -q /host; then
    mount -t 9p -o trans=virtio hostshare /host || true
  fi
}

mount_host_share
exec > >(tee -a /root/nas-qemu-stage2.log /host/final-verification.log) 2>&1

log() {
  printf '\n== %s ==\n' "$*"
}

run_check() {
  printf '\n$ %s\n' "$*"
  "$@"
}

run_shell_check() {
  printf '\n$ %s\n' "$*"
  bash -lc "$*"
}

export_artifacts() {
  local status="$1"
  mount_host_share
  cp /root/nas-qemu-stage2.log /host/stage2-guest.log || true
  if [[ "$status" == "0" ]]; then
    printf 'ok\n' >/host/stage2.status.tmp
  else
    printf 'fail\n' >/host/stage2.status.tmp
  fi
  mv -f /host/stage2.status.tmp /host/stage2.status
  sync -f /host/stage2.status 2>/dev/null || sync
}

on_exit() {
  local status="$?"
  export_artifacts "$status"
}

trap on_exit EXIT

log "stage2: post-reboot installed NAS verification"
cd /root/bootstrap
qemu_env="/root/bootstrap/nas/qemu/qemu-nas.env"
cp /root/qemu-nas.env "$qemu_env"

log "identity"
run_check hostname
run_shell_check 'test "$(hostname)" = nas-qemu'

log "disk layout"
run_check lsblk -f
run_shell_check "lsblk -no LABEL /dev/vdb | grep -qx nas-disk1"
run_shell_check "lsblk -no LABEL /dev/vdc | grep -qx nas-disk2"
run_shell_check "lsblk -no LABEL /dev/vdd | grep -qx nas-disk3"
run_shell_check "lsblk -no FSTYPE,LABEL /dev/vde | grep -Eq '^ext4[[:space:]]+nas-parity$'"

log "OS btrfs subvolume mounts"
run_check findmnt -n -o SOURCE,FSTYPE,OPTIONS /
run_check findmnt -n -o SOURCE,FSTYPE,OPTIONS /home
run_check findmnt -n -o SOURCE,FSTYPE,OPTIONS /var/log
run_check findmnt -n -o SOURCE,FSTYPE,OPTIONS /var/cache/pacman/pkg
run_check findmnt -n -o SOURCE,FSTYPE,OPTIONS /.snapshots
run_shell_check "findmnt -n -o OPTIONS / | grep -Eq 'subvol=/?@([,]|$)'"
run_shell_check "findmnt -n -o OPTIONS /home | grep -Eq 'subvol=/?@home([,]|$)'"
run_shell_check "findmnt -n -o OPTIONS /var/log | grep -Eq 'subvol=/?@log([,]|$)'"
run_shell_check "findmnt -n -o OPTIONS /var/cache/pacman/pkg | grep -Eq 'subvol=/?@pkg([,]|$)'"
run_shell_check "findmnt -n -o OPTIONS /.snapshots | grep -Eq 'subvol=/?@snapshots([,]|$)'"

log "fstab mergerfs correctness after reboot"
run_check cat /etc/fstab
run_shell_check "! grep -E 'fuse[.]mergerfs' /etc/fstab"
run_shell_check "! grep -E 'fsname=merger[f]s' /etc/fstab"
run_shell_check "! awk '\$2 == \"/data\" && \$3 == \"mergerfs\" { found=1 } END { exit !found }' /etc/fstab"
run_shell_check "! awk '\$2 == \"/mnt/snapshots\" && \$3 == \"mergerfs\" { found=1 } END { exit !found }' /etc/fstab"
run_check cat /etc/systemd/system/data.mount
run_check cat /etc/systemd/system/mnt-snapshots.mount
run_shell_check "grep -F 'Where=/data' /etc/systemd/system/data.mount"
run_shell_check "grep -F 'Type=mergerfs' /etc/systemd/system/data.mount"
run_shell_check "grep -F '/mnt/disk1/pool:/mnt/disk2/pool:/mnt/disk3/pool' /etc/systemd/system/data.mount"
run_shell_check "grep -F 'Where=/mnt/snapshots' /etc/systemd/system/mnt-snapshots.mount"
run_shell_check "grep -F 'Type=mergerfs' /etc/systemd/system/mnt-snapshots.mount"
run_shell_check "grep -F 'Options=defaults,ro,cache.files=off' /etc/systemd/system/mnt-snapshots.mount"

log "mount-a idempotence"
run_check mount -a
run_check mount -a
run_check mount -a
run_shell_check 'test "$(findmnt -rn /data | wc -l)" -eq 1'
run_shell_check 'test "$(findmnt -rn /mnt/snapshots | wc -l)" -eq 1'

log "mergerfs runtime mounts after reboot"
run_check findmnt /data
run_check findmnt /mnt/snapshots
run_check findmnt -n -o FSTYPE,OPTIONS /data
run_check findmnt -n -o FSTYPE,OPTIONS /mnt/snapshots
run_shell_check "findmnt -n -o OPTIONS /data | tr ',' '\n' | (! grep -qx ro)"
run_shell_check "findmnt -n -o OPTIONS /mnt/snapshots | tr ',' '\n' | grep -qx ro"

log "write behavior after reboot"
run_shell_check "touch /data/.nas-bootstrap-qemu-write-test && test -f /data/.nas-bootstrap-qemu-write-test && rm -f /data/.nas-bootstrap-qemu-write-test"
if touch /mnt/snapshots/.nas-bootstrap-should-fail 2>/root/snapshot-write.err; then
  echo "ERROR: snapshot view is writable"
  exit 1
else
  echo "OK: snapshot view is read-only"
fi

log "pool directories"
run_check find /data -maxdepth 1 -mindepth 1 -type d
expected_dirs="$(mktemp)"
actual_dirs="$(mktemp)"
cat >"$expected_dirs" <<'EOF'
/data/appdata-bulk
/data/backups
/data/docker
/data/downloads
/data/media
/data/personal
/data/replicas
/data/secrets
/data/staging
EOF
find /data -maxdepth 1 -mindepth 1 -type d | sort >"$actual_dirs"
diff -u "$expected_dirs" "$actual_dirs"
rm -f "$expected_dirs" "$actual_dirs"

log "per-disk btrfs subvolumes"
for d in /mnt/disk1 /mnt/disk2 /mnt/disk3; do
  echo "== $d =="
  btrfs subvolume list "$d" | grep 'pool/'
  for subvol in media downloads personal replicas secrets staging appdata-bulk docker backups; do
    btrfs subvolume show "$d/pool/$subvol" >/dev/null
  done
done

log "parity disk isolation"
run_shell_check "grep -E '^[^#].*(/data|/mnt/snapshots).*mergerfs' /etc/fstab | grep -F '/mnt/parity' && exit 1 || true"
echo "OK: parity not included in mergerfs"
run_check findmnt /mnt/parity

log "Docker dependency"
run_check cat /etc/systemd/system/docker.service.d/wait-for-data.conf
run_shell_check "systemctl cat docker | grep RequiresMountsFor=/data"

log "SnapRAID config"
run_check pacman -Q yay mergerfs snapraid
run_check test -f /etc/snapraid.conf
run_check test -d /var/lib/snapraid
run_check command -v snapraid
run_check grep -E "^[[:space:]]*data[[:space:]]" /etc/snapraid.conf
run_shell_check "! grep -E '^[[:space:]]*data[[:space:]].*/mnt/parity' /etc/snapraid.conf"
run_shell_check "! grep -E '^[[:space:]]*data[[:space:]].*/mnt/snapshots' /etc/snapraid.conf"
snapraid_status_output="$(snapraid status 2>&1)" && snapraid_status=0 || snapraid_status=$?
printf '%s\n' "$snapraid_status_output"
if [[ "$snapraid_status" -ne 0 && ( "$snapraid_status_output" == *"Error accessing 'content' dir"* || "$snapraid_status_output" == *"/var/lib/snapraid"* ) ]]; then
  echo "ERROR: snapraid status failed because the content directory is missing or inaccessible"
  exit 1
fi

log "btrbk config"
run_check test -f /etc/btrbk/btrbk.conf
run_check grep -F "snapshot_dir snapshots" /etc/btrbk/btrbk.conf
run_shell_check "! grep -F '/data' /etc/btrbk/btrbk.conf"

log "GRUB"
run_check test -s /boot/grub/grub.cfg
run_check grep -F intel-ucode.img /boot/grub/grub.cfg
run_check grep -F rootflags=subvol=@ /boot/grub/grub.cfg

log "Snapper"
run_check snapper -c root list
run_check test -f /etc/snapper/configs/root
run_check grep -F 'SUBVOLUME="/"' /etc/snapper/configs/root
run_check grep -F 'FSTYPE="btrfs"' /etc/snapper/configs/root
run_check systemctl is-enabled snapper-timeline.timer
run_check systemctl is-enabled snapper-cleanup.timer

log "services enabled and active"
run_check systemctl is-enabled sshd
run_check systemctl is-active sshd
run_check systemctl is-enabled docker
run_check systemctl is-enabled btrbk.timer
run_check systemctl is-enabled snapraid-sync.timer
run_check systemctl is-enabled snapraid-scrub.timer
run_check systemctl is-enabled smb
run_check systemctl is-enabled nmb

log "standalone installed health script"
run_check sudo nas/qemu/checks/verify-installed-health.sh "$qemu_env"

log "forbidden mergerfs error scan"
if grep -F "Unknown parameter 'category.create'" /root/nas-qemu-stage2.log /host/final-verification.log 2>/dev/null; then
  exit 1
fi
if grep -F "Unknown parameter 'fsname'" /root/nas-qemu-stage2.log /host/final-verification.log 2>/dev/null; then
  exit 1
fi

export_artifacts 0
printf 'nas-qemu-stage2.done\n' | tee /dev/ttyS0
touch /root/nas-qemu-stage2.done
sync
sleep 2
systemctl poweroff
