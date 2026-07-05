load_config() {
  if [[ -f "$ENV_FILE" ]]; then
    # The env file is trusted local host configuration.
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    log "Loaded private config: $ENV_FILE"
    LOADED_REAL_ENV=true
  elif [[ -f "$EXAMPLE_ENV_FILE" ]]; then
    warn "Private config not found: $ENV_FILE"
    warn "Using example config only. Mutating phases require .env."
    warn "Create it with: nas/bootstrap-nas.sh --init-env"
    # shellcheck disable=SC1090
    source "$EXAMPLE_ENV_FILE"
    LOADED_EXAMPLE_ENV=true
  else
    warn "No env file found; using built-in placeholders."
  fi

  split_csv_array_if_needed DATA_DISKS
  split_csv_array_if_needed DATA_DISK_LABELS

  if [[ -n "${DATA_ROOT:-}" ]]; then
    MERGERFS_MOUNT="$DATA_ROOT"
  fi
  if [[ "$START_SERVICES_AFTER_ENABLE" == "true" ]]; then
    START_SERVICES=true
  fi
  if [[ -n "$CLI_TARGET_MODE" ]]; then
    TARGET_MODE="$CLI_TARGET_MODE"
  fi
  if [[ -n "$CLI_TARGET_ROOT" ]]; then
    TARGET_ROOT="$CLI_TARGET_ROOT"
  fi
}

selected_mutating_phase() {
  [[ "$INSTALL_ARCH" == true || "$PACKAGES" == true || "$STORAGE" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true || "$START_SERVICES" == true ]]
}

resolve_check_target_mode() {
  if [[ "$CHECK_LIVE_TARGET" == true && "$CHECK_HEALTH" == true ]]; then
    die "--check-live-target and --check-health are mutually exclusive"
  fi

  if [[ "$CHECK_LIVE_TARGET" == true ]]; then
    if [[ "$CLI_TARGET_MODE" == "host" ]]; then
      die "--check-live-target must run in TARGET_MODE=live"
    fi
    TARGET_MODE="live"
  fi

  if [[ "$CHECK_HEALTH" == true ]]; then
    if [[ "$CLI_TARGET_MODE" == "live" ]]; then
      die "--check-health must run from the installed NAS OS in TARGET_MODE=host"
    fi
    TARGET_MODE="host"
  fi
}

resolve_phase_selection() {
  if [[ "$ALL" != true ]]; then
    return 0
  fi

  PACKAGES=true
  STORAGE=true
  SERVICES=true
  ENABLE_SERVICES=true

  if [[ "$TARGET_MODE" == "live" ]]; then
    INSTALL_ARCH=true
    PARTITION_OS_DISK=true
    warn "--all selected in TARGET_MODE=live: full ISO install enabled, including OS disk partitioning."
  else
    warn "--all selected in TARGET_MODE=host: host setup only; OS install and partitioning skipped."
  fi
}

validate_check_mode_selection() {
  if [[ "$CHECK_LIVE_TARGET" == true || "$CHECK_HEALTH" == true ]]; then
    if [[ "$APPLY" == true || "$ALL" == true || "$INSTALL_ARCH" == true || "$PACKAGES" == true || "$STORAGE" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true || "$CLI_START_SERVICES" == true ]]; then
      die "check modes cannot be combined with mutating phases, --apply, or --all"
    fi
  fi
}

require_real_config_for_mutation() {
  if [[ "$APPLY" == true ]] && selected_mutating_phase && [[ "$LOADED_REAL_ENV" != true ]]; then
    die "mutating phases require edited local config: $ENV_FILE. Create it with --init-env."
  fi
}

require_non_placeholder_var() {
  local name="$1"
  local value="${!name:-}"
  if is_placeholder "$value"; then
    die "required config value is missing or still a placeholder: $name"
  fi
}

require_non_placeholder_array() {
  local name="$1"
  local index value
  local -n array_ref="$name"
  local count="${#array_ref[@]}"
  [[ "$count" -gt 0 ]] || die "required config array is empty: $name"
  for ((index = 0; index < count; index++)); do
    value="${array_ref[$index]}"
    if is_placeholder "$value"; then
      die "required config array contains placeholder: ${name}[$index]=$value"
    fi
  done
}

allow_raw_path() {
  local path="$1"
  [[ "$ALLOW_RAW_DEV_PATHS" == "true" ]] && return 0
  [[ "$ALLOW_QEMU_DEVICE_NAMES" == "true" && "$path" =~ ^/dev/vd[a-z]([0-9]+)?$ ]] && return 0
  [[ "$ALLOW_QEMU_DEVICE_NAMES" == "true" && "$path" =~ ^/dev/disk/by-id/virtio- ]] && return 0
  return 1
}

validate_device_path_safety() {
  local name="$1"
  local path="$2"
  is_placeholder "$path" && die "$name is still a placeholder: $path"
  if [[ "$path" == /dev/disk/by-id/* ]]; then
    return 0
  fi
  if [[ "$path" =~ ^/dev/(sd[a-z][0-9]*|vd[a-z][0-9]*|nvme[0-9]+n[0-9]+p?[0-9]*)$ ]]; then
    allow_raw_path "$path" || die "$name must use /dev/disk/by-id/... on real hardware: $path"
    return 0
  fi
  warn "$name is not a /dev/disk/by-id path; verify it is stable: $path"
}

validate_device_exists_or_expected() {
  local name="$1"
  local path="$2"
  local may_be_created="${3:-false}"
  if [[ -e "$path" ]]; then
    return 0
  fi
  if [[ "$may_be_created" == "true" ]]; then
    warn "$name does not exist yet and is expected to be created by partitioning: $path"
    return 0
  fi
  die "$name does not exist: $path"
}

device_identity() {
  local path="$1"
  if [[ -e "$path" ]]; then
    readlink -f "$path" 2>/dev/null || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
}

paths_same_device() {
  local left="$1"
  local right="$2"
  [[ "$(device_identity "$left")" == "$(device_identity "$right")" ]]
}

validate_storage_disk_distinctness() {
  local idx other_idx disk other_disk disk_id other_id os_id parity_id

  for idx in "${!DATA_DISKS[@]}"; do
    disk="${DATA_DISKS[$idx]}"
    disk_id="$(device_identity "$disk")"
    for other_idx in "${!DATA_DISKS[@]}"; do
      (( other_idx > idx )) || continue
      other_disk="${DATA_DISKS[$other_idx]}"
      other_id="$(device_identity "$other_disk")"
      [[ "$disk_id" != "$other_id" ]] || die "DATA_DISKS contains duplicate devices: $disk and $other_disk"
    done
  done

  os_id="$(device_identity "$OS_DISK")"
  parity_id="$(device_identity "$PARITY_DISK")"
  [[ "$parity_id" != "$os_id" ]] || die "PARITY_DISK must not be OS_DISK"

  for idx in "${!DATA_DISKS[@]}"; do
    disk="${DATA_DISKS[$idx]}"
    disk_id="$(device_identity "$disk")"
    [[ "$disk_id" != "$os_id" ]] || die "DATA_DISKS[$idx] must not be OS_DISK"
    [[ "$disk_id" != "$parity_id" ]] || die "PARITY_DISK must not also be DATA_DISKS[$idx]"
    if paths_same_device "$disk" "$EFI_PARTITION" || paths_same_device "$disk" "$ROOT_PARTITION"; then
      warn "DATA_DISKS[$idx] resolves to an OS partition path; review disk mapping carefully"
    fi
  done

  if paths_same_device "$PARITY_DISK" "$EFI_PARTITION" || paths_same_device "$PARITY_DISK" "$ROOT_PARTITION"; then
    warn "PARITY_DISK resolves to an OS partition path; review disk mapping carefully"
  fi

  if [[ "$PARITY_MOUNT" == "$MERGERFS_MOUNT" || "$PARITY_MOUNT" == "$MERGERFS_MOUNT/"* ]]; then
    die "PARITY_MOUNT must not be inside MERGERFS_MOUNT"
  fi
  if [[ "$PARITY_MOUNT" == "$SNAPSHOT_VIEW_MOUNT" || "$PARITY_MOUNT" == "$SNAPSHOT_VIEW_MOUNT/"* ]]; then
    die "PARITY_MOUNT must not be inside SNAPSHOT_VIEW_MOUNT"
  fi
}

validate_config() {
  require_real_config_for_mutation
  [[ "$APPLY" == true ]] || return 0
  selected_mutating_phase || return 0

  local required name idx
  required=(NAS_HOSTNAME NAS_USER NAS_GROUP PUID PGID TARGET_ROOT TIMEZONE LOCALE)
  if [[ "$INSTALL_ARCH" == true ]]; then
    required+=(OS_DISK EFI_PARTITION ROOT_PARTITION BOOTLOADER)
  fi
  if [[ "$STORAGE" == true ]]; then
    required+=(OS_DISK PARITY_DISK PARITY_LABEL PARITY_MOUNT MERGERFS_MOUNT SNAPSHOT_VIEW_MOUNT BTRFS_DATA_MOUNT_OPTS BTRFS_DATA_FSTAB_OPTS MERGERFS_MIN_FREE_SPACE MERGERFS_CREATE_POLICY)
  fi
  if [[ "$SERVICES" == true || "$ENABLE_SERVICES" == true ]]; then
    required+=(DOCKER_ROOT DOCKER_COMPOSE_DIR DOCKER_APPDATA_DIR)
  fi
  for name in "${required[@]}"; do
    require_non_placeholder_var "$name"
  done

  [[ "$TARGET_MODE" == "host" || "$TARGET_MODE" == "live" ]] || die "TARGET_MODE must be host or live"
  [[ "$TARGET_ROOT" == /* ]] || die "TARGET_ROOT must be an absolute path"
  if [[ "$TARGET_MODE" == "live" && "$TARGET_ROOT" == "/" ]]; then
    die "TARGET_MODE=live requires TARGET_ROOT other than /"
  fi
  if [[ "$STORAGE" == true ]]; then
    require_non_placeholder_array DATA_DISKS
    require_non_placeholder_array DATA_DISK_LABELS
    [[ "${#DATA_DISKS[@]}" -eq "${#DATA_DISK_LABELS[@]}" ]] || die "DATA_DISKS and DATA_DISK_LABELS must have the same length"
  fi

  [[ "$BOOTLOADER" == "grub" ]] || die "BOOTLOADER must be grub"
  [[ "$INSTALL_INTEL_UCODE" == "true" ]] || die "INSTALL_INTEL_UCODE must be true for this Intel NAS"
  [[ "$SNAPPER_CONFIG_NAME" == "root" ]] || die "SNAPPER_CONFIG_NAME must be root"
  if [[ "$INSTALL_ARCH" == true || "$STORAGE" == true ]]; then
    [[ "$DISK_LAYOUT_REVIEWED" == "true" ]] || die "Set DISK_LAYOUT_REVIEWED=true in .env after reviewing OS/data/parity disk mapping."
  fi

  if [[ "$INSTALL_ARCH" == true ]]; then
    validate_device_path_safety OS_DISK "$OS_DISK"
    validate_device_path_safety EFI_PARTITION "$EFI_PARTITION"
    validate_device_path_safety ROOT_PARTITION "$ROOT_PARTITION"
    validate_device_exists_or_expected OS_DISK "$OS_DISK" false
    validate_device_exists_or_expected EFI_PARTITION "$EFI_PARTITION" "$PARTITION_OS_DISK"
    validate_device_exists_or_expected ROOT_PARTITION "$ROOT_PARTITION" "$PARTITION_OS_DISK"
    [[ "$EFI_PARTITION" == "$OS_DISK-part1" ]] || warn "EFI_PARTITION does not match the usual OS_DISK-part1 pattern"
    [[ "$ROOT_PARTITION" == "$OS_DISK-part2" ]] || warn "ROOT_PARTITION does not match the usual OS_DISK-part2 pattern"
  fi

  if [[ "$STORAGE" == true ]]; then
    validate_device_path_safety OS_DISK "$OS_DISK"
    validate_device_exists_or_expected OS_DISK "$OS_DISK" false
    for idx in "${!DATA_DISKS[@]}"; do
      validate_device_path_safety "DATA_DISKS[$idx]" "${DATA_DISKS[$idx]}"
      validate_device_exists_or_expected "DATA_DISKS[$idx]" "${DATA_DISKS[$idx]}" false
    done
    validate_device_path_safety PARITY_DISK "$PARITY_DISK"
    validate_device_exists_or_expected PARITY_DISK "$PARITY_DISK" false
    validate_storage_disk_distinctness
  fi
}

print_config_summary() {
  [[ "$APPLY" == true ]] || return 0
  selected_mutating_phase || return 0
  log "NAS bootstrap config summary:"
  log "  Hostname: $NAS_HOSTNAME"
  log "  User/group: $NAS_USER / $NAS_GROUP ($PUID:$PGID)"
  log "  Bootloader: $BOOTLOADER"
  log "  Target mode: $TARGET_MODE"
  log "  Target root: $TARGET_ROOT"
  log "  Final /data: $MERGERFS_MOUNT"
  log "  Active /data: $(active_mount_path "$MERGERFS_MOUNT")"
  if [[ "$INSTALL_ARCH" == true ]]; then
    log "  OS disk: $OS_DISK"
    log "  EFI partition: $EFI_PARTITION"
    log "  Root partition: $ROOT_PARTITION"
  fi
  if [[ "$STORAGE" == true ]]; then
    log "  Data disks:"
    local idx mountpoint
    for idx in "${!DATA_DISKS[@]}"; do
      mountpoint="/mnt/disk$((idx + 1))"
      log "    disk$((idx + 1)): ${DATA_DISKS[$idx]} -> label ${DATA_DISK_LABELS[$idx]} -> $mountpoint"
      log "      active disk$((idx + 1)): $(active_mount_path "$mountpoint")"
    done
    log "  Parity: $PARITY_DISK -> label $PARITY_LABEL -> $PARITY_MOUNT"
    log "  Active parity: $(active_mount_path "$PARITY_MOUNT")"
    log "  Pool: /mnt/disk*/pool -> $MERGERFS_MOUNT"
    log "  Snapshots: /mnt/disk*/snapshots -> $SNAPSHOT_VIEW_MOUNT"
    log "  Active snapshots: $(active_mount_path "$SNAPSHOT_VIEW_MOUNT")"
  fi
}

preflight_storage() {
  if [[ "${#DATA_DISKS[@]}" -eq 0 ]]; then
    warn "DATA_DISKS is empty."
  fi
  if [[ "${#DATA_DISKS[@]}" -ne "${#DATA_DISK_LABELS[@]}" ]]; then
    if [[ "$APPLY" == true ]]; then
      die "DATA_DISKS and DATA_DISK_LABELS must have the same length"
    fi
    warn "DATA_DISKS and DATA_DISK_LABELS lengths differ."
  fi

  local disk
  for disk in "${DATA_DISKS[@]}"; do
    if is_placeholder "$disk"; then
      warn "Data disk placeholder still present: $disk"
    elif [[ ! -e "$disk" ]]; then
      if [[ "$APPLY" == true ]]; then
        die "configured data disk does not exist: $disk"
      fi
      warn "Configured data disk not present on this machine: $disk"
    fi
  done

  local active_pool
  active_pool="$(active_mount_path "$MERGERFS_MOUNT")"
  if [[ -d "$active_pool" ]] && command -v findmnt >/dev/null 2>&1; then
    if ! findmnt -n "$active_pool" >/dev/null 2>&1; then
      if find "$active_pool" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        if [[ "$APPLY" == true ]]; then
          die "$active_pool exists, is not a mount, and is not empty"
        fi
        warn "$active_pool exists, is not a mount, and is not empty"
      fi
    fi
  fi
}

preflight() {
  log "Mode: $([[ "$APPLY" == true ]] && printf apply || printf dry-run)"
  log "Target mode: $TARGET_MODE"
  log "Target root: $TARGET_ROOT"
  if [[ "$PARTITION_OS_DISK" == true ]]; then
    warn "OS disk partitioning is permitted by --partition-os-disk."
  fi
  if { [[ "$APPLY" == true ]] && selected_mutating_phase; } || [[ "$CHECK_LIVE_TARGET" == true || "$CHECK_HEALTH" == true ]]; then
    require_root
  fi
  if [[ "$APPLY" == true && "$PACKAGES" == true ]]; then
    require_cmd pacman
  fi
  if [[ "$INSTALL_ARCH" == true ]]; then
    local command
    for command in pacstrap genfstab arch-chroot; do
      if ! command -v "$command" >/dev/null 2>&1; then
        if [[ "$APPLY" == true ]]; then
          die "--install-arch requires $command from the Arch ISO"
        fi
        warn "--install-arch will require $command from the Arch ISO"
      fi
    done
  fi
  if [[ "$STORAGE" == true ]]; then
    preflight_storage
  fi
  mkdir -p "$STAGING_DIR"
}

print_summary() {
  log "Planned actions:"
  log "  install_arch=$INSTALL_ARCH packages=$PACKAGES storage=$STORAGE"
  log "  services=$SERVICES enable_services=$ENABLE_SERVICES"
  log "  checks: live_target=$CHECK_LIVE_TARGET health=$CHECK_HEALTH"
}

blkid_value() {
  local device="$1"
  local field="$2"
  command -v blkid >/dev/null 2>&1 || return 1
  is_placeholder "$device" && return 1
  [[ -e "$device" ]] || return 1
  blkid -s "$field" -o value "$device" 2>/dev/null || return 1
}

filesystem_matches() {
  local device="$1"
  local fs_type="$2"
  local label="${3:-}"
  local actual_type
  actual_type="$(blkid_value "$device" TYPE || true)"
  [[ "$actual_type" == "$fs_type" ]] || return 1
  if [[ -n "$label" ]]; then
    local actual_label
    actual_label="$(blkid_value "$device" LABEL || true)"
    [[ "$actual_label" == "$label" ]] || return 1
  fi
}

uncomment_locale() {
  local path="$1"
  local locale="$2"
  log "+ uncomment $locale UTF-8 in $path"
  if [[ "$APPLY" == true ]]; then
    sed -i "s/^#${locale} UTF-8/${locale} UTF-8/" "$path"
  fi
}
