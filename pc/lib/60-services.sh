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
    target_run install -Dm 0755 "$PC_ROOT/config/clipboard/pc-clipboard-pull" /usr/local/bin/pc-clipboard-pull
    target_run install -Dm 0755 "$PC_ROOT/config/clipboard/pc-clipboard-publish" /usr/local/bin/pc-clipboard-publish
    target_run install -Dm 0755 "$PC_ROOT/config/clipboard/pc-clipboard-watch" /usr/local/bin/pc-clipboard-watch
    target_run install -Dm 0644 "$PC_ROOT/config/clipboard/nas-clipboard-pull.service" /etc/systemd/user/nas-clipboard-pull.service
    target_run install -Dm 0644 "$PC_ROOT/config/clipboard/nas-clipboard-publish.service" /etc/systemd/user/nas-clipboard-publish.service
    target_run runuser -u "$PC_USER" -- systemctl --user daemon-reload
    target_run runuser -u "$PC_USER" -- systemctl --user enable nas-clipboard-pull.service nas-clipboard-publish.service
  fi
}
