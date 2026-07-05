load_config() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    LOADED_REAL_ENV=true
    log "Loaded private config: $ENV_FILE"
  elif [[ -f "$EXAMPLE_ENV_FILE" ]]; then
    warn "Private config not found: $ENV_FILE"
    warn "Using example config only. Mutating phases require .env."
    # shellcheck disable=SC1090
    source "$EXAMPLE_ENV_FILE"
    LOADED_EXAMPLE_ENV=true
  else
    warn "No env file found; using built-in placeholders."
  fi

  if [[ -n "${CLI_TARGET_MODE:-}" ]]; then
    TARGET_MODE="$CLI_TARGET_MODE"
  fi
  if [[ -n "${CLI_TARGET_ROOT:-}" ]]; then
    TARGET_ROOT="$CLI_TARGET_ROOT"
  fi
}

selected_mutating_phase() {
  [[ "$INSTALL_ARCH" == true || "$PACKAGES" == true || "$SYSTEM" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true || "$START_SERVICES" == true ]]
}

resolve_check_target_mode() {
  if [[ "$CHECK_LIVE_TARGET" == true && "$CHECK_HEALTH" == true ]]; then
    die "--check-live-target and --check-health are mutually exclusive"
  fi
  if [[ "$CHECK_LIVE_TARGET" == true ]]; then
    [[ "$CLI_TARGET_MODE" != "host" ]] || die "--check-live-target must run in TARGET_MODE=live"
    TARGET_MODE="live"
  fi
  if [[ "$CHECK_HEALTH" == true ]]; then
    [[ "$CLI_TARGET_MODE" != "live" ]] || die "--check-health must run in TARGET_MODE=host"
    TARGET_MODE="host"
  fi
}

resolve_phase_selection() {
  [[ "$ALL" == true ]] || return 0
  PACKAGES=true
  SYSTEM=true
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
    if [[ "$APPLY" == true || "$ALL" == true || "$INSTALL_ARCH" == true || "$PACKAGES" == true || "$SYSTEM" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true || "$START_SERVICES" == true ]]; then
      die "check modes cannot be combined with mutating phases, --apply, or --all"
    fi
  fi
}

require_real_config_for_mutation() {
  if [[ "$APPLY" == true ]] && selected_mutating_phase && [[ "$LOADED_REAL_ENV" != true ]]; then
    die "mutating phases require edited local config: $ENV_FILE. Create it with --init-env."
  fi
}

validate_disk_mapping() {
  validate_device_path_safety OS_DISK "$OS_DISK"
  validate_device_path_safety EFI_PARTITION "$EFI_PARTITION"
  validate_device_path_safety ROOT_PARTITION "$ROOT_PARTITION"

  validate_device_exists_or_expected OS_DISK "$OS_DISK" false
  validate_device_exists_or_expected EFI_PARTITION "$EFI_PARTITION" "$PARTITION_OS_DISK"
  validate_device_exists_or_expected ROOT_PARTITION "$ROOT_PARTITION" "$PARTITION_OS_DISK"

  [[ "$EFI_PARTITION" == "$OS_DISK-part1" ]] || warn "EFI_PARTITION does not match the usual OS_DISK-part1 pattern"
  [[ "$ROOT_PARTITION" == "$OS_DISK-part2" ]] || warn "ROOT_PARTITION does not match the usual OS_DISK-part2 pattern"
  [[ "$EFI_PARTITION" != "$ROOT_PARTITION" ]] || die "EFI_PARTITION and ROOT_PARTITION must differ"

  if [[ "$ROOT_PARTITION" == "$OS_DISK" || "$EFI_PARTITION" == "$OS_DISK" ]]; then
    die "partition paths must not equal OS_DISK"
  fi
}

validate_config() {
  require_real_config_for_mutation
  [[ "$TARGET_MODE" == "host" || "$TARGET_MODE" == "live" ]] || die "TARGET_MODE must be host or live"
  [[ "$TARGET_ROOT" == /* ]] || die "TARGET_ROOT must be an absolute path"
  [[ "$BOOTLOADER" == "grub" ]] || die "BOOTLOADER must be grub"
  [[ "$INSTALL_MICROCODE" == "true" ]] || die "INSTALL_MICROCODE must be true for this AMD host"
  if [[ "$INSTALL_ARCH" == true || "$PACKAGES" == true || "$SYSTEM" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true ]]; then
    require_non_placeholder_var PC_HOSTNAME
    require_non_placeholder_var PC_USER
    require_non_placeholder_var TIMEZONE
    require_non_placeholder_var LOCALE
    require_non_placeholder_var KEYMAP
    require_non_placeholder_var KERNEL_PACKAGE
    require_non_placeholder_var KERNEL_HEADERS_PACKAGE
    require_non_placeholder_var MICROCODE_PACKAGE
  fi
  if [[ "$INSTALL_ARCH" == true ]]; then
    validate_disk_mapping
    [[ "$DISK_LAYOUT_REVIEWED" == "true" ]] || die "Set DISK_LAYOUT_REVIEWED=true in .env after reviewing OS disk mapping."
    require_non_placeholder_var GRUB_BOOTLOADER_ID
  fi
  if [[ "$PACKAGES" == true ]]; then
    require_non_placeholder_array PACMAN_PACKAGES
  fi
}

parse_args() {
  if [[ "$#" -eq 0 ]]; then
    usage
    exit 0
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --dry-run)
        APPLY=false
        ;;
      --apply)
        APPLY=true
        ;;
      --init-env)
        INIT_ENV=true
        ;;
      --list-disks)
        LIST_DISKS=true
        ;;
      --install-arch)
        INSTALL_ARCH=true
        ;;
      --partition-os-disk)
        PARTITION_OS_DISK=true
        ;;
      --packages)
        PACKAGES=true
        ;;
      --services)
        SERVICES=true
        ;;
      --enable-services)
        ENABLE_SERVICES=true
        ;;
      --start-services)
        START_SERVICES=true
        ;;
      --all)
        ALL=true
        ;;
      --check-live-target)
        CHECK_LIVE_TARGET=true
        ;;
      --check-health|--checkhealth)
        CHECK_HEALTH=true
        ;;
      --env-file)
        shift
        ENV_FILE="${1:-}"
        ;;
      --target-mode)
        shift
        CLI_TARGET_MODE="${1:-}"
        ;;
      --target-root)
        shift
        CLI_TARGET_ROOT="${1:-}"
        ;;
      --os-disk)
        shift
        OS_DISK="${1:-}"
        ;;
      --efi-partition)
        shift
        EFI_PARTITION="${1:-}"
        ;;
      --root-partition)
        shift
        ROOT_PARTITION="${1:-}"
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}
