ensure_chroot_user() {
  local target_root="$1"
  local user="$2"
  log "+ arch-chroot $target_root ensure user $user"
  if [[ "$APPLY" == true ]]; then
    if ! arch-chroot "$target_root" id "$user" >/dev/null 2>&1; then
      arch-chroot "$target_root" useradd -m -G wheel "$user"
    fi
  fi
}

create_os_subvolumes() {
  local root_partition="$1"
  local temp_mount="$2"

  ensure_safe_mountpoint "$temp_mount"
  if [[ "$APPLY" == true ]] && mountpoint -q "$temp_mount"; then
    die "$temp_mount is already mounted; refusing to continue"
  fi

  cleanup_os_temp_mount() {
    if [[ "$APPLY" == true ]]; then
      if mountpoint -q "$temp_mount"; then
        umount "$temp_mount"
      fi
      rmdir "$temp_mount" 2>/dev/null || true
    fi
  }
  trap cleanup_os_temp_mount RETURN

  run mount -o "$BTRFS_OS_MOUNT_OPTS" "$root_partition" "$temp_mount"

  local subvol
  for subvol in @ @home @log @pkg @snapshots @swap; do
    if [[ "$APPLY" == true && -e "$temp_mount/$subvol" ]]; then
      log "OS subvolume already exists: $subvol"
    else
      run btrfs subvolume create "$temp_mount/$subvol"
    fi
  done

  run umount "$temp_mount"
  if [[ "$APPLY" == true ]]; then
    rmdir "$temp_mount" 2>/dev/null || true
  fi
  trap - RETURN
}

configure_grub_defaults() {
  local target_root="$1"
  local grub_default="$target_root/etc/default/grub"

  log "+ ensure rootflags=subvol=@ in $grub_default"
  if [[ "$APPLY" == true ]]; then
    [[ -f "$grub_default" ]] || die "missing GRUB defaults file after pacstrap: $grub_default"
    if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_default"; then
      printf 'GRUB_CMDLINE_LINUX_DEFAULT="rootflags=subvol=@"\n' >>"$grub_default"
    elif ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=.*rootflags=subvol=@' "$grub_default"; then
      sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=")([^"]*)"/\1\2 rootflags=subvol=@"/' "$grub_default"
    fi
  fi
}

chroot_unit_exists() {
  local target_root="$1"
  local unit="$2"
  [[ "$APPLY" == true ]] || return 0
  arch-chroot "$target_root" systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"
}

enable_chroot_unit_if_exists() {
  local target_root="$1"
  local unit="$2"
  if [[ "$APPLY" != true ]]; then
    run arch-chroot "$target_root" systemctl enable "$unit"
    return 0
  fi
  if chroot_unit_exists "$target_root" "$unit"; then
    run arch-chroot "$target_root" systemctl enable "$unit"
  else
    warn "Target unit not available, not enabling: $unit"
  fi
}

configure_snapper_os() {
  local target_root="$1"
  log "Phase: configure Snapper for OS/root snapshots"
  ensure_dir "$target_root/etc/snapper/configs"
  ensure_dir "$target_root/etc/conf.d"
  ensure_dir "$target_root/.snapshots"

  write_text "$target_root/etc/snapper/configs/$SNAPPER_CONFIG_NAME" \
    'SUBVOLUME="/"'$'\n''FSTYPE="btrfs"'$'\n\n''ALLOW_USERS=""'$'\n''ALLOW_GROUPS="wheel"'$'\n\n''SYNC_ACL="no"'$'\n\n''BACKGROUND_COMPARISON="yes"'$'\n\n''NUMBER_CLEANUP="yes"'$'\n''NUMBER_MIN_AGE="1800"'$'\n''NUMBER_LIMIT="20"'$'\n''NUMBER_LIMIT_IMPORTANT="10"'$'\n\n''TIMELINE_CREATE="yes"'$'\n''TIMELINE_CLEANUP="yes"'$'\n''TIMELINE_MIN_AGE="1800"'$'\n''TIMELINE_LIMIT_HOURLY="10"'$'\n''TIMELINE_LIMIT_DAILY="7"'$'\n''TIMELINE_LIMIT_WEEKLY="4"'$'\n''TIMELINE_LIMIT_MONTHLY="3"'$'\n''TIMELINE_LIMIT_YEARLY="0"'$'\n\n''EMPTY_PRE_POST_CLEANUP="yes"'$'\n''EMPTY_PRE_POST_MIN_AGE="1800"'$'\n'
  write_text "$target_root/etc/conf.d/snapper" "SNAPPER_CONFIGS=\"$SNAPPER_CONFIG_NAME\""$'\n'
}

install_grub_bootloader() {
  local target_root="$1"
  log "Phase: install GRUB UEFI bootloader"
  configure_grub_defaults "$target_root"
  ensure_dir "$target_root/boot/grub"
  run arch-chroot "$target_root" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="$GRUB_BOOTLOADER_ID"
  run arch-chroot "$target_root" grub-mkconfig -o /boot/grub/grub.cfg
  if [[ "$APPLY" == true ]]; then
    [[ -s "$target_root/boot/grub/grub.cfg" ]] || die "GRUB config was not generated"
    grep -q 'intel-ucode.img' "$target_root/boot/grub/grub.cfg" || die "GRUB config is missing intel-ucode.img"
    grep -q 'rootflags=subvol=@' "$target_root/boot/grub/grub.cfg" || die "GRUB config is missing rootflags=subvol=@"
  fi
}

create_initial_os_snapshot() {
  local target_root="$1"
  log "Phase: create initial Snapper OS snapshot"
  run arch-chroot "$target_root" snapper --no-dbus -c "$SNAPPER_CONFIG_NAME" create --description "$SNAPPER_INITIAL_SNAPSHOT_DESCRIPTION"
  run arch-chroot "$target_root" grub-mkconfig -o /boot/grub/grub.cfg
}

install_arch_system() {
  log "Phase: install minimal Arch from ISO"
  if is_placeholder "$ROOT_PARTITION" || is_placeholder "$EFI_PARTITION"; then
    die "--install-arch requires --root-partition and --efi-partition or edited env values"
  fi

  if [[ "$PARTITION_OS_DISK" == true ]]; then
    is_placeholder "$OS_DISK" && die "--partition-os-disk requires --os-disk"
    confirm_destructive "About to wipe and repartition the OS disk." "$OS_DISK"
    run sgdisk --zap-all "$OS_DISK"
    run sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$OS_DISK"
    run sgdisk -n 2:0:0 -t 2:8304 -c 2:arch-root "$OS_DISK"
    run partprobe "$OS_DISK"
    if command -v udevadm >/dev/null 2>&1; then
      run udevadm settle
    fi
  fi

  if ! filesystem_matches "$EFI_PARTITION" vfat; then
    confirm_destructive "About to format the OS EFI partition as FAT32." "$EFI_PARTITION"
    run mkfs.fat -F32 "$EFI_PARTITION"
  fi

  if ! filesystem_matches "$ROOT_PARTITION" btrfs arch-root; then
    confirm_destructive "About to format the OS root partition as btrfs." "$ROOT_PARTITION"
    run mkfs.btrfs -f -L arch-root "$ROOT_PARTITION"
  fi

  local pacstrap_packages=(
    base
    base-devel
    linux
    linux-firmware
    intel-ucode
    btrfs-progs
    networkmanager
    sudo
    openssh
    inetutils
    git
    python
    vim
    neovim
    tmux
    grub
    efibootmgr
    snapper
    snap-pac
    grub-btrfs
    inotify-tools
  )

  create_os_subvolumes "$ROOT_PARTITION" "$OS_SUBVOL_TEMP_MOUNT"
  ensure_safe_mountpoint "$TARGET_ROOT"
  run mount -o "$BTRFS_OS_MOUNT_OPTS,subvol=@" "$ROOT_PARTITION" "$TARGET_ROOT"
  ensure_safe_mountpoint "$TARGET_ROOT/home"
  ensure_safe_mountpoint "$TARGET_ROOT/var/log"
  ensure_safe_mountpoint "$TARGET_ROOT/var/cache/pacman/pkg"
  ensure_safe_mountpoint "$TARGET_ROOT/.snapshots"
  ensure_safe_mountpoint "$TARGET_ROOT/swap"
  ensure_safe_mountpoint "$TARGET_ROOT/boot"
  run mount -o "$BTRFS_OS_MOUNT_OPTS,subvol=@home" "$ROOT_PARTITION" "$TARGET_ROOT/home"
  run mount -o "$BTRFS_OS_MOUNT_OPTS,subvol=@log" "$ROOT_PARTITION" "$TARGET_ROOT/var/log"
  run mount -o "$BTRFS_OS_MOUNT_OPTS,subvol=@pkg" "$ROOT_PARTITION" "$TARGET_ROOT/var/cache/pacman/pkg"
  run mount -o "$BTRFS_OS_MOUNT_OPTS,subvol=@snapshots" "$ROOT_PARTITION" "$TARGET_ROOT/.snapshots"
  run mount -o "$BTRFS_OS_MOUNT_OPTS,subvol=@swap" "$ROOT_PARTITION" "$TARGET_ROOT/swap"
  run mount "$EFI_PARTITION" "$TARGET_ROOT/boot"
  if [[ "$APPLY" == true ]]; then
    check_host_pacman_packages_available "${pacstrap_packages[@]}"
  fi
  run pacstrap -K "$TARGET_ROOT" "${pacstrap_packages[@]}"
  ensure_target_resolver
  write_fresh_install_fstab "$TARGET_ROOT"
  run arch-chroot "$TARGET_ROOT" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  run arch-chroot "$TARGET_ROOT" hwclock --systohc
  uncomment_locale "$TARGET_ROOT/etc/locale.gen" "$LOCALE"
  run arch-chroot "$TARGET_ROOT" locale-gen
  write_text "$TARGET_ROOT/etc/locale.conf" "LANG=$LOCALE"$'\n'
  write_text "$TARGET_ROOT/etc/hostname" "$NAS_HOSTNAME"$'\n'
  write_text "$TARGET_ROOT/etc/hosts" "127.0.0.1 localhost"$'\n'"::1 localhost"$'\n'"127.0.1.1 $NAS_HOSTNAME.localdomain $NAS_HOSTNAME"$'\n'
  ensure_chroot_user "$TARGET_ROOT" "$NAS_USER"
  ensure_dir "$TARGET_ROOT/etc/sudoers.d"
  write_text "$TARGET_ROOT/etc/sudoers.d/10-wheel" "%wheel ALL=(ALL:ALL) ALL"$'\n'
  run chmod 0440 "$TARGET_ROOT/etc/sudoers.d/10-wheel"
  if [[ "$SNAPPER_ENABLE" == "true" ]]; then
    configure_snapper_os "$TARGET_ROOT"
  else
    warn "SNAPPER_ENABLE is false; skipping OS Snapper configuration."
  fi
  run arch-chroot "$TARGET_ROOT" systemctl enable NetworkManager sshd
  if [[ "$SNAPPER_ENABLE" == "true" ]]; then
    enable_chroot_unit_if_exists "$TARGET_ROOT" snapper-timeline.timer
    enable_chroot_unit_if_exists "$TARGET_ROOT" snapper-cleanup.timer
  fi
  if [[ "$GRUB_BTRFS_ENABLE" == "true" ]]; then
    enable_chroot_unit_if_exists "$TARGET_ROOT" grub-btrfsd.service
  fi
  install_grub_bootloader "$TARGET_ROOT"
  if [[ "$SNAPPER_ENABLE" == "true" ]]; then
    create_initial_os_snapshot "$TARGET_ROOT"
  else
    warn "SNAPPER_ENABLE is false; skipping initial OS snapshot."
  fi
  warn "Set passwords before rebooting: arch-chroot $TARGET_ROOT passwd; arch-chroot $TARGET_ROOT passwd $NAS_USER"
}
