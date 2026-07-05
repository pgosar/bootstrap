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
