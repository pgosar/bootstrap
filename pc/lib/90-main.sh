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
  load_package_lists
  resolve_check_target_mode
  resolve_phase_selection
  validate_check_mode_selection
  validate_config

  if [[ "$CHECK_LIVE_TARGET" == true ]]; then
    print_config_summary
    check_live_target
    return $?
  fi

  if [[ "$CHECK_HEALTH" == true ]]; then
    print_config_summary
    check_health
    return $?
  fi

  print_config_summary

  if [[ "$INSTALL_ARCH" == true ]]; then
    install_arch_system
    write_next_steps_file "$TARGET_ROOT"
    printf '\nIMPORTANT NEXT STEP: SET PASSWORDS BEFORE REBOOTING\n'
    printf 'arch-chroot %s passwd\n' "$TARGET_ROOT"
    printf 'arch-chroot %s passwd %s\n' "$TARGET_ROOT" "$PC_USER"
  fi

  install_packages
  configure_host_identity
  configure_users
  install_aur_packages
  configure_snapper_root
  if [[ "$INSTALL_ARCH" == true ]]; then
    finalize_installed_system "$TARGET_ROOT"
  fi
  configure_services
  configure_service_files

  if [[ "$ENABLE_SERVICES" == true ]]; then
    enable_services
  fi

  if [[ "$START_SERVICES" == true ]]; then
    start_services
  fi
}

enable_services() {
  require_root
  if [[ "$APPLY" == true ]]; then
    [[ "$ENABLE_SYSTEMD_RESOLVED" == "true" ]] && enable_target_unit systemd-resolved
    [[ "$ENABLE_SYSTEMD_TIMESYNCD" == "true" ]] && enable_target_unit systemd-timesyncd
    [[ "$ENABLE_NETWORKMANAGER" == "true" ]] && enable_target_unit NetworkManager
    [[ "$ENABLE_BLUETOOTH" == "true" ]] && enable_target_unit bluetooth
    [[ "$ENABLE_LIBVIRTD" == "true" ]] && enable_target_unit libvirtd
    [[ "$ENABLE_LY" == "true" ]] && enable_target_unit "$LY_UNIT"
    [[ "$ENABLE_UFW" == "true" ]] && enable_target_unit ufw
    [[ "$ENABLE_AVAHI" == "true" ]] && enable_target_unit avahi-daemon
    enable_target_unit sshd
    [[ "$ENABLE_FSTRIM_TIMER" == "true" ]] && enable_target_unit fstrim.timer
    enable_target_unit snapper-cleanup.timer
    enable_target_unit snapper-timeline.timer false
    [[ "$ENABLE_SMARTD" == "true" ]] && enable_target_unit smartd
    [[ "$ENABLE_NFTABLES" == "true" ]] && enable_target_unit nftables
  else
    log "+ enable host services"
  fi
  return 0
}

start_services() {
  require_root
  if [[ "$TARGET_MODE" == "live" ]]; then
    warn "TARGET_MODE=live: not starting services inside chroot"
    return 0
  fi
  if [[ "$APPLY" == true ]]; then
    [[ "$ENABLE_SYSTEMD_RESOLVED" == "true" ]] && start_target_unit systemd-resolved
    [[ "$ENABLE_SYSTEMD_TIMESYNCD" == "true" ]] && start_target_unit systemd-timesyncd
    [[ "$ENABLE_NETWORKMANAGER" == "true" ]] && start_target_unit NetworkManager
    [[ "$ENABLE_BLUETOOTH" == "true" ]] && start_target_unit bluetooth
    [[ "$ENABLE_LIBVIRTD" == "true" ]] && start_target_unit libvirtd
    [[ "$ENABLE_LY" == "true" ]] && start_target_unit "$LY_UNIT"
    [[ "$ENABLE_UFW" == "true" ]] && start_target_unit ufw
    [[ "$ENABLE_AVAHI" == "true" ]] && start_target_unit avahi-daemon
    start_target_unit sshd
  else
    log "+ start host services"
  fi
  return 0
}
