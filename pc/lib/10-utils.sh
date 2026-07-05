log() { printf '[pc-bootstrap] %s\n' "$*"; }
warn() { printf '[pc-bootstrap] WARNING: %s\n' "$*" >&2; }
die() { printf '[pc-bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }
check_pass() { printf '[PASS] %s\n' "$*"; }
check_warn() { printf '[WARN] %s\n' "$*"; }
check_fail() { printf '[FAIL] %s\n' "$*"; }

quote_cmd() { printf '%q ' "$@"; }

usage() {
  cat <<EOF
Reproducible PC bootstrap for the current Arch-based host profile.

Usage:
  pc/bin/bootstrap-pc.sh [options]

Core modes:
  --dry-run              Print planned actions only.
  --apply                Allow selected phases to mutate the system.
  --init-env             Copy .env.example to .env without overwriting.
  --list-disks           Read-only inventory of disks and by-id hints.
  --install-arch         Install Arch to the target disk from the live ISO.
  --partition-os-disk    Allow destructive OS-disk partitioning.
  --packages             Install the host package set into the target.
  --services             Write host service/configuration files.
  --enable-services      Enable systemd units/timers in the target.
  --start-services       Start enabled services on the current host.
  --all                  In live mode: full install + packages + services.
                        In host mode: packages + services + enable-services.

Checks:
  --check-live-target     Read-only check from the Arch ISO against TARGET_ROOT.
  --check-health          Read-only check after rebooting into the installed host.
  --checkhealth           Alias for --check-health.

Overrides:
  --env-file PATH
  --target-mode host|live
  --target-root PATH
  --os-disk PATH
  --efi-partition PATH
  --root-partition PATH

Examples:
  pc/bin/bootstrap-pc.sh --init-env
  sudo pc/bin/bootstrap-pc.sh --dry-run --all
  sudo pc/bin/bootstrap-pc.sh --apply --all
  sudo pc/bin/bootstrap-pc.sh --env-file pc/.env --check-live-target
  sudo pc/bin/bootstrap-pc.sh --env-file pc/.env --check-health
EOF
}

require_root() { [[ "$(id -u)" == "0" ]] || die "this phase must be run as root"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

run() {
  log "+ $(quote_cmd "$@")"
  if [[ "$APPLY" == true ]]; then
    "$@"
  fi
}

run_capture() {
  log "+ $(quote_cmd "$@")"
  if [[ "$APPLY" == true ]]; then
    "$@"
  fi
}

target_path() {
  local path="$1"
  case "$TARGET_MODE" in
    host) printf '%s\n' "$path" ;;
    live)
      [[ "$path" == /* ]] || die "target_path requires an absolute path: $path"
      printf '%s%s\n' "$TARGET_ROOT" "$path"
      ;;
    *) die "invalid TARGET_MODE: $TARGET_MODE" ;;
  esac
}

active_path() { target_path "$1"; }

target_run() {
  if [[ "$TARGET_MODE" == "live" ]]; then
    run arch-chroot "$TARGET_ROOT" "$@"
  else
    run "$@"
  fi
}

target_exec() {
  if [[ "$TARGET_MODE" == "live" ]]; then
    arch-chroot "$TARGET_ROOT" "$@"
  else
    "$@"
  fi
}

target_unit_available() {
  local unit="$1" template output
  if [[ "$TARGET_MODE" == "live" ]]; then
    output="$(systemctl --root="$TARGET_ROOT" list-unit-files "$unit" --no-legend 2>/dev/null || true)"
  else
    output="$(systemctl list-unit-files "$unit" --no-legend 2>/dev/null || true)"
  fi
  if [[ -z "$output" && "$unit" != *.* ]]; then
    if [[ "$TARGET_MODE" == "live" ]]; then
      output="$(systemctl --root="$TARGET_ROOT" list-unit-files "$unit.service" --no-legend 2>/dev/null || true)"
    else
      output="$(systemctl list-unit-files "$unit.service" --no-legend 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$output" && "$unit" == *@*.* ]]; then
    template="${unit%@*}@.${unit##*.}"
    if [[ "$TARGET_MODE" == "live" ]]; then
      output="$(systemctl --root="$TARGET_ROOT" list-unit-files "$template" --no-legend 2>/dev/null || true)"
    else
      output="$(systemctl list-unit-files "$template" --no-legend 2>/dev/null || true)"
    fi
  fi
  [[ -n "$output" ]]
}

enable_target_unit() {
  local unit="$1"
  local required="${2:-true}"

  if [[ "$APPLY" != true ]]; then
    log "+ enable unit $(printf '%q' "$unit")"
    return 0
  fi

  if ! target_unit_available "$unit"; then
    if [[ "$required" == "true" ]]; then
      die "required systemd unit is not available in target: $unit"
    fi
    warn "optional systemd unit is not available in target; skipping enable: $unit"
    return 0
  fi

  log "+ enable unit $(printf '%q' "$unit")"
  if [[ "$TARGET_MODE" == "live" ]]; then
    systemctl --root="$TARGET_ROOT" enable "$unit"
  elif ! systemctl enable "$unit"; then
    if [[ "$required" == "true" ]]; then
      die "failed to enable required systemd unit: $unit"
    fi
    warn "failed to enable optional systemd unit: $unit"
  fi
}

start_target_unit() {
  local unit="$1"
  local required="${2:-true}"

  if [[ "$APPLY" != true ]]; then
    log "+ start unit $(printf '%q' "$unit")"
    return 0
  fi

  if ! target_unit_available "$unit"; then
    if [[ "$required" == "true" ]]; then
      die "required systemd unit is not available in target: $unit"
    fi
    warn "optional systemd unit is not available in target; skipping start: $unit"
    return 0
  fi

  log "+ start unit $(printf '%q' "$unit")"
  if ! target_exec systemctl start "$unit"; then
    if [[ "$required" == "true" ]]; then
      die "failed to start required systemd unit: $unit"
    fi
    warn "failed to start optional systemd unit: $unit"
  fi
}

target_run_capture() {
  if [[ "$TARGET_MODE" == "live" ]]; then
    run_capture arch-chroot "$TARGET_ROOT" "$@"
  else
    run_capture "$@"
  fi
}

check_run_target() {
  if [[ "$TARGET_MODE" == "live" ]]; then
    arch-chroot "$TARGET_ROOT" "$@"
  else
    "$@"
  fi
}

check_run_target_capture() {
  if [[ "$TARGET_MODE" == "live" ]]; then
    arch-chroot "$TARGET_ROOT" "$@"
  else
    "$@"
  fi
}

ensure_dir() {
  local dir="$1"
  if [[ "$APPLY" == true ]]; then
    mkdir -p "$dir"
  else
    log "+ mkdir -p $(printf '%q' "$dir")"
  fi
}

ensure_safe_mountpoint() {
  local path="$1"
  ensure_dir "$path"
  if [[ "$APPLY" == true ]] && [[ -d "$path" ]] && ! mountpoint -q "$path"; then
    if find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      die "$path exists, is not a mountpoint, and is not empty; refusing to mount over it"
    fi
  fi
}

backup_file() {
  local file="$1"
  [[ -e "$file" ]] || return 0
  local backup="${file}.backup.$(date +%Y%m%d-%H%M%S)"
  log "Backing up $file to $backup"
  if [[ "$APPLY" == true ]]; then
    cp -a "$file" "$backup"
  fi
}

write_text() {
  local path="$1"
  local content="$2"
  log "+ write $(printf '%q' "$path")"
  if [[ "$APPLY" == true ]]; then
    ensure_dir "$(dirname "$path")"
    printf '%s\n' "$content" >"$path"
  fi
}

copy_with_backup() {
  local src="$1"
  local dest="$2"
  backup_file "$dest"
  log "+ install $(printf '%q' "$src") -> $(printf '%q' "$dest")"
  if [[ "$APPLY" == true ]]; then
    ensure_dir "$(dirname "$dest")"
    cp -a "$src" "$dest"
  fi
}

init_env() {
  [[ -f "$EXAMPLE_ENV_FILE" ]] || die "missing template: $EXAMPLE_ENV_FILE"
  [[ ! -e "$DEFAULT_ENV_FILE" ]] || die "$DEFAULT_ENV_FILE already exists; refusing to overwrite"
  cp "$EXAMPLE_ENV_FILE" "$DEFAULT_ENV_FILE"
  printf 'Created .env from .env.example.\nEdit .env before running mutating phases.\n'
}

load_package_lists() {
  PACMAN_PACKAGES=()
  AUR_PACKAGES=()
  AUR_PACKAGE_VERSIONS=()
  local file line package version
  if [[ -f "$PACKAGE_FILE" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != \#* ]] || continue
      package="${line%%[[:space:]]*}"
      PACMAN_PACKAGES+=("$package")
    done <"$PACKAGE_FILE"
  fi
  if [[ -f "$AUR_PACKAGE_FILE" ]]; then
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
      AUR_PACKAGES+=("$package")
      [[ -n "$version" ]] && AUR_PACKAGE_VERSIONS["$package"]="$version"
    done <"$AUR_PACKAGE_FILE"
  fi
}

is_placeholder() {
  local value="${1:-}"
  [[ -z "$value" || "$value" == *REPLACE_ME* || "$value" == *CHANGEME* || "$value" == *TODO* || "$value" == *example* ]]
}

require_non_placeholder_var() {
  local name="$1"
  local value="${!name:-}"
  if is_placeholder "$value"; then
    die "required config value is missing or still a placeholder: $name"
  fi
}

require_non_placeholder_array() {
  local name="$1" value count idx
  eval "count=\${#$name[@]}"
  [[ "$count" -gt 0 ]] || die "required config array is empty: $name"
  for ((idx = 0; idx < count; idx++)); do
    eval "value=\${$name[$idx]}"
    if is_placeholder "$value"; then
      die "required config array contains placeholder: $name[$idx]=$value"
    fi
  done
}

device_identity() {
  local path="$1"
  if [[ -e "$path" ]]; then
    readlink -f "$path" 2>/dev/null || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
}

paths_same_device() {
  local left="$1" right="$2"
  [[ "$(device_identity "$left")" == "$(device_identity "$right")" ]]
}

allow_raw_path() {
  local path="$1"
  [[ "$ALLOW_RAW_DEV_PATHS" == "true" ]] && return 0
  [[ "$ALLOW_QEMU_DEVICE_NAMES" == "true" && "$path" =~ ^/dev/vd[a-z]([0-9]+)?$ ]] && return 0
  [[ "$ALLOW_QEMU_DEVICE_NAMES" == "true" && "$path" =~ ^/dev/disk/by-id/virtio- ]] && return 0
  return 1
}

validate_device_path_safety() {
  local name="$1" path="$2"
  is_placeholder "$path" && die "$name is still a placeholder: $path"
  if [[ "$path" == /dev/disk/by-id/* ]]; then
    return 0
  fi
  if [[ "$path" =~ ^/dev/(sd[a-z][0-9]*|vd[a-z][0-9]*|nvme[0-9]+n[0-9]+p?[0-9]*)$ ]]; then
    allow_raw_path "$path" || die "$name must use /dev/disk/by-id/... on real hardware: $path"
    return 0
  fi
  warn "$name is not a /dev/disk/by-id path; verify it is stable: $path"
}

validate_device_exists_or_expected() {
  local name="$1" path="$2" may_be_created="${3:-false}"
  if [[ -e "$path" ]]; then
    return 0
  fi
  if [[ "$may_be_created" == "true" ]]; then
    warn "$name does not exist yet and is expected to be created by partitioning: $path"
    return 0
  fi
  die "$name does not exist: $path"
}

preferred_by_id_for_disk() {
  local disk="$1" candidate resolved base priority best="" best_priority=99
  for candidate in /dev/disk/by-id/*; do
    [[ -e "$candidate" && "$candidate" != *-part* ]] || continue
    resolved="$(readlink -f "$candidate" 2>/dev/null || true)"
    [[ "$resolved" == "$disk" ]] || continue
    base="$(basename -- "$candidate")"
    case "$base" in
      wwn-*) priority=1 ;;
      nvme-eui.*) priority=2 ;;
      nvme-uuid.*) priority=3 ;;
      nvme-*) priority=4 ;;
      ata-*) priority=5 ;;
      scsi-*) priority=6 ;;
      *) priority=7 ;;
    esac
    if (( priority < best_priority )); then
      best="$candidate"
      best_priority="$priority"
    fi
  done
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

list_disks() {
  require_cmd lsblk
  printf 'PC bootstrap disk inventory (read-only)\n\n'
  local disk size model serial tran rota rm ro fstype label uuid mountpoints byid preferred
  while IFS= read -r disk; do
    [[ -b "$disk" ]] || continue
    size="$(lsblk -dn -o SIZE "$disk" 2>/dev/null | awk '{$1=$1; print}')"
    model="$(lsblk -dn -o MODEL "$disk" 2>/dev/null | sed 's/[[:space:]]*$//')"
    serial="$(lsblk -dn -o SERIAL "$disk" 2>/dev/null | sed 's/[[:space:]]*$//')"
    tran="$(lsblk -dn -o TRAN "$disk" 2>/dev/null | awk '{$1=$1; print}')"
    rota="$(lsblk -dn -o ROTA "$disk" 2>/dev/null | awk '{$1=$1; print}')"
    rm="$(lsblk -dn -o RM "$disk" 2>/dev/null | awk '{$1=$1; print}')"
    ro="$(lsblk -dn -o RO "$disk" 2>/dev/null | awk '{$1=$1; print}')"
    fstype="$(lsblk -dn -o FSTYPE "$disk" 2>/dev/null | awk '{$1=$1; print}')"
    label="$(lsblk -dn -o LABEL "$disk" 2>/dev/null | sed 's/[[:space:]]*$//')"
    uuid="$(lsblk -dn -o UUID "$disk" 2>/dev/null | awk '{$1=$1; print}')"
    mountpoints="$(lsblk -nr -o MOUNTPOINTS "$disk" 2>/dev/null | awk 'NF' | paste -sd ', ' -)"
    preferred="$(preferred_by_id_for_disk "$disk" || true)"
    printf 'Disk: %s\n' "$disk"
    printf 'Kernel device: %s\n' "$disk"
    printf 'Size: %s\n' "${size:-unknown}"
    printf 'Model: %s\n' "${model:-unknown}"
    printf 'Serial: %s\n' "${serial:-unknown}"
    printf 'Transport: %s\n' "${tran:-unknown}"
    printf 'Rotational: %s\n' "${rota:-unknown}"
    printf 'Removable: %s\n' "${rm:-unknown}"
    printf 'Read-only: %s\n' "${ro:-unknown}"
    printf 'Filesystem: %s\n' "${fstype:-none}"
    printf 'Label: %s\n' "${label:-none}"
    printf 'UUID: %s\n' "${uuid:-none}"
    printf 'Mountpoints: %s\n' "${mountpoints:-none}"
    printf 'Preferred by-id path: %s\n' "${preferred:-none}"
    if [[ -n "$preferred" ]]; then
      printf 'by-id candidate: %s\n' "$preferred"
    fi
    printf 'Suggested OS config:\n'
    printf '  OS_DISK="%s"\n' "${preferred:-$disk}"
    printf '  EFI_PARTITION="%s-part1"\n' "${preferred:-$disk}"
    printf '  ROOT_PARTITION="%s-part2"\n' "${preferred:-$disk}"
    printf '\n'
  done < <(lsblk -dn -o PATH,TYPE | awk '$2 == "disk" { print $1 }')
}

print_config_summary() {
  printf 'PC bootstrap config summary:\n\n'
  printf 'Target mode: %s\n' "$TARGET_MODE"
  printf 'Target root: %s\n' "$TARGET_ROOT"
  printf 'Hostname: %s\n' "$PC_HOSTNAME"
  printf 'User: %s\n' "$PC_USER"
  printf 'Bootloader: %s\n' "$BOOTLOADER"
  printf 'OS disk: %s\n' "$OS_DISK"
  printf 'EFI partition: %s\n' "$EFI_PARTITION"
  printf 'Root partition: %s\n' "$ROOT_PARTITION"
  printf 'Packages file: %s\n' "$PACKAGE_FILE"
  printf 'AUR packages file: %s\n' "$AUR_PACKAGE_FILE"
  printf '\n'
}

confirm_destructive() {
  local reason="$1"
  shift
  [[ "$APPLY" == true ]] || return 0
  [[ "$DESTRUCTIVE_CONFIRMED" == true ]] && return 0
  printf '\n================================================================================\n'
  printf '%s\n' "$reason"
  printf '================================================================================\n\n'
  printf 'Type exactly this phrase to continue:\n\n  %s\n\n' "$CONFIRM_PHRASE"
  read -r response
  [[ "$response" == "$CONFIRM_PHRASE" ]] || die "destructive confirmation failed"
  DESTRUCTIVE_CONFIRMED=true
}

write_fresh_install_fstab() {
  local target_root="$1" fstab="$target_root/etc/fstab"
  log "+ generate fresh install fstab at $fstab"
  if [[ "$APPLY" == true ]]; then
    [[ -e "$fstab" ]] && backup_file "$fstab"
    genfstab -U "$target_root" >"$fstab"
  else
    log "+ genfstab -U $(printf '%q' "$target_root") > $(printf '%q' "$fstab")"
  fi
}

check_pacman_packages_available() {
  local package
  for package in "$@"; do
    if ! pacman -Si "$package" >/dev/null 2>&1; then
      die "official package is not available in configured pacman repos: $package"
    fi
  done
}

check_target_pacman_packages_available() {
  local package
  for package in "$@"; do
    if ! check_run_target_package_available "$package"; then
      die "official package is not available in target pacman repos: $package"
    fi
  done
}

check_run_target_package_available() {
  local package="$1"
  if [[ "$TARGET_MODE" == "live" ]]; then
    arch-chroot "$TARGET_ROOT" pacman -Si "$package" >/dev/null 2>&1
  else
    pacman -Si "$package" >/dev/null 2>&1
  fi
}
