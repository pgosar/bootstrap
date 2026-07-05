create_os_subvolumes() {
  local root_partition="$1" temp_mount="$2"
  ensure_safe_mountpoint "$temp_mount"
  if [[ "$APPLY" == true ]] && mountpoint -q "$temp_mount"; then
    die "$temp_mount is already mounted; refusing to continue"
  fi

  local mounted=false
  cleanup() {
    if [[ "$mounted" == true ]] && mountpoint -q "$temp_mount"; then
      umount "$temp_mount"
    fi
  }
  trap cleanup RETURN

  if [[ "$APPLY" == true ]]; then
    run mount -o "$BTRFS_OS_MOUNT_OPTS" "$root_partition" "$temp_mount"
    mounted=true
    local pair name path
    for pair in "${ROOT_SUBVOL_LAYOUT[@]}"; do
      name="${pair%%|*}"
      path="${pair##*|}"
      if [[ -e "$temp_mount/$name" ]]; then
        log "OS subvolume already exists: $name"
      else
        run btrfs subvolume create "$temp_mount/$name"
      fi
      ensure_dir "$temp_mount$path"
    done
  else
    log "+ mount -o $(printf '%q' "$BTRFS_OS_MOUNT_OPTS") $(printf '%q' "$root_partition") $(printf '%q' "$temp_mount")"
    log "+ create btrfs subvolumes under $temp_mount"
  fi

  cleanup
  trap - RETURN
}

mount_os_subvolumes() {
  local root_partition="$1" target_root="$2" pair name path
  ensure_safe_mountpoint "$target_root"
  run mount -o "$BTRFS_OS_MOUNT_OPTS,subvol=@" "$root_partition" "$target_root"
  for pair in "${ROOT_SUBVOL_LAYOUT[@]}"; do
    name="${pair%%|*}"
    path="${pair##*|}"
    [[ "$name" == "@" ]] && continue
    ensure_safe_mountpoint "$target_root$path"
    run mount -o "$BTRFS_OS_MOUNT_OPTS,subvol=$name" "$root_partition" "$target_root$path"
  done
}

partition_os_disk() {
  [[ "$PARTITION_OS_DISK" == true ]] || return 0
  confirm_destructive "About to partition the OS disk and format EFI/root filesystems." "$OS_DISK"
  if [[ "$APPLY" == true ]]; then
    run sgdisk --zap-all "$OS_DISK"
    run sgdisk -n1:0:+1G -t1:ef00 -c1:EFI "$OS_DISK"
    run sgdisk -n2:0:0 -t2:8300 -c2:root "$OS_DISK"
    run partprobe "$OS_DISK"
    sleep 2
    if ! filesystem_matches "$EFI_PARTITION" vfat ; then
      confirm_destructive "About to format the OS EFI partition as FAT32." "$EFI_PARTITION"
      run mkfs.fat -F32 "$EFI_PARTITION"
    fi
    if ! filesystem_matches "$ROOT_PARTITION" btrfs arch-root ; then
      confirm_destructive "About to format the OS root partition as btrfs." "$ROOT_PARTITION"
      run mkfs.btrfs -f -L arch-root "$ROOT_PARTITION"
    fi
  else
    log "+ partition and format OS disk: $OS_DISK"
  fi
}

filesystem_matches() {
  local device="$1" fstype="${2:-}" label="${3:-}"
  if ! command -v blkid >/dev/null 2>&1; then
    return 1
  fi
  local actual_type actual_label
  actual_type="$(blkid -s TYPE -o value "$device" 2>/dev/null || true)"
  actual_label="$(blkid -s LABEL -o value "$device" 2>/dev/null || true)"
  [[ -z "$fstype" || "$actual_type" == "$fstype" ]] || return 1
  [[ -z "$label" || "$actual_label" == "$label" ]] || return 1
  return 0
}

write_pc_fstab() {
  local target_root="$1"
  write_fresh_install_fstab "$target_root"
}

configure_grub_defaults() {
  local grub_default="$1"
  local content
  content="$(cat <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="nowatchdog nvme_load=YES zswap.enabled=0 splash loglevel=3 rootflags=subvol=@"
GRUB_CMDLINE_LINUX=""
GRUB_PRELOAD_MODULES="part_gpt part_msdos"
GRUB_DISABLE_RECOVERY="true"
EOF
)"
  write_text "$grub_default" "$content"
}

configure_mkinitcpio() {
  local mkinitcpio="$1"
  local content
  content="$(cat <<EOF
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode kms modconf block keyboard sd-vconsole filesystems)
COMPRESSION="zstd"
EOF
)"
  write_text "$mkinitcpio" "$content"
}

write_next_steps_file() {
  local target_root="$1"
  local file="$target_root/root/PC_POST_INSTALL_NEXT_STEPS.txt"
  local content
  content="$(cat <<EOF
Set passwords before rebooting:

  arch-chroot $target_root passwd
  arch-chroot $target_root passwd $PC_USER

Then run:

  sudo pc/bin/bootstrap-pc.sh --env-file pc/.env --check-live-target

Then reboot without the ISO and run:

  sudo pc/bin/bootstrap-pc.sh --env-file pc/.env --check-health
EOF
)"
  write_text "$file" "$content"
}

finalize_installed_system() {
  local target_root="$1"
  if [[ "$APPLY" != true ]]; then
    log "+ finalize installed system at $target_root"
    return 0
  fi

  arch-chroot "$target_root" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  arch-chroot "$target_root" hwclock --systohc
  arch-chroot "$target_root" locale-gen
  arch-chroot "$target_root" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$GRUB_BOOTLOADER_ID" --recheck
  arch-chroot "$target_root" grub-mkconfig -o /boot/grub/grub.cfg
  arch-chroot "$target_root" mkinitcpio -P
}

install_arch_system() {
  require_root
  [[ "$TARGET_MODE" == "live" ]] || die "--install-arch is intended for TARGET_MODE=live"
  [[ "$INSTALL_ARCH" == true ]] || return 0
  validate_disk_mapping

  local target_root="$TARGET_ROOT"
  local os_mount="$target_root"
  local boot_mount="$target_root/boot/efi"
  local temp_mount="$OS_SUBVOL_TEMP_MOUNT"

  partition_os_disk
  create_os_subvolumes "$ROOT_PARTITION" "$temp_mount"
  mount_os_subvolumes "$ROOT_PARTITION" "$target_root"
  ensure_safe_mountpoint "$boot_mount"
  run mount "$EFI_PARTITION" "$boot_mount"

  local pacstrap_packages=(
    base
    base-devel
    "$KERNEL_PACKAGE"
    linux-firmware
    "$MICROCODE_PACKAGE"
    btrfs-progs
    grub
    efibootmgr
    sudo
    openssh
    git
    python
    vim
    neovim
    tmux
    inetutils
  )
  if [[ "$APPLY" == true ]]; then
    run pacman -Sy --noconfirm
    check_pacman_packages_available "${pacstrap_packages[@]}"
    run pacstrap -K "$target_root" "${pacstrap_packages[@]}"
  else
    log "+ pacstrap -K $(printf '%q' "$target_root") ..."
  fi

  if [[ "$APPLY" == true ]]; then
    write_pc_fstab "$target_root"
  fi
}
