#!/usr/bin/env bash
set -euo pipefail

trap 'echo "ERROR: guest stage 1 failed at line $LINENO: $BASH_COMMAND"' ERR

exec > >(tee -a /root/stage1.log) 2>&1

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

mount_host_share() {
  mkdir -p /host
  modprobe 9pnet_virtio || true
  if ! mountpoint -q /host; then
    mount -t 9p -o trans=virtio hostshare /host || true
  fi
}

export_artifacts() {
  mount_host_share
  cp /root/stage1.log /host/stage1-guest.log || true
  [[ -f /root/final-verification.log ]] && cp /root/final-verification.log /host/final-verification.log || true
  [[ -f /mnt/etc/fstab ]] && cp /mnt/etc/fstab /host/target-fstab || true
  [[ -f /mnt/boot/grub/grub.cfg ]] && cp /mnt/boot/grub/grub.cfg /host/grub.cfg || true
  sync
}

trap export_artifacts EXIT

log "stage1: live Arch ISO one-phase NAS install"
if [[ -d /sys/firmware/efi ]]; then
  echo "UEFI firmware interface detected."
else
  echo "WARNING: /sys/firmware/efi is not visible in the live ISO; GRUB install will be the authoritative UEFI check."
fi
timedatectl set-ntp true || true
mount_host_share

rm -rf /root/bootstrap
mkdir -p /root/bootstrap
QEMU_HTTP_PORT="${QEMU_HTTP_PORT:-18080}"

curl -fsSL "http://10.0.2.2:${QEMU_HTTP_PORT}/bootstrap.tar" -o /root/bootstrap.tar
tar -xf /root/bootstrap.tar -C /root/bootstrap

cd /root/bootstrap
qemu_env="/root/bootstrap/nas/qemu/qemu-nas.env"
unreviewed_env="/root/qemu-nas-unreviewed.env"
raw_rejected_env="/root/qemu-nas-raw-rejected.env"

{
  log "static checks"
  run_check bash -n nas/bootstrap-nas.sh
  run_check bash -n nas/lib/00-defaults.sh nas/lib/10-utils.sh nas/lib/20-config.sh nas/lib/30-install-arch.sh nas/lib/40-packages.sh nas/lib/50-storage.sh nas/lib/60-services.sh nas/lib/70-checks.sh nas/lib/90-main.sh
  if command -v shellcheck >/dev/null 2>&1; then
    run_check shellcheck nas/bootstrap-nas.sh nas/lib/00-defaults.sh nas/lib/10-utils.sh nas/lib/20-config.sh nas/lib/30-install-arch.sh nas/lib/40-packages.sh nas/lib/50-storage.sh nas/lib/60-services.sh nas/lib/70-checks.sh nas/lib/90-main.sh
  else
    echo "ShellCheck unavailable; skipped."
  fi
  run_shell_check "! grep -R 'fuse[.]mergerfs' -n nas"
  run_shell_check "! grep -R 'fsname=merger[f]s' -n nas"
  run_check nas/bootstrap-nas.sh --help
  run_check nas/bootstrap-nas.sh --list-disks

  log "fresh fake disk inventory"
  run_check lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS

  log "negative safety check: disk layout not reviewed"
  cp "$qemu_env" "$unreviewed_env"
  sed -i 's/DISK_LAYOUT_REVIEWED="true"/DISK_LAYOUT_REVIEWED="false"/' "$unreviewed_env"
  if nas/bootstrap-nas.sh \
      --env-file "$unreviewed_env" \
      --target-mode live \
      --target-root /mnt \
      --apply \
      --all; then
    echo "ERROR: unreviewed disk layout was accepted"
    exit 1
  else
    echo "OK: DISK_LAYOUT_REVIEWED=false was rejected"
  fi

  log "negative safety check: raw virtio devices require QEMU opt-in"
  cp "$qemu_env" "$raw_rejected_env"
  sed -i 's/ALLOW_QEMU_DEVICE_NAMES="true"/ALLOW_QEMU_DEVICE_NAMES="false"/' "$raw_rejected_env"
  if nas/bootstrap-nas.sh \
      --env-file "$raw_rejected_env" \
      --target-mode live \
      --target-root /mnt \
      --apply \
      --all; then
    echo "ERROR: raw virtio device paths were accepted without QEMU opt-in"
    exit 1
  else
    echo "OK: raw virtio device paths were rejected without QEMU opt-in"
  fi

  log "one-phase bootstrap command"
  printf 'yes, do as I say\n' | sudo nas/bootstrap-nas.sh \
    --env-file "$qemu_env" \
    --target-mode live \
    --target-root /mnt \
    --apply \
    --all

  log "pre-reboot live target check"
  run_check sudo nas/bootstrap-nas.sh \
    --env-file "$qemu_env" \
    --check-live-target

  log "pre-reboot OS mount tree"
  run_check findmnt -R /mnt

  log "target fstab"
  run_check cat /mnt/etc/fstab
  run_shell_check "! grep -E 'fuse[.]mergerfs' /mnt/etc/fstab"
  run_shell_check "! grep -E 'fsname=merger[f]s' /mnt/etc/fstab"
  run_shell_check "! awk '\$2 == \"/data\" && \$3 == \"mergerfs\" { found=1 } END { exit !found }' /mnt/etc/fstab"
  run_shell_check "! awk '\$2 == \"/mnt/snapshots\" && \$3 == \"mergerfs\" { found=1 } END { exit !found }' /mnt/etc/fstab"
  run_check cat /mnt/etc/systemd/system/data.mount
  run_check cat /mnt/etc/systemd/system/mnt-snapshots.mount
  run_shell_check "grep -F 'Where=/data' /mnt/etc/systemd/system/data.mount"
  run_shell_check "grep -F 'Type=mergerfs' /mnt/etc/systemd/system/data.mount"
  run_shell_check "grep -F '/mnt/disk1/pool:/mnt/disk2/pool:/mnt/disk3/pool' /mnt/etc/systemd/system/data.mount"
  run_shell_check "grep -F 'Where=/mnt/snapshots' /mnt/etc/systemd/system/mnt-snapshots.mount"
  run_shell_check "grep -F 'Type=mergerfs' /mnt/etc/systemd/system/mnt-snapshots.mount"
  run_shell_check "grep -F 'Options=defaults,ro,cache.files=off' /mnt/etc/systemd/system/mnt-snapshots.mount"

  log "active mergerfs mounts before reboot"
  run_check findmnt /mnt/data
  run_check findmnt /mnt/mnt/snapshots
  run_check findmnt /mnt/swap
  run_check findmnt -n -o FSTYPE,OPTIONS /mnt/data
  run_check findmnt -n -o FSTYPE,OPTIONS /mnt/mnt/snapshots
  run_shell_check "findmnt -n -o OPTIONS /mnt/data | tr ',' '\n' | (! grep -qx ro)"
  run_shell_check "findmnt -n -o OPTIONS /mnt/mnt/snapshots | tr ',' '\n' | grep -qx ro"
  run_shell_check "findmnt -n -o OPTIONS /mnt/swap | grep -Eq 'subvol=/?@swap([,]|$)'"

  log "write behavior before reboot"
  run_shell_check "touch /mnt/data/.nas-bootstrap-qemu-write-test && test -f /mnt/data/.nas-bootstrap-qemu-write-test && rm -f /mnt/data/.nas-bootstrap-qemu-write-test"
  if touch /mnt/mnt/snapshots/.nas-bootstrap-should-fail 2>/root/snapshot-write.err; then
    echo "ERROR: snapshot view is writable"
    exit 1
  else
    echo "OK: snapshot view is read-only"
  fi

  log "target packages"
  run_check arch-chroot /mnt pacman -Q yay mergerfs snapraid grub snapper snap-pac docker samba btrbk inetutils

  log "target GRUB"
  run_check test -s /mnt/boot/grub/grub.cfg
  run_check grep -F intel-ucode.img /mnt/boot/grub/grub.cfg
  run_check grep -F rootflags=subvol=@ /mnt/boot/grub/grub.cfg

  log "target Snapper"
  run_check arch-chroot /mnt snapper --no-dbus -c root list
  run_check test -f /mnt/etc/snapper/configs/root
  run_check grep -F 'SUBVOLUME="/"' /mnt/etc/snapper/configs/root
  run_check grep -F 'FSTYPE="btrfs"' /mnt/etc/snapper/configs/root

  log "target Docker dependency"
  run_check cat /mnt/etc/systemd/system/docker.service.d/wait-for-data.conf

  log "target services enabled"
  run_check arch-chroot /mnt systemctl is-enabled sshd
  run_check arch-chroot /mnt systemctl is-enabled docker
  run_check arch-chroot /mnt systemctl is-enabled snapper-timeline.timer
  run_check arch-chroot /mnt systemctl is-enabled snapper-cleanup.timer
  run_check arch-chroot /mnt systemctl is-enabled btrbk.timer
  run_check arch-chroot /mnt systemctl is-enabled snapraid-sync.timer
  run_check arch-chroot /mnt systemctl is-enabled snapraid-scrub.timer
  run_check arch-chroot /mnt systemctl is-enabled smb
  run_check arch-chroot /mnt systemctl is-enabled nmb

  log "install post-reboot verifier"
cp -a /root/bootstrap /mnt/root/bootstrap
cp "$qemu_env" /mnt/root/qemu-nas.env
install -m 0755 /root/bootstrap/nas/qemu/guest/stage2.sh /mnt/root/guest-stage2.sh

  cat > /mnt/etc/systemd/system/nas-qemu-stage2.service <<'EOF'
[Unit]
Description=Run NAS bootstrap QEMU post-reboot verifier once
After=network-online.target local-fs.target
Wants=network-online.target
ConditionPathExists=!/root/nas-qemu-stage2.done

[Service]
Type=oneshot
ExecStart=/root/guest-stage2.sh
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  arch-chroot /mnt systemctl enable nas-qemu-stage2.service
} | tee -a /root/final-verification.log

export_artifacts
sync
poweroff
