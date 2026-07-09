check_pass() {
  printf '[PASS] %s\n' "$*"
  CHECK_PASS=$((CHECK_PASS + 1))
}

check_warn() {
  printf '[WARN] %s\n' "$*"
  CHECK_WARN=$((CHECK_WARN + 1))
}

check_fail() {
  printf '[FAIL] %s\n' "$*"
  CHECK_FAIL=$((CHECK_FAIL + 1))
}

print_check_summary() {
  printf '\nNAS check summary\n'
  printf '=================\n'
  printf 'PASS=%s\n' "$CHECK_PASS"
  printf 'WARN=%s\n' "$CHECK_WARN"
  printf 'FAIL=%s\n' "$CHECK_FAIL"
  if [[ "$CHECK_FAIL" -eq 0 ]]; then
    printf 'RESULT: HEALTHY\n'
    return 0
  fi
  printf 'RESULT: UNHEALTHY\n'
  return 1
}

check_path_exists() {
  local path="$1"
  [[ -e "$path" ]] && check_pass "$path exists" || check_fail "$path exists"
}

check_dir_exists() {
  local path="$1"
  [[ -d "$path" ]] && check_pass "$path exists" || check_fail "$path exists"
}

check_mount_exists() {
  local path="$1"
  if findmnt "$path" >/dev/null 2>&1; then
    check_pass "$path is mounted"
  else
    check_fail "$path is mounted"
  fi
}

check_mount_count_one() {
  local path="$1" count
  count="$(findmnt -rn -o TARGET 2>/dev/null | awk -v path="$path" '$0 == path { count++ } END { print count + 0 }')"
  if [[ "$count" -eq 1 ]]; then
    check_pass "$path has exactly one mount"
  else
    check_fail "$path has exactly one mount (found $count)"
  fi
}

check_no_transport_error() {
  local path="$1" err
  err="$(ls "$path" 2>&1 >/dev/null || true)"
  if [[ "$err" == *"Transport endpoint is not connected"* ]]; then
    check_fail "$path is not a broken FUSE endpoint"
  else
    check_pass "$path is not a broken FUSE endpoint"
  fi
}

check_mount_mergerfs_like() {
  local path="$1" label="$2" fstype source
  fstype="$(findmnt -n -o FSTYPE "$path" 2>/dev/null || true)"
  source="$(findmnt -n -o SOURCE "$path" 2>/dev/null || true)"
  if [[ "$fstype" == *fuse* || "$fstype" == *mergerfs* || "$source" == *"/mnt/disk"* ]]; then
    check_pass "$label"
  else
    check_fail "$label (fstype=$fstype source=$source)"
  fi
}

check_mount_fstype() {
  local path="$1" expected="$2" label="$3" fstype
  fstype="$(findmnt -n -o FSTYPE "$path" 2>/dev/null || true)"
  [[ "$fstype" == "$expected" ]] && check_pass "$label" || check_fail "$label (fstype=$fstype)"
}

check_mount_option_contains_any() {
  local path="$1" label="$2" options candidate
  shift 2
  options="$(findmnt -n -o OPTIONS "$path" 2>/dev/null || true)"
  for candidate in "$@"; do
    if [[ ",$options," == *",$candidate,"* ]]; then
      check_pass "$label"
      return 0
    fi
  done
  check_fail "$label (options=$options)"
}

check_mount_option_not_contains() {
  local path="$1" label="$2" token="$3" options
  options="$(findmnt -n -o OPTIONS "$path" 2>/dev/null || true)"
  if [[ ",$options," == *",$token,"* ]]; then
    check_fail "$label (options=$options)"
  else
    check_pass "$label"
  fi
}

check_file_contains_literal() {
  local path="$1" text="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    check_fail "$label ($path missing)"
  elif grep -Fq "$text" "$path"; then
    check_pass "$label"
  else
    check_fail "$label"
  fi
}

check_file_not_contains_literal() {
  local path="$1" text="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    check_fail "$label ($path missing)"
  elif grep -Fq "$text" "$path"; then
    check_fail "$label"
  else
    check_pass "$label"
  fi
}

check_file_contains_regex() {
  local path="$1" pattern="$2" label="$3"
  if [[ ! -f "$path" ]]; then
    check_fail "$label ($path missing)"
  elif grep -Eq "$pattern" "$path"; then
    check_pass "$label"
  else
    check_fail "$label"
  fi
}

check_no_duplicate_fstab_mount() {
  local fstab="$1" mountpoint="$2" count
  if [[ ! -f "$fstab" ]]; then
    check_fail "fstab exists at $fstab"
    return 0
  fi
  count="$(awk -v mp="$mountpoint" '$1 !~ /^#/ && $2 == mp { count++ } END { print count+0 }' "$fstab")"
  if (( count == 1 )); then
    check_pass "fstab has exactly one entry for $mountpoint"
  else
    check_fail "fstab has $count entries for $mountpoint"
  fi
}

fstab_line_for_mount() {
  local fstab="$1" mountpoint="$2"
  awk -v mp="$mountpoint" '$1 !~ /^#/ && $2 == mp { print; found=1 } END { exit !found }' "$fstab" 2>/dev/null || true
}

check_no_fstab_mergerfs_entry() {
  local fstab="$1" mountpoint="$2" count
  if [[ ! -f "$fstab" ]]; then
    check_fail "fstab exists at $fstab"
    return 0
  fi
  count="$(awk -v mp="$mountpoint" '$1 !~ /^#/ && $2 == mp && $3 == "mergerfs" { count++ } END { print count + 0 }' "$fstab")"
  if (( count == 0 )); then
    check_pass "fstab has no mergerfs entry for $mountpoint"
  else
    check_fail "fstab has $count mergerfs entries for $mountpoint; mergerfs is managed by systemd mount units"
  fi
}

check_mergerfs_mount_unit() {
  local mountpoint="$1" branch_suffix="$2" unit_name unit_path idx token
  unit_name="$(mount_unit_name_for_path "$mountpoint")"
  unit_path="$(target_path "/etc/systemd/system/$unit_name")"
  check_path_exists "$unit_path"
  [[ -f "$unit_path" ]] || return 0
  check_file_contains_literal "$unit_path" "Where=$mountpoint" "$unit_name uses $mountpoint"
  check_file_contains_literal "$unit_path" "Type=mergerfs" "$unit_name uses mergerfs type"
  check_file_not_contains_literal "$unit_path" "$PARITY_MOUNT" "$unit_name excludes parity mount"
  for idx in "${!DATA_DISK_LABELS[@]}"; do
    token="/mnt/disk$((idx + 1))/$branch_suffix"
    check_file_contains_literal "$unit_path" "$token" "$unit_name source contains $token"
  done
  if [[ "$mountpoint" == "$MERGERFS_MOUNT" ]]; then
    check_file_contains_literal "$unit_path" "category.create=$MERGERFS_CREATE_POLICY" "$unit_name has create policy"
    check_file_contains_literal "$unit_path" "moveonenospc=true" "$unit_name moves on no space"
    check_file_contains_literal "$unit_path" "minfreespace=$MERGERFS_MIN_FREE_SPACE" "$unit_name has min free space policy"
  fi
  if [[ "$mountpoint" == "$SNAPSHOT_VIEW_MOUNT" ]]; then
    check_file_contains_literal "$unit_path" "Options=defaults,ro," "$unit_name is read-only"
  fi
  check_unit_enabled "$unit_name" true
}

check_package_installed() {
  local package="$1"
  if check_run_target pacman -Q "$package" >/dev/null 2>&1; then
    check_pass "$package package installed"
  else
    check_fail "$package package installed"
  fi
}

check_unit_enabled() {
  local unit="$1" required="${2:-true}"
  if check_run_target systemctl is-enabled "$unit" >/dev/null 2>&1; then
    check_pass "$unit enabled"
  elif [[ "$required" == "true" ]]; then
    check_fail "$unit enabled"
  else
    check_warn "$unit not enabled"
  fi
}

check_unit_active() {
  local unit="$1" required="${2:-true}"
  if check_run_target systemctl is-active "$unit" >/dev/null 2>&1; then
    check_pass "$unit active"
  elif [[ "$required" == "true" ]]; then
    check_fail "$unit active"
  else
    check_warn "$unit not active"
  fi
}

check_unit_not_failed() {
  local unit="$1"
  if check_run_target systemctl is-failed "$unit" >/dev/null 2>&1; then
    check_fail "$unit is not failed"
  else
    check_pass "$unit is not failed"
  fi
}

check_btrfs_subvolume() {
  local path="$1"
  if ! command -v btrfs >/dev/null 2>&1; then
    check_fail "btrfs command available for subvolume checks"
  elif btrfs subvolume show "$path" >/dev/null 2>&1; then
    check_pass "$path is a btrfs subvolume"
  else
    check_fail "$path is a btrfs subvolume"
  fi
}

check_device_fstype_label() {
  local device="$1" expected_type="$2" expected_label="${3:-}" label="$4" actual_type actual_label
  actual_type="$(blkid_value "$device" TYPE || true)"
  actual_label="$(blkid_value "$device" LABEL || true)"
  [[ "$actual_type" == "$expected_type" ]] && check_pass "$label type is $expected_type" || check_fail "$label type is $expected_type (found ${actual_type:-none})"
  if [[ -n "$expected_label" ]]; then
    [[ "$actual_label" == "$expected_label" ]] && check_pass "$label label is $expected_label" || check_fail "$label label is $expected_label (found ${actual_label:-none})"
  fi
}

check_write_behavior() {
  [[ "$VALIDATE_WRITE_TESTS" == "true" ]] || return 0
  local data_path snapshot_path test_path
  data_path="$(active_mount_path "$MERGERFS_MOUNT")"
  snapshot_path="$(active_mount_path "$SNAPSHOT_VIEW_MOUNT")"
  test_path="$data_path/.nas-bootstrap-health-write-test"
  if touch "$test_path" >/dev/null 2>&1 && [[ -f "$test_path" ]]; then
    rm -f "$test_path"
    check_pass "$MERGERFS_MOUNT is writable"
  else
    check_fail "$MERGERFS_MOUNT is writable"
  fi
  test_path="$snapshot_path/.nas-bootstrap-should-not-write"
  if touch "$test_path" >/dev/null 2>&1; then
    rm -f "$test_path"
    check_fail "$SNAPSHOT_VIEW_MOUNT rejects writes"
  else
    check_pass "$SNAPSHOT_VIEW_MOUNT rejects writes"
  fi
}

check_common_os_mounts() {
  check_mount_exists "$(active_mount_path /)"
  check_mount_exists "$(active_mount_path /home)"
  check_mount_exists "$(active_mount_path /var/log)"
  check_mount_exists "$(active_mount_path /var/cache/pacman/pkg)"
  check_mount_exists "$(active_mount_path /.snapshots)"
  check_mount_option_contains_any "$(active_mount_path /)" "root uses @ subvolume" "subvol=@" "subvol=/@"
  check_mount_option_contains_any "$(active_mount_path /home)" "/home uses @home subvolume" "subvol=@home" "subvol=/@home"
  check_mount_option_contains_any "$(active_mount_path /var/log)" "/var/log uses @log subvolume" "subvol=@log" "subvol=/@log"
  check_mount_option_contains_any "$(active_mount_path /var/cache/pacman/pkg)" "/var/cache/pacman/pkg uses @pkg subvolume" "subvol=@pkg" "subvol=/@pkg"
  check_mount_option_contains_any "$(active_mount_path /.snapshots)" "/.snapshots uses @snapshots subvolume" "subvol=@snapshots" "subvol=/@snapshots"
}

check_common_data_mounts() {
  local idx mountpoint subvol path
  for idx in "${!DATA_DISK_LABELS[@]}"; do
    mountpoint="$(active_mount_path "/mnt/disk$((idx + 1))")"
    check_mount_exists "$mountpoint"
    check_mount_fstype "$mountpoint" btrfs "$mountpoint is btrfs"
    check_dir_exists "$mountpoint/pool"
    check_dir_exists "$mountpoint/snapshots"
    for subvol in "${POOL_SUBVOLUMES[@]}"; do
      path="$mountpoint/pool/$subvol"
      check_dir_exists "$path"
      check_btrfs_subvolume "$path"
    done
    check_dir_exists "$mountpoint/pool/media/torrents"
    if [[ -L "$mountpoint/pool/torrents" ]] && [[ "$(readlink "$mountpoint/pool/torrents")" == "media/torrents" ]]; then
      check_pass "$mountpoint/pool/torrents points to media/torrents"
    else
      check_fail "$mountpoint/pool/torrents points to media/torrents"
    fi
  done
  check_mount_exists "$(active_mount_path "$PARITY_MOUNT")"
  check_mount_exists "$(active_mount_path "$MERGERFS_MOUNT")"
  check_mount_exists "$(active_mount_path "$SNAPSHOT_VIEW_MOUNT")"
  check_mount_count_one "$(active_mount_path "$MERGERFS_MOUNT")"
  check_mount_count_one "$(active_mount_path "$SNAPSHOT_VIEW_MOUNT")"
  check_mount_mergerfs_like "$(active_mount_path "$MERGERFS_MOUNT")" "$MERGERFS_MOUNT appears mergerfs-backed"
  check_mount_mergerfs_like "$(active_mount_path "$SNAPSHOT_VIEW_MOUNT")" "$SNAPSHOT_VIEW_MOUNT appears mergerfs-backed"
  check_mount_option_not_contains "$(active_mount_path "$MERGERFS_MOUNT")" "$MERGERFS_MOUNT is writable" "ro"
  check_mount_option_contains_any "$(active_mount_path "$SNAPSHOT_VIEW_MOUNT")" "$SNAPSHOT_VIEW_MOUNT is read-only" "ro"
  check_no_transport_error "$(active_mount_path "$MERGERFS_MOUNT")"
  check_no_transport_error "$(active_mount_path "$SNAPSHOT_VIEW_MOUNT")"
  check_write_behavior
}

check_common_pool_dirs() {
  local path
  for path in \
    "$MERGERFS_MOUNT/media" \
    "$MERGERFS_MOUNT/torrents" \
    "$MERGERFS_MOUNT/media/torrents" \
    "$MERGERFS_MOUNT/personal" \
    "$MERGERFS_MOUNT/replicas" \
    "$MERGERFS_MOUNT/secrets" \
    "$MERGERFS_MOUNT/staging" \
    "$MERGERFS_MOUNT/appdata-bulk" \
    "$MERGERFS_MOUNT/docker" \
    "$MERGERFS_MOUNT/backups" \
    "$DOCKER_COMPOSE_DIR" \
    "$DOCKER_APPDATA_DIR"; do
    check_dir_exists "$(target_path "$path")"
  done
  if [[ "$(target_path "$MERGERFS_MOUNT/torrents")" -ef "$(target_path "$MERGERFS_MOUNT/media/torrents")" ]]; then
    check_pass "$MERGERFS_MOUNT/torrents resolves to $MERGERFS_MOUNT/media/torrents"
  else
    check_fail "$MERGERFS_MOUNT/torrents resolves to $MERGERFS_MOUNT/media/torrents"
  fi
}

check_common_fstab() {
  local fstab="$1" bad_fuse bad_fsname idx
  bad_fuse="fuse.merger""fs"
  bad_fsname="fsname=merger""fs"
  check_path_exists "$fstab"
  check_file_not_contains_literal "$fstab" "$bad_fuse" "fstab avoids legacy mergerfs fstype"
  check_file_not_contains_literal "$fstab" "$bad_fsname" "fstab avoids legacy mergerfs fsname option"
  check_file_not_contains_literal "$fstab" "/mnt/mnt/" "fstab uses final paths"
  check_no_fstab_mergerfs_entry "$fstab" "$MERGERFS_MOUNT"
  check_no_fstab_mergerfs_entry "$fstab" "$SNAPSHOT_VIEW_MOUNT"
  check_mergerfs_mount_unit "$MERGERFS_MOUNT" pool
  check_mergerfs_mount_unit "$SNAPSHOT_VIEW_MOUNT" snapshots
  for idx in "${!DATA_DISK_LABELS[@]}"; do
    check_no_duplicate_fstab_mount "$fstab" "/mnt/disk$((idx + 1))"
  done
  check_no_duplicate_fstab_mount "$fstab" "$PARITY_MOUNT"
  check_no_duplicate_fstab_mount "$fstab" /
  check_no_duplicate_fstab_mount "$fstab" /home
  check_no_duplicate_fstab_mount "$fstab" /var/log
  check_no_duplicate_fstab_mount "$fstab" /var/cache/pacman/pkg
  check_no_duplicate_fstab_mount "$fstab" /.snapshots
  check_no_duplicate_fstab_mount "$fstab" /boot
}

check_common_packages() {
  local package
  for package in grub efibootmgr intel-ucode snapper snap-pac docker docker-compose samba btrbk yay mergerfs snapraid nftables smartmontools nvme-cli rsync restic jq curl hdparm lsscsi sg3_utils wol; do
    check_package_installed "$package"
  done
  [[ "$GRUB_BTRFS_ENABLE" == "true" ]] && check_package_installed grub-btrfs
  if [[ "$ENABLE_UFW" == "true" ]]; then
    check_package_installed ufw
  else
    if check_run_target pacman -Q ufw >/dev/null 2>&1; then
      check_fail "ufw package is not installed on NAS"
    else
      check_pass "ufw package is not installed on NAS"
    fi
  fi
}

check_common_grub_snapper() {
  local grub_config snapper_config
  grub_config="$(target_path /boot/grub/grub.cfg)"
  snapper_config="$(target_path "/etc/snapper/configs/$SNAPPER_CONFIG_NAME")"
  check_path_exists "$grub_config"
  check_file_contains_literal "$grub_config" "intel-ucode.img" "GRUB config references Intel microcode"
  check_file_contains_literal "$grub_config" "rootflags=subvol=@" "GRUB config uses rootflags=subvol=@"
  if [[ -f "$grub_config" ]] && grep -Eiq 'snapshot|snapper|grub-btrfs' "$grub_config"; then
    check_pass "GRUB config contains snapshot menu integration"
  else
    check_warn "GRUB config does not yet contain snapshot menu entries; normal GRUB/Snapper may still work, but grub-btrfs integration needs review."
  fi
  if [[ "$SNAPPER_ENABLE" == "true" ]]; then
    check_path_exists "$snapper_config"
    check_file_contains_literal "$snapper_config" 'SUBVOLUME="/"' "Snapper root config uses /"
    check_file_contains_literal "$snapper_config" 'FSTYPE="btrfs"' "Snapper root config uses btrfs"
    check_file_contains_literal "$snapper_config" 'TIMELINE_CREATE="yes"' "Snapper timeline snapshots enabled"
    check_file_contains_literal "$snapper_config" 'TIMELINE_CLEANUP="yes"' "Snapper timeline cleanup enabled"
    check_file_contains_literal "$snapper_config" 'NUMBER_CLEANUP="yes"' "Snapper numbered cleanup enabled"
    check_file_contains_literal "$(target_path /etc/conf.d/snapper)" "SNAPPER_CONFIGS=\"$SNAPPER_CONFIG_NAME\"" "Snapper root config registered"
    if [[ -d "$(target_path /etc/snapper/configs)" ]] && grep -R -F "$MERGERFS_MOUNT" "$(target_path /etc/snapper/configs)" >/dev/null 2>&1; then
      check_fail "No Snapper config references $MERGERFS_MOUNT"
    else
      check_pass "No Snapper config references $MERGERFS_MOUNT"
    fi
    if check_run_target snapper --no-dbus -c "$SNAPPER_CONFIG_NAME" list >/dev/null 2>&1 || check_run_target snapper -c "$SNAPPER_CONFIG_NAME" list >/dev/null 2>&1; then
      check_pass "snapper root config can be listed"
    else
      check_fail "snapper root config can be listed"
    fi
    check_unit_enabled snapper-timeline.timer true
    check_unit_enabled snapper-cleanup.timer true
  fi
}

check_common_docker() {
  [[ "$DOCKER_ENABLE" == "true" ]] || return 0
  local docker_override
  docker_override="$(target_path /etc/systemd/system/docker.service.d/wait-for-data.conf)"
  check_path_exists "$docker_override"
  check_file_contains_literal "$docker_override" "RequiresMountsFor=$MERGERFS_MOUNT" "Docker waits for $MERGERFS_MOUNT"
  check_file_contains_literal "$docker_override" "After=network-online.target" "Docker waits for network-online target"
  check_file_contains_literal "$docker_override" "Docker published ports are explicit exposure" "Docker exposure stance documented"
  check_unit_enabled docker true
  if [[ "$TARGET_MODE" == "host" ]]; then
    if systemctl cat docker 2>/dev/null | grep -F "RequiresMountsFor=$MERGERFS_MOUNT" >/dev/null; then
      check_pass "systemctl cat docker includes mount dependency"
    else
      check_fail "systemctl cat docker includes mount dependency"
    fi
    if [[ "$START_SERVICES_AFTER_ENABLE" == "true" ]]; then
      systemctl is-active docker >/dev/null 2>&1 && check_pass "docker active" || check_fail "docker active"
      docker info >/dev/null 2>&1 && check_pass "docker daemon responds" || check_fail "docker daemon responds"
    else
      systemctl is-active docker >/dev/null 2>&1 && check_pass "docker active" || check_warn "docker not active; START_SERVICES_AFTER_ENABLE=false"
    fi
  fi
}

check_common_pc_worker_orchestration() {
  [[ "$PC_WORKER_ORCHESTRATION_ENABLE" == "true" ]] || return 0

  check_path_exists "$(target_path /etc/systemd/system/immich-ml-wake-proxy.service)"
  check_path_exists "$(target_path /etc/systemd/system/tdarr-wake-monitor.service)"
  check_path_exists "$(target_path /etc/systemd/system/tdarr-wake-monitor.timer)"
  check_path_exists "$(active_mount_path "$DOCKER_COMPOSE_DIR")/nightly-orchestrator/immich-ml-wake-proxy.py"
  check_path_exists "$(active_mount_path "$DOCKER_COMPOSE_DIR")/nightly-orchestrator/tdarr-wake-monitor.sh"
  check_path_exists "$(active_mount_path "$DOCKER_COMPOSE_DIR")/nightly-orchestrator/pc-worker-ensure.sh"
  check_unit_enabled immich-ml-wake-proxy.service true
  check_unit_enabled tdarr-wake-monitor.timer true
  if [[ "$TARGET_MODE" == "host" ]]; then
    check_unit_active immich-ml-wake-proxy.service true
    check_unit_active tdarr-wake-monitor.timer true
  fi
}

check_common_snapraid_btrbk_samba() {
  local snapraid_conf btrbk_conf samba_conf idx mountpoint snapraid_output snapraid_status
  snapraid_conf="$(target_path /etc/snapraid.conf)"
  btrbk_conf="$(target_path /etc/btrbk/btrbk.conf)"
  samba_conf="$(target_path /etc/samba/smb.conf)"

  if [[ "$SNAPRAID_ENABLE" == "true" ]]; then
    check_path_exists "$snapraid_conf"
    check_dir_exists "$(target_path /var/lib/snapraid)"
    check_command_exists_target snapraid && check_pass "snapraid command installed" || check_fail "snapraid command installed"
    for path in torrents iso-mirror staging snapshots '#recycle'; do
      check_file_contains_literal "$snapraid_conf" "$path" "SnapRAID excludes $path"
    done
    for idx in "${!DATA_DISK_LABELS[@]}"; do
      mountpoint="/mnt/disk$((idx + 1))"
      check_file_contains_literal "$snapraid_conf" "$mountpoint" "SnapRAID references $mountpoint"
    done
    if [[ -f "$snapraid_conf" ]] && grep -E "^[[:space:]]*data[[:space:]].*$SNAPSHOT_VIEW_MOUNT" "$snapraid_conf" >/dev/null 2>&1; then
      check_fail "SnapRAID data entries exclude $SNAPSHOT_VIEW_MOUNT"
    else
      check_pass "SnapRAID data entries exclude $SNAPSHOT_VIEW_MOUNT"
    fi
    if [[ -f "$snapraid_conf" ]] && grep -E "^[[:space:]]*data[[:space:]].*$PARITY_MOUNT" "$snapraid_conf" >/dev/null 2>&1; then
      check_fail "SnapRAID data entries exclude parity mount"
    else
      check_pass "SnapRAID data entries exclude parity mount"
    fi
    snapraid_output="$(check_run_target snapraid status 2>&1)" && snapraid_status=0 || snapraid_status=$?
    if [[ "$snapraid_status" -eq 0 ]]; then
      check_pass "snapraid status"
    elif [[ "$snapraid_output" == *"Error accessing 'content' dir"* || "$snapraid_output" == *"/var/lib/snapraid"* ]]; then
      printf '%s\n' "$snapraid_output"
      check_fail "snapraid content directory is accessible"
    else
      printf '%s\n' "$snapraid_output"
      check_warn "SnapRAID installed/configured, initial sync may not have been run yet"
    fi
    if snapraid_output="$(check_run_target snapraid diff 2>&1)"; then
      if [[ "$snapraid_output" == *"WARNING! Ignoring mount point"* ]]; then
        printf '%s\n' "$snapraid_output"
        check_fail "SnapRAID data entries cover Btrfs subvolume contents"
      else
        check_pass "SnapRAID data entries cover Btrfs subvolume contents"
      fi
    else
      if [[ "$snapraid_output" == *"WARNING! Ignoring mount point"* ]]; then
        printf '%s\n' "$snapraid_output"
        check_fail "SnapRAID data entries cover Btrfs subvolume contents"
      else
        check_warn "SnapRAID diff could not be checked before initial sync"
      fi
    fi
    check_unit_enabled snapraid-sync.timer true
    check_unit_enabled snapraid-scrub.timer true
  fi

  if [[ "$BTRBK_ENABLE" == "true" ]]; then
    check_path_exists "$btrbk_conf"
    for idx in "${!DATA_DISK_LABELS[@]}"; do
      mountpoint="/mnt/disk$((idx + 1))"
      check_file_contains_literal "$btrbk_conf" "$mountpoint" "btrbk references $mountpoint"
    done
    check_file_contains_literal "$btrbk_conf" "snapshot_dir snapshots" "btrbk snapshots outside mergerfs pool"
    check_file_not_contains_literal "$btrbk_conf" "$MERGERFS_MOUNT" "btrbk does not snapshot through $MERGERFS_MOUNT"
    if [[ -f "$btrbk_conf" ]] && grep -Eq 'subvolume[[:space:]]+pool/torrents' "$btrbk_conf"; then
      check_fail "btrbk does not snapshot torrents"
    else
      check_pass "btrbk does not snapshot torrents"
    fi
    if [[ "$TARGET_MODE" == "host" ]]; then
      btrbk -c /etc/btrbk/btrbk.conf dryrun >/dev/null 2>&1 && check_pass "btrbk config dryrun" || check_fail "btrbk config dryrun"
    else
      check_warn "btrbk dryrun skipped in live target check"
    fi
    check_unit_enabled btrbk.timer true
  fi

  if [[ "$SMB_ENABLE" == "true" ]]; then
    check_path_exists "$samba_conf"
    if check_run_target testparm -s /etc/samba/smb.conf >/dev/null 2>&1; then
      check_pass "Samba config parses"
    else
      check_fail "Samba config parses"
    fi
    if [[ -f "$samba_conf" ]] && grep -E "^[[:space:]]*path[[:space:]]*=[[:space:]]*$MERGERFS_MOUNT/secrets([[:space:]]|$)" "$samba_conf" >/dev/null 2>&1; then
      check_fail "Samba does not expose secrets"
    else
      check_pass "Samba does not expose secrets"
    fi
    check_unit_enabled smb true
    check_unit_enabled nmb true
  fi
}

check_common_services() {
  check_unit_enabled sshd true
  if [[ "$TARGET_MODE" == "host" ]]; then
    check_unit_active sshd true
  fi
  if [[ "$TAILSCALE_ENABLE" == "true" ]]; then
    check_unit_enabled tailscaled true
    if [[ "$TARGET_MODE" == "host" ]]; then
      tailscale status >/dev/null 2>&1 && check_pass "Tailscale status available" || check_warn "Tailscale may not be authenticated yet"
    fi
  fi
  check_unit_enabled systemd-timesyncd.service true
  if [[ "$TARGET_MODE" == "host" ]]; then
    check_unit_active systemd-timesyncd.service true
  fi
  if [[ "$ENABLE_UFW" == "true" ]]; then
    check_unit_enabled ufw.service true
    if [[ "$TARGET_MODE" == "host" ]]; then
      check_unit_not_failed ufw.service
      check_unit_active ufw.service true
    fi
  fi
  if [[ "$FIREWALL_ENABLE" == "true" ]]; then
    check_path_exists "$(target_path /etc/nftables.conf)"
    check_unit_enabled nftables.service true
    if [[ "$TARGET_MODE" == "host" ]]; then
      check_unit_not_failed nftables.service
      if check_run_target nft -c -f /etc/nftables.conf >/dev/null 2>&1; then
        check_pass "nftables config validates"
      else
        check_fail "nftables config validates"
      fi
      if check_run_target nft list ruleset >/dev/null 2>&1; then
        check_pass "nft list ruleset succeeds"
      else
        check_fail "nft list ruleset succeeds"
      fi
    fi
  fi
  if [[ "$SMART_ENABLE" == "true" ]]; then
    check_path_exists "$(target_path /etc/smartd.conf)"
    check_unit_enabled smartd.service true
    if [[ "$TARGET_MODE" == "host" ]]; then
      local smart_scan
      smart_scan="$(check_run_target smartctl --scan-open 2>/dev/null || true)"
      if [[ -n "$smart_scan" ]]; then
        check_unit_active smartd.service true
        check_pass "SMART devices detected"
      else
        check_warn "SMART devices unavailable; likely QEMU virtio or unsupported controller"
      fi
    fi
  fi
  check_path_exists "$(target_path /etc/systemd/journald.conf.d/90-nas-bootstrap.conf)"
  check_file_contains_literal "$(target_path /etc/systemd/journald.conf.d/90-nas-bootstrap.conf)" "SystemMaxUse=$JOURNALD_SYSTEM_MAX_USE" "journald SystemMaxUse configured"
  check_file_contains_literal "$(target_path /etc/systemd/journald.conf.d/90-nas-bootstrap.conf)" "RuntimeMaxUse=$JOURNALD_RUNTIME_MAX_USE" "journald RuntimeMaxUse configured"
  check_file_contains_literal "$(target_path /etc/systemd/journald.conf.d/90-nas-bootstrap.conf)" "MaxRetentionSec=$JOURNALD_MAX_RETENTION_SEC" "journald MaxRetentionSec configured"
  if [[ "$SWAP_ENABLE" == "true" ]]; then
    check_path_exists "$(target_path "$SWAP_FILE")"
    check_file_contains_literal "$(target_path /etc/fstab)" "$SWAP_FILE none swap defaults 0 0" "swapfile is persistent in fstab"
    if [[ "$TARGET_MODE" == "host" ]]; then
      swapon --show=NAME --noheadings | grep -Fxq "$SWAP_FILE" && check_pass "$SWAP_FILE is active" || check_fail "$SWAP_FILE is active"
    fi
  fi
  check_path_exists "$(target_path /usr/local/sbin/nas-notify)"
  if [[ -x "$(target_path /usr/local/sbin/nas-notify)" ]]; then
    check_pass "nas-notify helper is executable"
  else
    check_fail "nas-notify helper is executable"
  fi
  check_file_contains_literal "$(target_path /usr/local/sbin/nas-notify)" "Placeholder notification helper" "nas-notify is clearly marked placeholder"
  if [[ "$GRUB_BTRFS_ENABLE" == "true" ]]; then
    check_unit_enabled grub-btrfsd.service false
  fi
}

check_mount_a_and_findmnt_verify() {
  local output status
  if awk '$1 !~ /^#/ && $3 == "mergerfs" { found=1 } END { exit !found }' /etc/fstab 2>/dev/null; then
    check_fail "mount -a skipped because /etc/fstab still contains mergerfs entries that can stack FUSE mounts"
    return 0
  fi
  output="$(systemctl daemon-reload 2>&1)" || check_fail "systemctl daemon-reload"
  output="$(mount -a 2>&1)" && status=0 || status=$?
  if [[ "$status" -eq 0 && "$output" != *"Unknown parameter 'category.create'"* && "$output" != *"Unknown parameter 'fsname'"* && "$output" != *"Transport endpoint is not connected"* ]]; then
    check_pass "mount -a succeeds"
  else
    printf '%s\n' "$output"
    check_fail "mount -a succeeds"
  fi
  output="$(findmnt --verify 2>&1)" && status=0 || status=$?
  printf '%s\n' "$output"
  if [[ "$status" -eq 0 && "$output" != *"Unknown parameter 'category.create'"* && "$output" != *"Unknown parameter 'fsname'"* && "$output" != *"Transport endpoint is not connected"* ]]; then
    check_pass "findmnt --verify has no errors"
  else
    check_fail "findmnt --verify has no errors"
  fi
  check_mount_count_one "$MERGERFS_MOUNT"
  check_mount_count_one "$SNAPSHOT_VIEW_MOUNT"
}

check_live_target() {
  CHECK_PASS=0
  CHECK_WARN=0
  CHECK_FAIL=0
  TARGET_MODE="live"
  printf 'Running live target check.\nTarget root: %s\nData path: %s\nSnapshot view: %s\n' "$TARGET_ROOT" "$(active_mount_path "$MERGERFS_MOUNT")" "$(active_mount_path "$SNAPSHOT_VIEW_MOUNT")"
  [[ "$TARGET_ROOT" != "/" ]] && check_pass "TARGET_ROOT is not /" || check_fail "TARGET_ROOT is not /"
  [[ -d /run/archiso ]] && check_pass "running from Arch ISO" || check_warn "not obviously running from Arch ISO"
  command -v arch-chroot >/dev/null 2>&1 && check_pass "arch-chroot available for live target checks" || check_fail "arch-chroot available for live target checks"
  findmnt "$TARGET_ROOT" >/dev/null 2>&1 && check_pass "$TARGET_ROOT is mounted" || check_fail "$TARGET_ROOT is mounted"
  ensure_live_mergerfs_healthy
  check_mount_exists "$(target_path /boot)"
  check_common_os_mounts
  check_common_data_mounts
  check_common_pool_dirs
  check_common_fstab "$(target_path /etc/fstab)"
  check_common_packages
  check_common_grub_snapper
  check_common_docker
  check_common_pc_worker_orchestration
  check_common_snapraid_btrbk_samba
  check_common_services
  print_check_summary
}

check_health() {
  CHECK_PASS=0
  CHECK_WARN=0
  CHECK_FAIL=0
  TARGET_MODE="host"
  printf 'Running installed-system health check.\nRoot path: /\nData path: %s\nSnapshot view: %s\n' "$MERGERFS_MOUNT" "$SNAPSHOT_VIEW_MOUNT"
  [[ ! -d /run/archiso ]] && check_pass "not running from Arch ISO" || check_fail "--check-health must run from installed NAS OS, not Arch ISO"
  check_path_exists /etc/fstab
  check_path_exists /boot/grub/grub.cfg
  [[ "$(hostname)" == "$NAS_HOSTNAME" ]] && check_pass "hostname matches $NAS_HOSTNAME" || check_fail "hostname matches $NAS_HOSTNAME"
  id "$NAS_USER" >/dev/null 2>&1 && check_pass "$NAS_USER exists" || check_fail "$NAS_USER exists"
  getent group "$NAS_GROUP" >/dev/null 2>&1 && check_pass "$NAS_GROUP group exists" || check_fail "$NAS_GROUP group exists"
  id -nG "$NAS_USER" 2>/dev/null | grep -Eq "(^| )wheel( |$)" && check_pass "$NAS_USER is in wheel" || check_fail "$NAS_USER is in wheel"
  id -nG "$NAS_USER" 2>/dev/null | grep -Eq "(^| )docker( |$)" && check_pass "$NAS_USER is in docker" || check_fail "$NAS_USER is in docker"
  id -nG "$NAS_USER" 2>/dev/null | grep -Eq "(^| )$NAS_GROUP( |$)" && check_pass "$NAS_USER is in $NAS_GROUP" || check_fail "$NAS_USER is in $NAS_GROUP"
  check_device_fstype_label "$EFI_PARTITION" vfat "" "$EFI_PARTITION"
  check_device_fstype_label "$ROOT_PARTITION" btrfs arch-root "$ROOT_PARTITION"
  local idx
  for idx in "${!DATA_DISKS[@]}"; do
    check_device_fstype_label "${DATA_DISKS[$idx]}" btrfs "${DATA_DISK_LABELS[$idx]}" "${DATA_DISKS[$idx]}"
  done
  check_device_fstype_label "$PARITY_DISK" ext4 "$PARITY_LABEL" "$PARITY_DISK"
  check_common_os_mounts
  check_mount_exists /boot
  check_common_data_mounts
  check_common_pool_dirs
  check_common_fstab /etc/fstab
  check_mount_a_and_findmnt_verify
  check_common_packages
  check_common_grub_snapper
  check_common_docker
  check_common_pc_worker_orchestration
  check_common_snapraid_btrbk_samba
  check_common_services
  print_check_summary
}
