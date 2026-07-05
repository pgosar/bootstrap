CHECK_PASS=0
CHECK_WARN=0
CHECK_FAIL=0

check_pass() { printf '[PASS] %s\n' "$*"; CHECK_PASS=$((CHECK_PASS + 1)); }
check_warn() { printf '[WARN] %s\n' "$*"; CHECK_WARN=$((CHECK_WARN + 1)); }
check_fail() { printf '[FAIL] %s\n' "$*"; CHECK_FAIL=$((CHECK_FAIL + 1)); }

print_check_summary() {
  printf '\nPC check summary\n'
  printf '================\n'
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

check_file_exists() {
  local path="$1"
  [[ -e "$path" ]] && check_pass "$path exists" || check_fail "$path exists"
}

check_file_contains() {
  local file="$1" pattern="$2" desc="$3"
  if [[ -f "$file" ]] && grep -Fq "$pattern" "$file"; then
    check_pass "$desc"
  else
    check_fail "$desc"
  fi
}

check_file_not_contains() {
  local file="$1" pattern="$2" desc="$3"
  if [[ -f "$file" ]] && grep -Fq "$pattern" "$file"; then
    check_fail "$desc"
  else
    check_pass "$desc"
  fi
}

check_command_success() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    check_pass "$desc"
  else
    check_fail "$desc"
  fi
}

check_target_success() {
  local desc="$1"
  shift
  if check_run_target "$@" >/dev/null 2>&1; then
    check_pass "$desc"
  else
    check_fail "$desc"
  fi
}

check_mount_present() {
  local path="$1"
  if findmnt "$path" >/dev/null 2>&1; then
    check_pass "$path is mounted"
  else
    check_fail "$path is mounted"
  fi
}

check_single_mount_at_path() {
  local path="$1" count
  count="$(findmnt -rn "$path" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" == "1" ]]; then
    check_pass "$path has exactly one mount"
  else
    check_fail "$path has exactly one mount (found $count)"
  fi
}

check_mount_fstype() {
  local path="$1" expected="$2" actual
  actual="$(findmnt -n -o FSTYPE "$path" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    check_pass "$path fstype is $expected"
  else
    check_fail "$path fstype is $expected (actual: ${actual:-missing})"
  fi
}

check_mount_option_contains_any() {
  local path="$1"
  shift
  local options needle
  options="$(findmnt -n -o OPTIONS "$path" 2>/dev/null || true)"
  for needle in "$@"; do
    if [[ "$options" == *"$needle"* ]]; then
      check_pass "$path options contain $needle"
      return 0
    fi
  done
  check_fail "$path options contain one of: $*"
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

check_fstab_has_subvol() {
  local fstab="$1" mountpoint="$2" subvol="$3"
  if awk -v mp="$mountpoint" -v sv="subvol=$subvol" -v sv_abs="subvol=/"$subvol '
      $1 !~ /^#/ && $2 == mp && ($4 ~ sv || $4 ~ sv_abs) { found=1 }
      END { exit !found }
    ' "$fstab"; then
    check_pass "fstab maps $mountpoint to subvol=$subvol"
  else
    check_fail "fstab maps $mountpoint to subvol=$subvol"
  fi
}

check_block_fstype_label() {
  local device="$1" expected_type="$2" expected_label="$3" actual_type actual_label
  actual_type="$(blkid -s TYPE -o value "$device" 2>/dev/null || true)"
  actual_label="$(blkid -s LABEL -o value "$device" 2>/dev/null || true)"
  if [[ "$actual_type" == "$expected_type" ]]; then
    check_pass "$device fstype is $expected_type"
  else
    check_fail "$device fstype is $expected_type (actual: ${actual_type:-missing})"
  fi
  if [[ "$actual_label" == "$expected_label" ]]; then
    check_pass "$device label is $expected_label"
  else
    check_fail "$device label is $expected_label (actual: ${actual_label:-missing})"
  fi
}

check_user_group_membership() {
  local user="$1"
  shift
  local expected group_list
  group_list="$(id -nG "$user" 2>/dev/null || true)"
  for expected in "$@"; do
    if [[ " $group_list " == *" $expected "* ]]; then
      check_pass "$user is in group $expected"
    else
      check_fail "$user is in group $expected"
    fi
  done
}

check_package_installed() {
  local package="$1"
  if check_run_target pacman -Q "$package" >/dev/null 2>&1; then
    check_pass "$package package installed"
  else
    check_fail "$package package installed"
  fi
}

check_package_version() {
  local package="$1" expected="$2" actual
  if [[ -z "$expected" ]]; then
    return 0
  fi
  actual="$(check_run_target pacman -Q "$package" 2>/dev/null | awk '{print $2}' || true)"
  if [[ "$actual" == "$expected" ]]; then
    check_pass "$package package version is $expected"
  else
    check_warn "$package package version drift: expected $expected, actual ${actual:-missing}"
  fi
}

check_packages_from_file() {
  local file="$1" package version line
  [[ -f "$file" ]] || {
    check_fail "package manifest exists: $file"
    return 0
  }
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    package="${line%%[[:space:]]*}"
    version=""
    if [[ "$line" == *[[:space:]]* ]]; then
      version="${line#"$package"}"
      version="${version#"${version%%[![:space:]]*}"}"
      version="${version%%#*}"
      version="${version%"${version##*[![:space:]]}"}"
    fi
    check_package_installed "$package"
    check_package_version "$package" "$version"
  done <"$file"
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

check_unit_active_host() {
  local unit="$1" required="${2:-true}"
  if systemctl is-active "$unit" >/dev/null 2>&1; then
    check_pass "$unit active"
  elif [[ "$required" == "true" ]]; then
    check_fail "$unit active"
  else
    check_warn "$unit not active"
  fi
}

check_root_mounts() {
  local prefix="$1"
  local root home root_home srv cache tmp log snapshots boot
  if [[ -z "$prefix" ]]; then
    root="/"
    home="/home"
    root_home="/root"
    srv="/srv"
    cache="/var/cache"
    tmp="/var/tmp"
    log="/var/log"
    snapshots="/.snapshots"
    boot="/boot/efi"
  else
    root="$prefix"
    home="$prefix/home"
    root_home="$prefix/root"
    srv="$prefix/srv"
    cache="$prefix/var/cache"
    tmp="$prefix/var/tmp"
    log="$prefix/var/log"
    snapshots="$prefix/.snapshots"
    boot="$prefix/boot/efi"
  fi

  check_mount_present "$root"
  check_mount_present "$home"
  check_mount_present "$root_home"
  check_mount_present "$srv"
  check_mount_present "$cache"
  check_mount_present "$tmp"
  check_mount_present "$log"
  check_mount_present "$snapshots"
  check_mount_present "$boot"

  check_single_mount_at_path "$root"
  check_single_mount_at_path "$home"
  check_single_mount_at_path "$root_home"
  check_single_mount_at_path "$srv"
  check_single_mount_at_path "$cache"
  check_single_mount_at_path "$tmp"
  check_single_mount_at_path "$log"
  check_single_mount_at_path "$snapshots"
  check_single_mount_at_path "$boot"

  check_mount_fstype "$root" btrfs
  check_mount_fstype "$home" btrfs
  check_mount_fstype "$root_home" btrfs
  check_mount_fstype "$srv" btrfs
  check_mount_fstype "$cache" btrfs
  check_mount_fstype "$tmp" btrfs
  check_mount_fstype "$log" btrfs
  check_mount_fstype "$snapshots" btrfs
  check_mount_fstype "$boot" vfat

  check_mount_option_contains_any "$root" "subvol=@" "subvol=/@"
  check_mount_option_contains_any "$home" "subvol=@home" "subvol=/@home"
  check_mount_option_contains_any "$root_home" "subvol=@root" "subvol=/@root"
  check_mount_option_contains_any "$srv" "subvol=@srv" "subvol=/@srv"
  check_mount_option_contains_any "$cache" "subvol=@cache" "subvol=/@cache"
  check_mount_option_contains_any "$tmp" "subvol=@tmp" "subvol=/@tmp"
  check_mount_option_contains_any "$log" "subvol=@log" "subvol=/@log"
  check_mount_option_contains_any "$snapshots" "subvol=@snapshots" "subvol=/@snapshots"
}

check_core_fstab() {
  local fstab="$1"
  check_file_exists "$fstab"
  check_file_not_contains "$fstab" "fuse.mergerfs" "$fstab does not contain fuse.mergerfs"
  check_file_not_contains "$fstab" "fsname=mergerfs" "$fstab does not contain fsname=mergerfs"
  check_file_not_contains "$fstab" "/mnt/mnt/" "$fstab does not contain live-target paths"

  check_fstab_has_subvol "$fstab" / @
  check_fstab_has_subvol "$fstab" /home @home
  check_fstab_has_subvol "$fstab" /root @root
  check_fstab_has_subvol "$fstab" /srv @srv
  check_fstab_has_subvol "$fstab" /var/cache @cache
  check_fstab_has_subvol "$fstab" /var/tmp @tmp
  check_fstab_has_subvol "$fstab" /var/log @log
  check_fstab_has_subvol "$fstab" /.snapshots @snapshots

  check_no_duplicate_fstab_mount "$fstab" /
  check_no_duplicate_fstab_mount "$fstab" /home
  check_no_duplicate_fstab_mount "$fstab" /root
  check_no_duplicate_fstab_mount "$fstab" /srv
  check_no_duplicate_fstab_mount "$fstab" /var/cache
  check_no_duplicate_fstab_mount "$fstab" /var/tmp
  check_no_duplicate_fstab_mount "$fstab" /var/log
  check_no_duplicate_fstab_mount "$fstab" /.snapshots
  check_no_duplicate_fstab_mount "$fstab" /boot/efi
}

check_grub_and_snapper_files() {
  local root_prefix="$1" grub snapper confd
  grub="$root_prefix/boot/grub/grub.cfg"
  snapper="$root_prefix/etc/snapper/configs/root"
  confd="$root_prefix/etc/conf.d/snapper"

  check_file_exists "$grub"
  check_file_contains "$grub" "amd-ucode.img" "GRUB config references AMD microcode"
  check_file_contains "$grub" "rootflags=subvol=@" "GRUB config uses rootflags=subvol=@"
  if grep -Eiq 'snapshot|snapper|grub-btrfs' "$grub" 2>/dev/null; then
    check_pass "GRUB config has snapshot-related entries"
  else
    check_warn "GRUB config has no snapshot menu entries yet"
  fi

  check_file_exists "$snapper"
  check_file_contains "$snapper" 'SUBVOLUME="/"' "Snapper root config targets /"
  check_file_contains "$snapper" 'FSTYPE="btrfs"' "Snapper root config uses btrfs"
  check_file_contains "$snapper" 'NUMBER_CLEANUP="yes"' "Snapper number cleanup enabled"
  check_file_contains "$snapper" 'NUMBER_LIMIT="50"' "Snapper number limit matches host"
  check_file_contains "$snapper" 'NUMBER_LIMIT_IMPORTANT="15"' "Snapper important limit matches host"
  check_file_contains "$snapper" 'TIMELINE_CREATE="no"' "Snapper timeline creation matches host"
  check_file_contains "$snapper" 'TIMELINE_CLEANUP="yes"' "Snapper timeline cleanup enabled"
  check_file_not_contains "$snapper" "/data" "Snapper root config does not reference /data"
  check_file_exists "$confd"
  check_file_contains "$confd" 'SNAPPER_CONFIGS="root"' "Snapper configs are enabled"
}

check_expected_services_enabled() {
  [[ "$ENABLE_NETWORKMANAGER" == "true" ]] && check_unit_enabled NetworkManager
  [[ "$ENABLE_BLUETOOTH" == "true" ]] && check_unit_enabled bluetooth
  [[ "$ENABLE_LIBVIRTD" == "true" ]] && check_unit_enabled libvirtd
  [[ "$ENABLE_LY" == "true" ]] && check_unit_enabled "$LY_UNIT"
  [[ "$ENABLE_UFW" == "true" ]] && check_unit_enabled ufw
  [[ "$ENABLE_AVAHI" == "true" ]] && check_unit_enabled avahi-daemon
  [[ "$ENABLE_SYSTEMD_RESOLVED" == "true" ]] && check_unit_enabled systemd-resolved
  [[ "$ENABLE_SYSTEMD_TIMESYNCD" == "true" ]] && check_unit_enabled systemd-timesyncd
  check_unit_enabled sshd
  [[ "$ENABLE_FSTRIM_TIMER" == "true" ]] && check_unit_enabled fstrim.timer
  check_unit_enabled snapper-cleanup.timer
  check_unit_enabled snapper-timeline.timer false
  [[ "$ENABLE_SMARTD" == "true" ]] && check_unit_enabled smartd
  [[ "$ENABLE_NFTABLES" == "true" ]] && check_unit_enabled nftables
  return 0
}

check_health_active_services() {
  [[ "$ENABLE_NETWORKMANAGER" == "true" ]] && check_unit_active_host NetworkManager
  [[ "$ENABLE_SYSTEMD_RESOLVED" == "true" ]] && check_unit_active_host systemd-resolved
  [[ "$ENABLE_SYSTEMD_TIMESYNCD" == "true" ]] && check_unit_active_host systemd-timesyncd
  check_unit_active_host sshd
  [[ "$ENABLE_UFW" == "true" ]] && check_unit_active_host ufw
  [[ "$ENABLE_BLUETOOTH" == "true" ]] && check_unit_active_host bluetooth false
  [[ "$ENABLE_LIBVIRTD" == "true" ]] && check_unit_active_host libvirtd false
  [[ "$ENABLE_AVAHI" == "true" ]] && check_unit_active_host avahi-daemon false
  return 0
}

check_live_target() {
  TARGET_MODE="live"
  require_root
  [[ "$TARGET_ROOT" != "/" ]] || check_fail "TARGET_ROOT is not /"
  [[ -d /run/archiso ]] || check_warn "not obviously running from Arch ISO"
  command -v arch-chroot >/dev/null 2>&1 && check_pass "arch-chroot available" || check_fail "arch-chroot available"
  findmnt "$TARGET_ROOT" >/dev/null 2>&1 && check_pass "$TARGET_ROOT is mounted" || check_fail "$TARGET_ROOT is mounted"

  local target_fstab
  target_fstab="$(target_path /etc/fstab)"
  check_root_mounts "$TARGET_ROOT"
  check_core_fstab "$target_fstab"
  check_file_contains "$(target_path /etc/hostname)" "$PC_HOSTNAME" "target hostname configured"
  check_grub_and_snapper_files "$TARGET_ROOT"
  check_packages_from_file "$PACKAGE_FILE"
  check_package_installed yay
  check_packages_from_file "$AUR_PACKAGE_FILE"
  check_expected_services_enabled
  check_target_success "snapper root config usable" snapper --no-dbus -c root list
  check_target_success "user $PC_USER exists in target" id "$PC_USER"
  check_target_success "group wheel exists in target" getent group wheel
  print_check_summary
}

check_health() {
  TARGET_MODE="host"
  require_root
  [[ ! -d /run/archiso ]] || check_fail "--check-health must run from installed host, not Arch ISO"

  local check_log_dir="/var/log/pc-bootstrap/checks"
  mkdir -p "$check_log_dir"
  systemctl daemon-reload >/dev/null 2>&1 || true
  local attempt
  for attempt in 1 2 3; do
    if mount -a >>"$check_log_dir/mount-a.log" 2>&1; then
      check_pass "mount -a pass $attempt completed successfully"
    else
      check_fail "mount -a pass $attempt completed successfully"
    fi
  done
  if grep -Eq "Unknown parameter|Transport endpoint is not connected" "$check_log_dir/mount-a.log" 2>/dev/null; then
    check_fail "mount -a log has no fatal mount errors"
  else
    check_pass "mount -a log has no fatal mount errors"
  fi
  if findmnt --verify >"$check_log_dir/findmnt-verify.log" 2>&1; then
    check_pass "findmnt --verify completed successfully"
  else
    check_fail "findmnt --verify completed successfully"
  fi

  check_block_fstype_label "$EFI_PARTITION" vfat ""
  check_block_fstype_label "$ROOT_PARTITION" btrfs arch-root
  check_root_mounts ""
  check_core_fstab /etc/fstab
  check_grub_and_snapper_files ""
  check_packages_from_file "$PACKAGE_FILE"
  check_package_installed yay
  check_packages_from_file "$AUR_PACKAGE_FILE"
  check_expected_services_enabled
  check_health_active_services

  if hostnamectl --static | grep -qx "$PC_HOSTNAME"; then
    check_pass "hostname matches expected value"
  else
    check_fail "hostname matches expected value"
  fi
  if id "$PC_USER" >/dev/null 2>&1; then
    check_pass "$PC_USER user exists"
    check_user_group_membership "$PC_USER" "${USER_SUPPLEMENTAL_GROUPS[@]}"
  else
    check_fail "$PC_USER user exists"
  fi
  getent group "$PC_USER" >/dev/null 2>&1 && check_pass "$PC_USER primary group exists" || check_fail "$PC_USER primary group exists"
  check_command_success "snapper root config usable" snapper --no-dbus -c root list

  print_check_summary
}
