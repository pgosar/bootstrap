log() {
  printf '[nas-bootstrap] %s\n' "$*"
}

warn() {
  printf '[nas-bootstrap] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[nas-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Safe Arch NAS bootstrap. Dry-run is the default. Formatting requires
exact interactive confirmation: "$CONFIRM_PHRASE".
The phrase is required once per script invocation before destructive actions.

Usage:
  nas/bootstrap-nas.sh [options]

Modes:
  --dry-run              Print planned actions; do not mutate anything. Default.
  --apply                Apply requested phases.
  --install-arch         Install minimal Arch to TARGET_ROOT from the live ISO.
  --partition-os-disk    Permit partitioning OS disk in the install phase.
  --packages             Install packages, create NAS user/group, build AUR packages.
  --storage              Configure btrfs data disks, fstab, parity mount, and mergerfs.
  --services             Configure SnapRAID, btrbk, Docker, Samba, Tailscale notes, firewall notes, alerts.
  --enable-services      Enable configured systemd services and timers.
  --start-services       Start services after enabling where supported.
  --init-env             Copy .env.example to .env without overwriting.
  --list-disks           Read-only disk inventory with /dev/disk/by-id hints.
  --all                  In target-mode live: run the full ISO install and target setup.
                         In target-mode host: run host packages, storage, services, and enable-services only.
  --env-file PATH        Load private env file. Default: $DEFAULT_ENV_FILE

Checks:
  --check-live-target   Strict read-only check from the Arch ISO before reboot.
                        Requires installed target mounted at TARGET_ROOT, usually /mnt.
                        Checks target files, target packages, target units,
                        live mergerfs mounts, /mnt/data, and /mnt/mnt/snapshots.

  --check-health        Strict read-only health check after rebooting into the installed NAS.
  --checkhealth         Alias for --check-health.
                        Checks the real installed system at /, including /etc/fstab,
                        /data, /mnt/snapshots, services, timers, Docker, SnapRAID,
                        btrbk, Samba, and mount behavior.

Overrides:
  --os-disk PATH
  --efi-partition PATH
  --root-partition PATH
  --target-root PATH
  --target-mode host|live

Common first run:
  nas/bootstrap-nas.sh --init-env
  \$EDITOR nas/.env
  nas/bootstrap-nas.sh --list-disks
  sudo nas/bootstrap-nas.sh --dry-run --all

Apply the full NAS host setup:
  sudo nas/bootstrap-nas.sh --apply --all

Minimal Arch install from the ISO:
  sudo nas/bootstrap-nas.sh --apply --install-arch --partition-os-disk

Full one-phase install from the Arch ISO:
  sudo /repo/nas/bootstrap-nas.sh \\
    --env-file /repo/nas/.env \\
    --target-mode live \\
    --target-root /mnt \\
    --apply \\
    --all

Pre-reboot live target check from the Arch ISO:
  sudo /repo/nas/bootstrap-nas.sh --env-file /repo/nas/.env --check-live-target

Post-reboot installed NAS health check:
  sudo /repo/nas/bootstrap-nas.sh --env-file /repo/nas/.env --check-health
EOF
}

quote_cmd() {
  printf '%q ' "$@"
}

run() {
  log "+ $(quote_cmd "$@")"
  if [[ "$APPLY" == true ]]; then
    "$@"
  fi
}

run_capture() {
  log "+ $(quote_cmd "$@")" >&2
  if [[ "$APPLY" == true ]]; then
    "$@"
  fi
}

run_in() {
  local dir="$1"
  shift
  log "+ (cd $dir && $(quote_cmd "$@"))"
  if [[ "$APPLY" == true ]]; then
    (cd "$dir" && "$@")
  fi
}

target_path() {
  local path="$1"
  case "$TARGET_MODE" in
  host)
    printf '%s\n' "$path"
    ;;
  live)
    [[ "$path" == /* ]] || die "target_path requires absolute path: $path"
    printf '%s%s\n' "$TARGET_ROOT" "$path"
    ;;
  *)
    die "invalid TARGET_MODE: $TARGET_MODE"
    ;;
  esac
}

active_mount_path() {
  local final_path="$1"
  target_path "$final_path"
}

target_run() {
  if [[ "$TARGET_MODE" == "live" ]]; then
    run arch-chroot "$TARGET_ROOT" "$@"
  else
    run "$@"
  fi
}

target_run_capture() {
  if [[ "$TARGET_MODE" == "live" ]]; then
    run_capture arch-chroot "$TARGET_ROOT" "$@"
  else
    run_capture "$@"
  fi
}

target_command_available() {
  local command="$1"
  [[ "$APPLY" == true ]] || return 0
  if [[ "$TARGET_MODE" == "live" ]]; then
    arch-chroot "$TARGET_ROOT" bash -lc "command -v '$command' >/dev/null 2>&1"
  else
    command -v "$command" >/dev/null 2>&1
  fi
}

target_unit_exists() {
  local unit="$1"
  [[ "$APPLY" == true ]] || return 0
  if [[ "$TARGET_MODE" == "live" ]]; then
    arch-chroot "$TARGET_ROOT" systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"
  else
    systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"
  fi
}

ensure_target_resolver() {
  [[ "$TARGET_MODE" == "live" ]] || return 0
  ensure_dir "$TARGET_ROOT/etc"
  if [[ "$APPLY" == true ]]; then
    rm -f "$TARGET_ROOT/etc/resolv.conf"
    cp -L /etc/resolv.conf "$TARGET_ROOT/etc/resolv.conf"
  else
    log "+ rm -f $(printf '%q' "$TARGET_ROOT/etc/resolv.conf")"
    log "+ cp -L /etc/resolv.conf $(printf '%q' "$TARGET_ROOT/etc/resolv.conf")"
  fi
}

check_run_target() {
  if [[ "$TARGET_MODE" == "live" ]]; then
    arch-chroot "$TARGET_ROOT" "$@"
  else
    "$@"
  fi
}

check_command_exists_target() {
  local command="$1"
  if [[ "$TARGET_MODE" == "live" ]]; then
    arch-chroot "$TARGET_ROOT" bash -lc "command -v '$command' >/dev/null 2>&1"
  else
    command -v "$command" >/dev/null 2>&1
  fi
}

require_root() {
  [[ "$(id -u)" == "0" ]] || die "this phase must be run as root"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

is_placeholder() {
  local value="${1:-}"
  [[ -z "$value" || "$value" == *REPLACE_ME* || "$value" == *CHANGEME* || "$value" == *TODO* || "$value" == *example* ]]
}

init_env() {
  [[ -f "$EXAMPLE_ENV_FILE" ]] || die "missing template: $EXAMPLE_ENV_FILE"
  if [[ -e "$DEFAULT_ENV_FILE" ]]; then
    die "$DEFAULT_ENV_FILE already exists; refusing to overwrite"
  fi
  cp "$EXAMPLE_ENV_FILE" "$DEFAULT_ENV_FILE"
  printf 'Created .env from .env.example.\n'
  printf 'Edit .env before running --apply.\n'
  printf 'Run --list-disks to discover stable /dev/disk/by-id paths.\n'
}

preferred_by_id_for_disk() {
  local disk="$1"
  local candidate resolved base priority best="" best_priority=99
  for candidate in /dev/disk/by-id/*; do
    [[ -e "$candidate" && "$candidate" != *-part* ]] || continue
    resolved="$(readlink -f "$candidate" 2>/dev/null || true)"
    [[ "$resolved" == "$disk" ]] || continue
    base="$(basename -- "$candidate")"
    case "$base" in
      wwn-*) priority=1 ;;
      nvme-eui.*) priority=2 ;;
      nvme-uuid.*) priority=3 ;;
      nvme-nvme.*) priority=7 ;;
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
  printf 'NAS bootstrap disk inventory (read-only)\n\n'
  local disk size model serial tran rota rm ro fstype label uuid mountpoints byid suggested
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
    printf 'Disk: %s\n' "$disk"
    printf 'Kernel device: %s\n' "$disk"
    printf 'Size: %s\n' "${size:-unknown}"
    printf 'Model: %s\n' "${model:-unknown}"
    printf 'Serial: %s\n' "${serial:-unknown}"
    printf 'Transport: %s\n' "${tran:-unknown}"
    printf 'Rotational: %s\n' "${rota:-unknown}"
    printf 'Removable: %s\n' "${rm:-unknown}"
    printf 'Read-only: %s\n' "${ro:-unknown}"
    printf 'Filesystem type: %s\n' "${fstype:-none}"
    printf 'Label: %s\n' "${label:-none}"
    printf 'UUID: %s\n' "${uuid:-none}"
    printf 'Mountpoints: %s\n' "${mountpoints:-none}"
    printf 'by-id candidates:\n'
    byid=false
    local candidate resolved
    for candidate in /dev/disk/by-id/*; do
      [[ -e "$candidate" && "$candidate" != *-part* ]] || continue
      resolved="$(readlink -f "$candidate" 2>/dev/null || true)"
      if [[ "$resolved" == "$disk" ]]; then
        printf '  %s\n' "$candidate"
        byid=true
      fi
    done
    [[ "$byid" == true ]] || printf '  none found\n'
    suggested="$(preferred_by_id_for_disk "$disk" || true)"
    if [[ -n "$suggested" ]]; then
      printf 'Preferred by-id path:\n'
      printf '  %s\n' "$suggested"
      printf 'Suggested OS config:\n'
      printf '  OS_DISK="%s"\n' "$suggested"
      printf '  EFI_PARTITION="%s-part1"\n' "$suggested"
      printf '  ROOT_PARTITION="%s-part2"\n' "$suggested"
    else
      printf 'Preferred by-id path:\n'
      printf '  none\n'
    fi
    printf '\n'
  done < <(lsblk -dn -p -o NAME,TYPE | awk '$2 == "disk" { print $1 }')
}

ensure_dir() {
  local path="$1"
  [[ -d "$path" ]] && return 0
  run mkdir -p "$path"
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

write_text() {
  local path="$1"
  local content="$2"
  log "+ write $path"
  if [[ "$APPLY" == true ]]; then
    mkdir -p "$(dirname -- "$path")"
    printf '%s' "$content" >"$path"
  fi
}

append_command_output() {
  local path="$1"
  shift
  log "+ $(quote_cmd "$@") >> $path"
  if [[ "$APPLY" == true ]]; then
    "$@" >>"$path"
  fi
}

write_fresh_install_fstab() {
  local target_root="$1"
  local fstab="$target_root/etc/fstab"

  log "+ generate fresh install fstab at $fstab"
  if [[ "$APPLY" == true ]]; then
    if [[ -e "$fstab" ]]; then
      backup_file "$fstab"
    fi
    genfstab -U "$target_root" >"$fstab"
  else
    log "+ genfstab -U $(printf '%q' "$target_root") > $(printf '%q' "$fstab")"
  fi
}

backup_file() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  local backup
  backup="$(dirname -- "$path")/$(basename -- "$path").backup.$(date +%Y%m%d-%H%M%S)"
  run cp -a "$path" "$backup"
}

copy_with_backup() {
  local src="$1"
  local dst="$2"
  backup_file "$dst"
  ensure_dir "$(dirname -- "$dst")"
  run cp "$src" "$dst"
}

confirm_destructive() {
  local title="$1"
  shift
  if [[ "$APPLY" != true ]]; then
    warn "Would require confirmation before: $title"
    local target
    for target in "$@"; do
      warn "  $target"
    done
    return 0
  fi

  if [[ "$DESTRUCTIVE_CONFIRMED" == true ]]; then
    warn "Destructive confirmation already accepted for this run: $title"
    local target
    for target in "$@"; do
      warn "  $target"
    done
    return 0
  fi

  warn "$title"
  warn "This is destructive. Affected targets:"
  local target
  for target in "$@"; do
    warn "  $target"
  done

  local response
  printf 'Type "%s" to continue: ' "$CONFIRM_PHRASE" >&2
  IFS= read -r response
  [[ "$response" == "$CONFIRM_PHRASE" ]] || die "confirmation phrase did not match; aborting"
  DESTRUCTIVE_CONFIRMED=true
}

split_csv_array_if_needed() {
  local name="$1"
  local declaration
  declaration="$(declare -p "$name" 2>/dev/null || true)"
  [[ "$declaration" == declare\ -a* || "$declaration" == declare\ -x\ -a* ]] || return 0

  local -n array_ref="$name"
  local count="${#array_ref[@]}"
  if [[ "$count" == "1" ]]; then
    local first="${array_ref[0]}"
    if [[ "$first" == *,* ]]; then
      local old_ifs="$IFS"
      IFS=,
      # shellcheck disable=SC2206
      array_ref=( $first )
      IFS="$old_ifs"
    fi
  fi
}
