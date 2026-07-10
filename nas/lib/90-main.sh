parse_args() {
  if [[ "$#" -eq 0 ]]; then
    usage
    exit 0
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
    --dry-run)
      APPLY=false
      ;;
    --apply)
      APPLY=true
      ;;
    --partition-os-disk)
      PARTITION_OS_DISK=true
      ;;
    --start-services)
      START_SERVICES=true
      CLI_START_SERVICES=true
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
    --packages)
      PACKAGES=true
      ;;
    --storage)
      STORAGE=true
      ;;
    --services)
      SERVICES=true
      ;;
    --enable-services)
      ENABLE_SERVICES=true
      ;;
    --check-live-target)
      CHECK_LIVE_TARGET=true
      ;;
    --check-health | --checkhealth)
      CHECK_HEALTH=true
      ;;
    --all)
      ALL=true
      ;;
    --env-file)
      shift
      [[ "$#" -gt 0 ]] || die "--env-file requires a value"
      ENV_FILE="$1"
      ;;
    --os-disk)
      shift
      [[ "$#" -gt 0 ]] || die "--os-disk requires a value"
      OS_DISK="$1"
      ;;
    --efi-partition)
      shift
      [[ "$#" -gt 0 ]] || die "--efi-partition requires a value"
      EFI_PARTITION="$1"
      ;;
    --root-partition)
      shift
      [[ "$#" -gt 0 ]] || die "--root-partition requires a value"
      ROOT_PARTITION="$1"
      ;;
    --target-root)
      shift
      [[ "$#" -gt 0 ]] || die "--target-root requires a value"
      TARGET_ROOT="$1"
      CLI_TARGET_ROOT="$1"
      ;;
    --target-mode)
      shift
      [[ "$#" -gt 0 ]] || die "--target-mode requires a value"
      [[ "$1" == "host" || "$1" == "live" ]] || die "--target-mode must be host or live"
      TARGET_MODE="$1"
      CLI_TARGET_MODE="$1"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  if [[ "$INIT_ENV" == true ]]; then
    init_env
    return 0
  fi
  if [[ "$LIST_DISKS" == true ]]; then
    list_disks
    return 0
  fi
  load_config
  resolve_check_target_mode
  resolve_phase_selection
  validate_check_mode_selection
  validate_config
  preflight
  print_config_summary
  print_summary
  if [[ "$CHECK_LIVE_TARGET" == true ]]; then
    check_live_target
    return 0
  fi
  if [[ "$CHECK_HEALTH" == true ]]; then
    check_health
    return 0
  fi
  if [[ "$INSTALL_ARCH" == true ]]; then
    install_arch_system
    configure_pacman_ignore_packages
  fi
  if [[ "$PACKAGES" == true ]]; then
    install_packages
    configure_users
    install_aur_packages
  fi
  [[ "$STORAGE" == true ]] && configure_storage
  [[ "$SERVICES" == true ]] && configure_services
  [[ "$ENABLE_SERVICES" == true ]] && enable_services
  write_post_install_next_steps
  print_post_install_password_reminder
  return 0
}
