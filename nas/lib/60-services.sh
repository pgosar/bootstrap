configure_operations_basics() {
  log "Phase: journald limits, shell reminders, and backup placeholders"
  ensure_dir "$(target_path /etc/systemd/journald.conf.d)"
  ensure_dir "$(target_path /etc/profile.d)"
  ensure_dir "$(target_path /etc/NetworkManager/system-connections)"
  ensure_dir "$(target_path /etc/sysctl.d)"
  ensure_dir "$(target_path /etc/zsh)"
  ensure_dir "$(target_path /usr/local/sbin)"
  ensure_dir "$(target_path /var/lib/nas-secrets/locked)"
  run chown root:root "$(target_path /var/lib/nas-secrets/locked)"
  run chmod 0555 "$(target_path /var/lib/nas-secrets/locked)"
  copy_with_backup "$NAS_ROOT/config/profile.d/nas-kernel-reminder.sh" "$(target_path /etc/profile.d/nas-kernel-reminder.sh)"
  copy_with_backup "$NAS_ROOT/config/nas-kernel-maintenance-reminder" "$(target_path /usr/local/sbin/nas-kernel-maintenance-reminder)"
  run chmod 0755 "$(target_path /usr/local/sbin/nas-kernel-maintenance-reminder)"
  copy_with_backup "$NAS_ROOT/config/systemd/nas-kernel-maintenance-reminder.service" "$(target_path /etc/systemd/system/nas-kernel-maintenance-reminder.service)"
  copy_with_backup "$NAS_ROOT/config/systemd/nas-kernel-maintenance-reminder.timer" "$(target_path /etc/systemd/system/nas-kernel-maintenance-reminder.timer)"
  copy_with_backup "$NAS_ROOT/config/zsh/zshrc" "$(target_path /etc/zsh/zshrc)"
  copy_with_backup "$NAS_ROOT/config/sysctl/99-ipv4-only.conf" "$(target_path /etc/sysctl.d/99-ipv4-only.conf)"
  copy_with_backup "$NAS_ROOT/config/network/nas-ipv4-ethernet.nmconnection" "$(target_path /etc/NetworkManager/system-connections/nas-ipv4-ethernet.nmconnection)"
  run chmod 0600 "$(target_path /etc/NetworkManager/system-connections/nas-ipv4-ethernet.nmconnection)"
  if [[ "$APPLY" == true && "$TARGET_MODE" == "host" ]]; then
    target_run sysctl --system
    target_run nmcli connection reload
  fi
  backup_file "$(target_path /etc/systemd/journald.conf.d/90-nas-bootstrap.conf)"
  write_text "$(target_path /etc/systemd/journald.conf.d/90-nas-bootstrap.conf)" \
    "[Journal]"$'\n'"SystemMaxUse=$JOURNALD_SYSTEM_MAX_USE"$'\n'"RuntimeMaxUse=$JOURNALD_RUNTIME_MAX_USE"$'\n'"MaxRetentionSec=$JOURNALD_MAX_RETENTION_SEC"$'\n'
  copy_with_backup "$NAS_ROOT/config/nas-notify" "$(target_path /usr/local/sbin/nas-notify)"
  run chmod 0755 "$(target_path /usr/local/sbin/nas-notify)"
  copy_with_backup "$NAS_ROOT/config/nas-weekly-digest" "$(target_path /usr/local/sbin/nas-weekly-digest)"
  run chmod 0755 "$(target_path /usr/local/sbin/nas-weekly-digest)"
  copy_with_backup "$NAS_ROOT/config/systemd/nas-weekly-digest.service" "$(target_path /etc/systemd/system/nas-weekly-digest.service)"
  copy_with_backup "$NAS_ROOT/config/systemd/nas-weekly-digest.timer" "$(target_path /etc/systemd/system/nas-weekly-digest.timer)"
  copy_with_backup "$NAS_ROOT/config/nas-recent-files" "$(target_path /usr/local/sbin/nas-recent-files)"
  run chmod 0755 "$(target_path /usr/local/sbin/nas-recent-files)"
  copy_with_backup "$NAS_ROOT/config/nas-duplicate-report" "$(target_path /usr/local/sbin/nas-duplicate-report)"
  run chmod 0755 "$(target_path /usr/local/sbin/nas-duplicate-report)"
  copy_with_backup "$NAS_ROOT/config/nas-uptime-ledger" "$(target_path /usr/local/sbin/nas-uptime-ledger)"
  run chmod 0755 "$(target_path /usr/local/sbin/nas-uptime-ledger)"
  copy_with_backup "$NAS_ROOT/config/nas-nextcloud-external-scan" "$(target_path /usr/local/sbin/nas-nextcloud-external-scan)"
  run chmod 0755 "$(target_path /usr/local/sbin/nas-nextcloud-external-scan)"
  for unit in nas-recent-files.service nas-recent-files.timer nas-duplicate-report.service nas-duplicate-report.timer nas-uptime-ledger.service nas-uptime-ledger.timer nas-nextcloud-external-scan.service nas-nextcloud-external-scan.timer; do
    copy_with_backup "$NAS_ROOT/config/systemd/$unit" "$(target_path "/etc/systemd/system/$unit")"
  done
  copy_with_backup "$NAS_ROOT/config/nas-secrets" "$(target_path /usr/local/bin/nas-secrets)"
  run chmod 0755 "$(target_path /usr/local/bin/nas-secrets)"
  copy_with_backup "$NAS_ROOT/config/nas-notify.env.example" "$(target_path /etc/nas-notify.env.example)"
  run chmod 0600 "$(target_path /etc/nas-notify.env.example)"
  copy_with_backup "$NAS_ROOT/config/nas-url-queue-notify" "$(target_path /usr/local/sbin/nas-url-queue-notify)"
  run chmod 0755 "$(target_path /usr/local/sbin/nas-url-queue-notify)"
  copy_with_backup "$NAS_ROOT/config/nas-url-queue-tailscale" "$(target_path /usr/local/sbin/nas-url-queue-tailscale)"
  run chmod 0755 "$(target_path /usr/local/sbin/nas-url-queue-tailscale)"
  copy_with_backup "$NAS_ROOT/config/nas-clipboard-tailscale" "$(target_path /usr/local/sbin/nas-clipboard-tailscale)"
  run chmod 0755 "$(target_path /usr/local/sbin/nas-clipboard-tailscale)"
  copy_with_backup "$NAS_ROOT/config/systemd/nas-url-queue-notify.service" "$(target_path /etc/systemd/system/nas-url-queue-notify.service)"
  copy_with_backup "$NAS_ROOT/config/systemd/nas-url-queue-notify.path" "$(target_path /etc/systemd/system/nas-url-queue-notify.path)"
  copy_with_backup "$NAS_ROOT/config/btrfs-scrub.sh" "$(target_path /usr/local/bin/nas-btrfs-scrub)"
  run chmod 0755 "$(target_path /usr/local/bin/nas-btrfs-scrub)"
  copy_with_backup "$NAS_ROOT/config/systemd/nas-btrfs-scrub@.service" "$(target_path /etc/systemd/system/nas-btrfs-scrub@.service)"
  for unit in nas-btrfs-scrub-disk1.timer nas-btrfs-scrub-disk2.timer nas-btrfs-scrub-disk3.timer; do
    copy_with_backup "$NAS_ROOT/config/systemd/$unit" "$(target_path "/etc/systemd/system/$unit")"
  done
}

configure_swap() {
  log "Phase: OS swapfile"
  if [[ "$SWAP_ENABLE" != "true" ]]; then
    warn "SWAP_ENABLE is false; skipping swapfile setup."
    return 0
  fi
  [[ "$SWAP_MOUNT" == /* ]] || die "SWAP_MOUNT must be an absolute path"
  [[ "$SWAP_FILE" == /* ]] || die "SWAP_FILE must be an absolute path"
  [[ "$(dirname -- "$SWAP_FILE")" == "$SWAP_MOUNT" ]] || die "SWAP_FILE must live directly under SWAP_MOUNT"
  [[ "$SWAP_SIZE" =~ ^[0-9]+[KkMmGgTt]?$ ]] || die "SWAP_SIZE must look like 12g"

  local swap_path fstab line
  swap_path="$(target_path "$SWAP_FILE")"
  fstab="$(target_path /etc/fstab)"
  line="$SWAP_FILE none swap defaults 0 0"

  if [[ "$APPLY" == true ]]; then
    ensure_dir "$(target_path "$SWAP_MOUNT")"
    if ! findmnt -rn --mountpoint "$(target_path "$SWAP_MOUNT")" >/dev/null 2>&1; then
      die "$SWAP_MOUNT must be mounted from the dedicated @swap subvolume before creating swap"
    fi
    if [[ ! -e "$swap_path" ]]; then
      target_run btrfs filesystem mkswapfile --size "$SWAP_SIZE" "$SWAP_FILE"
    fi
    run chmod 0600 "$swap_path"
    if [[ "$TARGET_MODE" == "host" ]] && ! swapon --show=NAME --noheadings | grep -Fxq "$SWAP_FILE"; then
      target_run swapon "$SWAP_FILE"
    fi
  else
    log "+ btrfs filesystem mkswapfile --size $(printf '%q' "$SWAP_SIZE") $(printf '%q' "$SWAP_FILE")"
    log "+ swapon $(printf '%q' "$SWAP_FILE")"
  fi

  backup_file "$fstab"
  if [[ "$APPLY" == true ]] && grep -Fxq "$line" "$fstab"; then
    log "+ fstab already contains $SWAP_FILE swap entry"
  elif [[ "$APPLY" == true ]]; then
    printf '\n# NAS bootstrap swapfile on NVMe root filesystem\n%s\n' "$line" >>"$fstab"
  else
    log "+ append swap entry to $fstab: $line"
  fi
}

configure_firewall() {
  log "Phase: nftables firewall"
  if [[ "$FIREWALL_ENABLE" != "true" ]]; then
    warn "FIREWALL_ENABLE is false; skipping nftables policy generation."
    return 0
  fi

  local cidr cidr_csv="" has_cidr=false
  read -r -a firewall_cidrs <<<"${FIREWALL_LAN_CIDRS:-}"
  for cidr in "${firewall_cidrs[@]}"; do
    [[ -n "$cidr" ]] || continue
    has_cidr=true
    cidr_csv+="${cidr_csv:+, }$cidr"
  done
  [[ "$has_cidr" == true ]] || die "FIREWALL_LAN_CIDRS is empty"

  backup_file "$(target_path /etc/nftables.conf)"
  write_text "$(target_path /etc/nftables.conf)" "$(
    cat <<EOF
# Generated by NAS bootstrap
flush ruleset

table inet filter {
  set lan_cidrs {
    type ipv4_addr
    flags interval
    elements = { $cidr_csv }
  }

  chain input {
    type filter hook input priority 0; policy drop;
    iif "lo" accept
    ct state established,related accept
    ct state invalid drop
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    tcp dport 22 ip saddr @lan_cidrs accept
    tcp dport 3004 ip saddr 172.16.0.0/12 accept
    tcp dport { 139, 445 } ip saddr @lan_cidrs accept
    udp dport { 137, 138 } ip saddr @lan_cidrs accept
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    ip saddr @lan_cidrs ip daddr 172.16.0.0/12 accept
    ip saddr 172.16.0.0/12 accept
    ip saddr 172.16.0.0/12 ip daddr @lan_cidrs accept
    ip saddr 172.16.0.0/12 ip daddr 172.16.0.0/12 accept
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF
  )"

  if [[ "$APPLY" == true ]] && target_command_available nft; then
    target_run nft -c -f /etc/nftables.conf
  fi
}

configure_smartd() {
  log "Phase: smartmontools and smartd"
  if [[ "$SMART_ENABLE" != "true" ]]; then
    warn "SMART_ENABLE is false; skipping smartd configuration."
    return 0
  fi
  ensure_dir "$(target_path /etc)"
  copy_with_backup "$NAS_ROOT/config/smartd.conf" "$(target_path /etc/smartd.conf)"
}

configure_snapraid() {
  log "Phase: SnapRAID config and timers"
  if ! target_command_available snapraid; then
    warn "snapraid command not found; install it before enabling timers."
  fi
  copy_with_backup "$NAS_ROOT/config/snapraid.conf.example" "$(target_path /etc/snapraid.conf)"
  ensure_dir "$(target_path /var/lib/snapraid)"
  run chown root:root "$(target_path /var/lib/snapraid)"
  run chmod 0755 "$(target_path /var/lib/snapraid)"

  # Install the guarded sync script
  ensure_dir "$(target_path /usr/local/bin)"
  copy_with_backup "$NAS_ROOT/config/snapraid-sync.sh" "$(target_path /usr/local/bin/snapraid-sync.sh)"
  run chmod 0755 "$(target_path /usr/local/bin/snapraid-sync.sh)"
  copy_with_backup "$NAS_ROOT/config/snapraid-scrub.sh" "$(target_path /usr/local/bin/snapraid-scrub.sh)"
  run chmod 0755 "$(target_path /usr/local/bin/snapraid-scrub.sh)"

  local unit
  for unit in snapraid-sync.service snapraid-sync.timer snapraid-scrub.service snapraid-scrub.timer; do
    copy_with_backup "$NAS_ROOT/config/systemd/$unit" "$(target_path "/etc/systemd/system/$unit")"
  done
}

configure_btrbk() {
  log "Phase: btrbk config and timer"
  copy_with_backup "$NAS_ROOT/config/btrbk.conf.example" "$(target_path /etc/btrbk/btrbk.conf)"
  local unit
  for unit in btrbk.service btrbk.timer; do
    copy_with_backup "$NAS_ROOT/config/systemd/$unit" "$(target_path "/etc/systemd/system/$unit")"
  done
}

configure_docker() {
  log "Phase: Docker directories and /data dependency"
  local active_data active_docker_root active_compose active_appdata
  active_data="$(active_mount_path "$MERGERFS_MOUNT")"
  active_docker_root="$(target_path "$DOCKER_ROOT")"
  active_compose="$(target_path "$DOCKER_COMPOSE_DIR")"
  active_appdata="$(target_path "$DOCKER_APPDATA_DIR")"
  if [[ "$TARGET_MODE" == "live" ]]; then
    ensure_live_mergerfs_healthy
  fi
  if [[ "$APPLY" == true ]] && ! findmnt -n "$active_data" >/dev/null 2>&1; then
    die "$active_data must be mounted before Docker setup"
  fi
  ensure_dir "$active_docker_root"
  ensure_dir "$active_compose"
  ensure_dir "$active_appdata"
  if [[ "$APPLY" == true ]]; then
    verify_dir_exists "$active_docker_root"
    verify_dir_exists "$active_compose"
    verify_dir_exists "$active_appdata"
  fi
  run chown -R "$PUID:$PGID" "$active_docker_root"
  backup_file "$(target_path /etc/systemd/system/docker.service.d/wait-for-data.conf)"
  write_text "$(target_path /etc/systemd/system/docker.service.d/wait-for-data.conf)" \
    "# Generated by NAS bootstrap."$'\n'\
"# nftables protects host services. Docker published ports are explicit exposure."$'\n'\
"# Compose files should avoid broad 0.0.0.0 bindings unless intentionally reviewed."$'\n'\
"# Prefer LAN-only, Tailscale-only, or localhost bindings for admin UIs."$'\n'\
"# TODO: add a small /data/docker/compose exposure audit before real Compose stacks."$'\n'\
"[Unit]"$'\n'"RequiresMountsFor=$MERGERFS_MOUNT"$'\n'"After=network-online.target"$'\n'"Wants=network-online.target"$'\n'
  copy_with_backup "$NAS_ROOT/config/docker-daemon.json.example" "$(target_path /etc/docker/daemon.json)"
}

configure_pc_worker_orchestration() {
  log "Phase: PC worker orchestration units"
  if [[ "$PC_WORKER_ORCHESTRATION_ENABLE" != "true" ]]; then
    warn "PC_WORKER_ORCHESTRATION_ENABLE is false; skipping PC worker orchestration units."
    return 0
  fi

  local unit
  for unit in immich-ml-wake-proxy.service tdarr-wake-monitor.service tdarr-wake-monitor.timer; do
    copy_with_backup "$NAS_ROOT/config/systemd/$unit" "$(target_path "/etc/systemd/system/$unit")"
  done
}

configure_samba() {
  log "Phase: Samba config"
  copy_with_backup "$NAS_ROOT/config/smb.conf.example" "$(target_path /etc/samba/smb.conf)"
  if target_command_available testparm; then
    target_run testparm -s /etc/samba/smb.conf
  else
    warn "testparm not found; install samba before health checks."
  fi
}

configure_tailscale() {
  log "Phase: SSH and Tailscale"
  ensure_dir "$(target_path /etc/ssh/sshd_config.d)"
  copy_with_backup "$NAS_ROOT/config/ssh/99-ipv4-only.conf" "$(target_path /etc/ssh/sshd_config.d/99-ipv4-only.conf)"
  warn "Tailscale auth keys are not stored in this repo."
  log "Manual next step after service enablement: sudo tailscale up"
}

configure_services() {
  configure_operations_basics
  configure_swap
  configure_firewall
  configure_smartd
  configure_snapraid
  configure_btrbk
  configure_docker
  configure_pc_worker_orchestration
  configure_samba
  configure_tailscale
}

enable_services() {
  log "Phase: enable services"
  if [[ "$TARGET_MODE" == "host" ]]; then
    run systemctl daemon-reload
  else
    warn "TARGET_MODE=live: enabling target services only; not starting services inside chroot."
  fi
  if [[ "$FIREWALL_ENABLE" == "true" ]]; then
    target_run systemctl enable nftables
    if [[ "$START_SERVICES" == true && "$TARGET_MODE" == "host" ]]; then
      target_run systemctl start nftables
    fi
  fi
  if [[ "$ENABLE_UFW" == "true" ]]; then
    target_run systemctl enable ufw
    if [[ "$START_SERVICES" == true && "$TARGET_MODE" == "host" ]]; then
      target_run systemctl start ufw
    fi
  fi

  target_run systemctl enable systemd-timesyncd.service
  target_run systemctl enable nas-kernel-maintenance-reminder.timer
  target_run systemctl enable nas-weekly-digest.timer
  target_run systemctl enable nas-recent-files.timer
  target_run systemctl enable nas-duplicate-report.timer
  target_run systemctl enable nas-uptime-ledger.timer
  target_run systemctl enable nas-nextcloud-external-scan.timer
  if [[ "$START_SERVICES" == true && "$TARGET_MODE" == "host" ]]; then
    target_run systemctl start systemd-timesyncd.service
  fi
  if [[ "$SMART_ENABLE" == "true" ]]; then
    target_run systemctl enable smartd.service
    if [[ "$START_SERVICES" == true && "$TARGET_MODE" == "host" ]]; then
      target_run systemctl start smartd.service
    fi
  fi
  if [[ "$DOCKER_ENABLE" == "true" ]]; then
    target_run systemctl enable docker
    if [[ "$START_SERVICES" == true && "$TARGET_MODE" == "host" ]]; then
      target_run systemctl start docker
    fi
  fi
  if [[ "$PC_WORKER_ORCHESTRATION_ENABLE" == "true" ]]; then
    target_run systemctl enable immich-ml-wake-proxy.service tdarr-wake-monitor.timer
    if [[ "$START_SERVICES" == true && "$TARGET_MODE" == "host" ]]; then
      target_run systemctl start immich-ml-wake-proxy.service tdarr-wake-monitor.timer
    fi
  fi
  if [[ "$TAILSCALE_ENABLE" == "true" ]]; then
    target_run systemctl enable sshd tailscaled
    if [[ "$START_SERVICES" == true && "$TARGET_MODE" == "host" ]]; then
      target_run systemctl start sshd tailscaled
    fi
  else
    target_run systemctl enable sshd
  fi
  if [[ "$SMB_ENABLE" == "true" ]]; then
    target_run systemctl enable smb nmb
    if [[ "$START_SERVICES" == true && "$TARGET_MODE" == "host" ]]; then
      target_run systemctl start smb nmb
    fi
  fi
  if [[ "$SNAPRAID_ENABLE" == "true" ]]; then
    target_run systemctl enable snapraid-sync.timer snapraid-scrub.timer
  fi
  if [[ "$BTRBK_ENABLE" == "true" ]]; then
    target_run systemctl enable btrbk.timer
  fi
  target_run systemctl enable nas-btrfs-scrub-disk1.timer nas-btrfs-scrub-disk2.timer nas-btrfs-scrub-disk3.timer
  target_run systemctl enable nas-url-queue-notify.path
  if [[ "$SNAPPER_ENABLE" == "true" ]]; then
    target_run systemctl enable snapper-timeline.timer snapper-cleanup.timer
    if [[ "$START_SERVICES" == true && "$TARGET_MODE" == "host" ]]; then
      target_run systemctl start snapper-timeline.timer snapper-cleanup.timer
    fi
  fi
  if [[ "$GRUB_BTRFS_ENABLE" == "true" ]]; then
    if [[ "$APPLY" != true ]] || target_unit_exists grub-btrfsd.service; then
      target_run systemctl enable grub-btrfsd.service
      if [[ "$START_SERVICES" == true && "$TARGET_MODE" == "host" ]]; then
        target_run systemctl start grub-btrfsd.service
      fi
    else
      warn "grub-btrfsd.service is not available; GRUB snapshot menu auto-refresh will not be enabled."
    fi
  fi
}

post_install_next_steps_text() {
  cat <<EOF
Set passwords before rebooting:

  arch-chroot $TARGET_ROOT passwd
  arch-chroot $TARGET_ROOT passwd $NAS_USER

Then run:

  sudo $SCRIPT_DIR/bootstrap-nas.sh --env-file $ENV_FILE --check-live-target

Then reboot without the ISO and run:

  sudo $SCRIPT_DIR/bootstrap-nas.sh --env-file $ENV_FILE --check-health
EOF
}

write_post_install_next_steps() {
  [[ "$INSTALL_ARCH" == true ]] || return 0
  local path="$TARGET_ROOT/root/NAS_POST_INSTALL_NEXT_STEPS.txt"
  log "+ write $path"
  if [[ "$APPLY" == true ]]; then
    mkdir -p "$TARGET_ROOT/root"
    post_install_next_steps_text >"$path"
  fi
}

print_post_install_password_reminder() {
  [[ "$INSTALL_ARCH" == true ]] || return 0
  cat <<EOF
================================================================================
IMPORTANT NEXT STEP: SET PASSWORDS BEFORE REBOOTING
================================================================================

The installed system was created, but passwords may not be set yet.

Run these before rebooting out of the Arch ISO:

  arch-chroot $TARGET_ROOT passwd
  arch-chroot $TARGET_ROOT passwd $NAS_USER

Then run the pre-reboot live target check:

  sudo $SCRIPT_DIR/bootstrap-nas.sh \\
    --env-file $ENV_FILE \\
    --check-live-target

Only reboot after passwords and the live target check are done.

After rebooting without the ISO, run:

  sudo $SCRIPT_DIR/bootstrap-nas.sh \\
    --env-file $ENV_FILE \\
    --check-health

================================================================================
EOF
}

CHECK_PASS=0
CHECK_WARN=0
