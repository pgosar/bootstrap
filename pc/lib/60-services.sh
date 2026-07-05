configure_services() {
  [[ "$SERVICES" == true || "$ENABLE_SERVICES" == true || "$START_SERVICES" == true ]] || return 0
  require_root
  if [[ "$APPLY" != true ]]; then
    log "+ configure host service files under $(printf '%q' "$(target_path /etc/systemd/system)")"
  fi
}

configure_service_files() {
  [[ "$SERVICES" == true || "$ENABLE_SERVICES" == true ]] || return 0
  require_root
  if [[ "$APPLY" == true ]]; then
    ensure_dir "$(target_path /var/log)"
  fi
}
