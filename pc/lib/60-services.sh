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
  target_run install -Dm 0755 "$PC_ROOT/config/wol/pc-arm-wol" /usr/local/sbin/pc-arm-wol
  target_run install -Dm 0644 "$PC_ROOT/config/wol/pc-wol.service" /etc/systemd/system/pc-wol.service
  if [[ ! -f "$(target_path /etc/default/pc-wol)" ]]; then
    write_text "$(target_path /etc/default/pc-wol)" "WOL_INTERFACE=$PC_WOL_INTERFACE"
  fi
  target_run install -d -o "$PC_USER" -g "$PC_USER" "/home/$PC_USER/.local/bin" "/home/$PC_USER/.config/systemd/user"
  target_run install -Dm 0755 "$PC_ROOT/config/wol/pc-blank-displays" "/home/$PC_USER/.local/bin/pc-blank-displays"
  target_run install -Dm 0644 "$PC_ROOT/config/wol/pc-blank-displays.service" "/home/$PC_USER/.config/systemd/user/pc-blank-displays.service"
  target_run chown "$PC_USER:$PC_USER" "/home/$PC_USER/.local/bin/pc-blank-displays" "/home/$PC_USER/.config/systemd/user/pc-blank-displays.service"
  # ssh-inhibit: keep the machine awake while SSH sessions are active
  target_run install -Dm 0755 "$PC_ROOT/config/ssh-inhibit/ssh-inhibit.sh" /usr/local/bin/ssh-inhibit.sh
  target_run install -Dm 0644 "$PC_ROOT/config/ssh-inhibit/ssh-inhibit.service" /etc/systemd/system/ssh-inhibit.service
  # RAM RGB clock schedule
  target_run install -Dm 0755 "$PC_ROOT/config/ram-rgb/ram-rgb.sh" /usr/local/bin/ram-rgb.sh
  local unit
  for unit in ram-rgb-on.service ram-rgb-off.service ram-rgb-on.timer ram-rgb-off.timer; do
    target_run install -Dm 0644 "$PC_ROOT/config/ram-rgb/$unit" "/etc/systemd/system/$unit"
  done
  target_run install -Dm 0755 "$PC_ROOT/config/ram-rgb/ram-rgb.sleep" /usr/lib/systemd/system-sleep/ram-rgb
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
