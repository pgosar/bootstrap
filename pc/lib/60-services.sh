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
    run install -Dm 0755 "$PC_ROOT/config/clipboard/pc-clipboard-pull" "$(target_path /usr/local/bin/pc-clipboard-pull)"
    run install -Dm 0755 "$PC_ROOT/config/clipboard/pc-clipboard-publish" "$(target_path /usr/local/bin/pc-clipboard-publish)"
    run install -Dm 0755 "$PC_ROOT/config/clipboard/pc-clipboard-watch" "$(target_path /usr/local/bin/pc-clipboard-watch)"
    run install -Dm 0644 "$PC_ROOT/config/clipboard/nas-clipboard-pull.service" "$(target_path /etc/systemd/user/nas-clipboard-pull.service)"
    run install -Dm 0644 "$PC_ROOT/config/clipboard/nas-clipboard-publish.service" "$(target_path /etc/systemd/user/nas-clipboard-publish.service)"
    run install -Dm 0755 "$PC_ROOT/../common/workstation-state/workstation-state-recorder" "$(target_path /usr/local/bin/workstation-state-recorder)"
    run install -Dm 0755 "$PC_ROOT/../common/workstation-state/workstation-state-prune" "$(target_path /usr/local/bin/workstation-state-prune)"
    run install -Dm 0644 "$PC_ROOT/config/workstation-state/workstation-state-recorder.service" "$(target_path /etc/systemd/system/workstation-state-recorder.service)"
    run sed -i -e "s/__STATE_USER__/$PC_USER/g" "$(target_path /etc/systemd/system/workstation-state-recorder.service)"
    run install -Dm 0644 "$PC_ROOT/config/workstation-state/workstation-state-recorder.timer" "$(target_path /etc/systemd/system/workstation-state-recorder.timer)"
    target_run install -d -m 0750 -o "$PC_USER" -g "$PC_USER" /var/lib/workstation-state /var/lib/workstation-state/pc
    target_run runuser -u "$PC_USER" -- systemctl --user daemon-reload
    target_run runuser -u "$PC_USER" -- systemctl --user enable nas-clipboard-pull.service nas-clipboard-publish.service
  fi
}

configure_pc_service_files() {
  [[ "$SERVICES" == true || "$ENABLE_SERVICES" == true ]] || return 0
  require_root
  if [[ "$APPLY" != true ]]; then
    log "+ install PC service files (wol, ssh-inhibit, ram-rgb)"
    return 0
  fi
  # Wake-on-LAN support (folded in from bin/install-wol-support.sh)
  run install -Dm 0755 "$PC_ROOT/config/wol/pc-arm-wol" "$(target_path /usr/local/sbin/pc-arm-wol)"
  run install -Dm 0644 "$PC_ROOT/config/wol/pc-wol.service" "$(target_path /etc/systemd/system/pc-wol.service)"
  if [[ ! -f "$(target_path /etc/default/pc-wol)" ]]; then
    write_text "$(target_path /etc/default/pc-wol)" "WOL_INTERFACE=$PC_WOL_INTERFACE"
  fi
  target_run install -d -o "$PC_USER" -g "$PC_USER" "/home/$PC_USER/.local/bin" "/home/$PC_USER/.config/systemd/user"
  run install -Dm 0755 "$PC_ROOT/config/wol/pc-blank-displays" "$(target_path /home/$PC_USER/.local/bin/pc-blank-displays)"
  run install -Dm 0644 "$PC_ROOT/config/wol/pc-blank-displays.service" "$(target_path /home/$PC_USER/.config/systemd/user/pc-blank-displays.service)"
  target_run chown "$PC_USER:$PC_USER" "/home/$PC_USER/.local/bin/pc-blank-displays" "/home/$PC_USER/.config/systemd/user/pc-blank-displays.service"
  # ssh-inhibit: keep the machine awake while SSH sessions are active
  run install -Dm 0755 "$PC_ROOT/config/ssh-inhibit/ssh-inhibit.sh" "$(target_path /usr/local/bin/ssh-inhibit.sh)"
  run install -Dm 0644 "$PC_ROOT/config/ssh-inhibit/ssh-inhibit.service" "$(target_path /etc/systemd/system/ssh-inhibit.service)"
  # RAM RGB clock schedule
  run install -Dm 0755 "$PC_ROOT/config/ram-rgb/ram-rgb.sh" "$(target_path /usr/local/bin/ram-rgb.sh)"
  local unit
  for unit in ram-rgb-on.service ram-rgb-off.service ram-rgb-on.timer ram-rgb-off.timer; do
    run install -Dm 0644 "$PC_ROOT/config/ram-rgb/$unit" "$(target_path /etc/systemd/system/$unit)"
  done
  run install -Dm 0755 "$PC_ROOT/config/ram-rgb/ram-rgb.sleep" "$(target_path /usr/lib/systemd/system-sleep/ram-rgb)"
}

configure_docker_workers() {
  [[ "$ENABLE_PC_WORKERS" == "true" ]] || return 0
  [[ "$SERVICES" == true || "$ENABLE_SERVICES" == true ]] || return 0
  require_root
  if [[ "$APPLY" != true ]]; then
    log "+ install Docker workers stack under /home/$PC_USER/docker"
    return 0
  fi
  local home="/home/$PC_USER"
  target_run install -d -o "$PC_USER" -g "$PC_USER" "$home/docker" "$home/docker/pc-workers" \
    "$home/docker/appdata/tdarr-node/configs" "$home/docker/appdata/tdarr-node/logs" \
    "$home/docker/appdata/tdarr-node/transcode-cache" "$home/docker/appdata/immich-machine-learning/model-cache"
  run install -Dm 0644 "$PC_ROOT/config/docker-workers/pc-workers-compose.yml" "$(target_path "$home/docker/pc-workers-compose.yml")"
  run install -Dm 0644 "$PC_ROOT/config/docker-workers/compose.yml" "$(target_path "$home/docker/pc-workers/compose.yml")"
  if [[ ! -f "$(target_path "$home/docker/pc-workers.env")" ]]; then
    run install -Dm 0600 "$PC_ROOT/config/docker-workers/env.top.example" "$(target_path "$home/docker/pc-workers.env")"
    warn "wrote placeholder $home/docker/pc-workers.env: set TDARR_API_KEY before the workers can pair"
  fi
  if [[ ! -f "$(target_path "$home/docker/pc-workers/.env")" ]]; then
    run install -Dm 0600 "$PC_ROOT/config/docker-workers/env.inner.example" "$(target_path "$home/docker/pc-workers/.env")"
    warn "wrote placeholder $home/docker/pc-workers/.env: set TDARR_API_KEY before the workers can pair"
  fi
  target_run chown "$PC_USER:$PC_USER" "$home/docker/pc-workers-compose.yml" "$home/docker/pc-workers/compose.yml" "$home/docker/pc-workers.env" "$home/docker/pc-workers/.env"
  run install -Dm 0644 "$PC_ROOT/config/docker-workers/pc-workers-up.service" "$(target_path /etc/systemd/system/pc-workers-up.service)"
  run sed -i -e "s/__PC_USER__/$PC_USER/g" "$(target_path /etc/systemd/system/pc-workers-up.service)"
}

setup_dotfiles() {
  [[ "$SETUP_DOTFILES" == "true" ]] || return 0
  [[ "$SERVICES" == true || "$ENABLE_SERVICES" == true ]] || return 0
  require_root
  if [[ "$APPLY" != true ]]; then
    log "+ clone/update dotfiles into /home/$PC_USER/code/dotfiles and run its install.sh as $PC_USER"
    return 0
  fi
  target_run install -d -o "$PC_USER" -g "$PC_USER" "/home/$PC_USER/code"
  if check_run_target test -d "/home/$PC_USER/code/dotfiles/.git"; then
    target_run runuser -u "$PC_USER" -- git -C "/home/$PC_USER/code/dotfiles" pull --ff-only
  else
    target_run runuser -u "$PC_USER" -- git clone "https://github.com/pgosar/dotfiles.git" "/home/$PC_USER/code/dotfiles"
  fi
  target_run runuser -u "$PC_USER" -- bash "/home/$PC_USER/code/dotfiles/install.sh"
}
