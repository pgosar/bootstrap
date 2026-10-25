configure_users() {
  [[ "$SYSTEM" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true ]] || return 0
  require_root
  local groups joined_groups
  groups=("${USER_SUPPLEMENTAL_GROUPS[@]}")
  joined_groups="$(IFS=, ; printf '%s' "${groups[*]}")"

  if [[ "$APPLY" == true ]]; then
    local group sudoers_file
    for group in "${groups[@]}"; do
      target_run groupadd -f "$group"
    done
    target_run groupadd -f "$PC_USER"
    target_run useradd -m -s /bin/zsh -g "$PC_USER" -G "$joined_groups" "$PC_USER" 2>/dev/null || \
      target_run usermod -s /bin/zsh -G "$joined_groups" "$PC_USER"
    sudoers_file="$(target_path /etc/sudoers.d/10-wheel-nopasswd)"
    write_text "$sudoers_file" '%wheel ALL=(ALL:ALL) NOPASSWD: ALL'
    chmod 0440 "$sudoers_file"
  else
    log "+ create user $PC_USER with groups: $joined_groups"
  fi
}

configure_host_identity() {
  [[ "$SYSTEM" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true ]] || return 0
  local hosts_file grub_default mkinitcpio locale_gen locale_conf vconsole_conf resolv_conf
  hosts_file="$(target_path /etc/hosts)"
  grub_default="$(target_path /etc/default/grub)"
  mkinitcpio="$(target_path /etc/mkinitcpio.conf)"
  locale_gen="$(target_path /etc/locale.gen)"
  locale_conf="$(target_path /etc/locale.conf)"
  vconsole_conf="$(target_path /etc/vconsole.conf)"
  resolv_conf="$(target_path /etc/resolv.conf)"

  write_text "$(target_path /etc/hostname)" "$PC_HOSTNAME"
  write_text "$locale_conf" "LANG=$LOCALE"
  write_text "$vconsole_conf" "KEYMAP=$KEYMAP"

  if [[ "$APPLY" == true ]]; then
    if [[ -f "$locale_gen" ]]; then
      backup_file "$locale_gen"
      sed -i "s/^#\(${LOCALE//./\\.} UTF-8\)/\1/" "$locale_gen"
    fi
    cat >"$hosts_file" <<EOF
127.0.0.1 localhost
::1 localhost
127.0.1.1 $PC_HOSTNAME.localdomain $PC_HOSTNAME
EOF
    if [[ "$ENABLE_SYSTEMD_RESOLVED" == true ]]; then
      rm -f "$resolv_conf"
      ln -s /run/systemd/resolve/stub-resolv.conf "$resolv_conf"
    fi
  else
    log "+ write hostname and hosts for $PC_HOSTNAME"
  fi

  configure_grub_defaults "$grub_default"
  configure_mkinitcpio "$mkinitcpio"
}

configure_snapper_root() {
  [[ "$SYSTEM" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true ]] || return 0
  require_root
  local config_file confd_file
  config_file="$(target_path /etc/snapper/configs/root)"
  confd_file="$(target_path /etc/conf.d/snapper)"

  if [[ "$APPLY" == true ]]; then
    ensure_dir "$(dirname "$config_file")"
    ensure_dir "$(dirname "$confd_file")"
    backup_file "$config_file"
    backup_file "$confd_file"
    cat >"$config_file" <<'EOF'
SUBVOLUME="/"
FSTYPE="btrfs"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="15"
TIMELINE_CREATE="no"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
EOF
    write_text "$confd_file" 'SNAPPER_CONFIGS="root"'
    if [[ -d "$(target_path /.snapshots)" ]]; then
      log "Snapper snapshot mountpoint present"
    fi
  else
    log "+ write snapper root config"
  fi
}

configure_ufw_rules() {
  [[ "$SYSTEM" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true ]] || return 0
  [[ "$ENABLE_UFW" == "true" ]] || return 0
  require_root

  target_run ufw allow 22
  target_run ufw allow from "$KDECONNECT_LAN_CIDR" to any port 1714:1764 proto tcp comment "KDE Connect LAN"
  target_run ufw allow from "$KDECONNECT_LAN_CIDR" to any port 1714:1764 proto udp comment "KDE Connect LAN"
  target_run ufw allow from "$KDECONNECT_LAN_CIDR" to any port 47984,47989,47990,48010 proto tcp comment "Sunshine LAN"
  target_run ufw allow from "$KDECONNECT_LAN_CIDR" to any port 47998,47999,48000,48002,48010 proto udp comment "Sunshine LAN"
  target_run ufw allow from "$TAILSCALE_CIDR" to any port 47984,47989,47990,48010 proto tcp comment "Sunshine Tailscale"
  target_run ufw allow from "$TAILSCALE_CIDR" to any port 47998,47999,48000,48002,48010 proto udp comment "Sunshine Tailscale"
  # ufw --force enable cannot run inside the install chroot; the
  # ENABLED flag plus the enabled ufw.service load the rules at boot.
  run sed -i 's/^ENABLED=.*/ENABLED=yes/' "$(target_path /etc/ufw/ufw.conf)"
}

setup_fnm() {
  [[ "$PACKAGES" == true ]] || return 0
  require_root

  if [[ "$APPLY" != true ]]; then
    log "+ install LTS Node via fnm for $PC_USER and set as default"
    return 0
  fi

  # Install latest LTS Node and set as fnm default so the dotfiles
  # zshrc (eval "$(fnm env --use-on-cd)") provides node/npm.
  target_run runuser -u "$PC_USER" -- bash -lc "fnm install --lts && fnm default lts-latest"
}

configure_pc_system_files() {
  [[ "$SYSTEM" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true ]] || return 0
  require_root
  if [[ "$APPLY" == true ]]; then
    run install -Dm 0644 "$PC_ROOT/config/system/nvidia-suspend-workaround.conf" "$(target_path /etc/modprobe.d/nvidia-suspend-workaround.conf)"
    run install -Dm 0644 "$PC_ROOT/config/system/92-keychron-via.rules" "$(target_path /etc/udev/rules.d/92-keychron-via.rules)"
    run install -Dm 0755 "$PC_ROOT/config/system/remove-nvidia" "$(target_path /usr/local/bin/remove-nvidia)"
    run install -Dm 0644 "$PC_ROOT/config/system/daemon.json" "$(target_path /etc/docker/daemon.json)"
    run install -Dm 0644 "$PC_ROOT/config/system/lact-config.yaml" "$(target_path /etc/lact/config.yaml)"
    run install -Dm 0644 "$PC_ROOT/config/system/plasmalogin.conf" "$(target_path /etc/plasmalogin.conf)"
    run install -Dm 0644 "$PC_ROOT/config/keyd/8bitdo-retro-keyboard.conf" "$(target_path /etc/keyd/8bitdo-retro-keyboard.conf)"
    run install -Dm 0644 "$PC_ROOT/config/keyd/by-tech-gaming-keyboard.conf" "$(target_path /etc/keyd/by-tech-gaming-keyboard.conf)"
    run install -Dm 0644 "$PC_ROOT/config/sysctl/99-bbr.conf" "$(target_path /etc/sysctl.d/99-bbr.conf)"
    run install -Dm 0644 "$PC_ROOT/config/sysctl/40-ipv6.conf" "$(target_path /etc/sysctl.d/40-ipv6.conf)"
    run install -Dm 0644 "$PC_ROOT/config/system/10-suspend-mode.conf" "$(target_path /etc/systemd/sleep.conf.d/10-suspend-mode.conf)"
    run install -Dm 0644 "$PC_ROOT/config/system/10-chwd.conf" "$(target_path /etc/mkinitcpio.conf.d/10-chwd.conf)"
    run install -Dm 0644 "$PC_ROOT/config/system/10-chwd-kms.conf" "$(target_path /etc/mkinitcpio.conf.d/10-chwd-kms.conf)"
    run install -Dm 0644 "$PC_ROOT/config/system/90-8bitdo-retro-keyboard-modifiers.hwdb" "$(target_path /etc/udev/hwdb.d/90-8bitdo-retro-keyboard-modifiers.hwdb)"
    target_run systemd-hwdb update
    run install -Dm 0644 "$PC_ROOT/config/system/logrotate.service" "$(target_path /etc/systemd/system/logrotate.service)"
    run install -Dm 0644 "$PC_ROOT/config/system/logrotate.timer" "$(target_path /etc/systemd/system/logrotate.timer)"
    run ln -sf /opt/mcpelauncher-bin/bin/mcpelauncher-client "$(target_path /usr/local/bin/mcpelauncher-client)"
    run ln -sf /opt/mcpelauncher-bin/bin/mcpelauncher-ui-qt "$(target_path /usr/local/bin/mcpelauncher-ui-qt)"
  else
    log "+ install PC system files (nvidia workaround, keychron rule, remove-nvidia, docker/lact/plasmalogin configs, keyd, sysctl, sleep mode, mkinitcpio drop-ins, hwdb, logrotate, mcpelauncher links)"
  fi
}

configure_network_profile() {
  [[ "$SYSTEM" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true ]] || return 0
  require_root
  if [[ "$APPLY" == true ]]; then
    run install -Dm 0600 "$PC_ROOT/config/network/Wired connection 1.nmconnection" "$(target_path "/etc/NetworkManager/system-connections/Wired connection 1.nmconnection")"
    if [[ ! -f "$(target_path "/etc/NetworkManager/system-connections/ATTcFikS2f-5g.nmconnection")" ]]; then
      run install -Dm 0600 "$PC_ROOT/config/network/ATTcFikS2f-5g.nmconnection" "$(target_path "/etc/NetworkManager/system-connections/ATTcFikS2f-5g.nmconnection")"
      warn "WiFi profile installed with a placeholder psk: set the real psk in ATTcFikS2f-5g.nmconnection"
    fi
  else
    log "+ install NetworkManager wired profile (static $PC_STATIC_ADDRESS via $PC_GATEWAY)"
  fi
}

configure_nas_mounts() {
  [[ "$SYSTEM" == true || "$SERVICES" == true || "$ENABLE_SERVICES" == true ]] || return 0
  require_root
  local fstab
  fstab="$(target_path /etc/fstab)"
  if [[ "$APPLY" != true ]]; then
    log "+ add NAS CIFS mounts (//$NAS_SERVER_IP shares) to $fstab and install /etc/.nascreds"
    return 0
  fi
  [[ -f "$fstab" ]] || die "fstab not found: $fstab"
  if ! grep -q '# pc-bootstrap: nas mounts' "$fstab"; then
    backup_file "$fstab"
    {
      printf '# pc-bootstrap: nas mounts\n'
      local share
      for share in "${NAS_SHARES[@]}"; do
        printf '//%s/%s /home/%s/Server/%s cifs credentials=/etc/.nascreds,uid=1000,gid=1000,dir_mode=0775,file_mode=0664,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60 0 0\n' "$NAS_SERVER_IP" "$share" "$PC_USER" "$share"
      done
    } >>"$fstab"
  fi
  local share
  for share in "${NAS_SHARES[@]}"; do
    target_run install -d -m 0755 -o "$PC_USER" -g "$PC_USER" "/home/$PC_USER/Server/$share"
  done
  if [[ -n "${NAS_CREDS_SOURCE:-}" && -f "$NAS_CREDS_SOURCE" ]]; then
    run install -Dm 0600 "$NAS_CREDS_SOURCE" "$(target_path /etc/.nascreds)"
  elif [[ ! -f "$(target_path /etc/.nascreds)" ]]; then
    warn "NAS_CREDS_SOURCE unset: writing placeholder /etc/.nascreds - fill in username=/password= before the mounts can authenticate"
    write_text "$(target_path /etc/.nascreds)" "username=REPLACE_ME
password=REPLACE_ME"
    run chmod 0600 "$(target_path /etc/.nascreds)"
  fi
}
