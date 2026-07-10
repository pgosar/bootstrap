check_host_pacman_packages_available() {
  local package
  run pacman -Sy --noconfirm
  for package in "$@"; do
    if ! pacman -Si "$package" >/dev/null 2>&1; then
      die "official package is not available in configured pacman repos: $package"
    fi
  done
}

check_pacman_packages_available() {
  local package
  target_run pacman -Sy --noconfirm
  if [[ "$APPLY" != true ]]; then
    return 0
  fi
  for package in "$@"; do
    if ! target_run_capture pacman -Si "$package" >/dev/null 2>&1; then
      die "official package is not available in configured pacman repos: $package"
    fi
  done
}

configure_pacman_ignore_packages() {
  local active_conf existing_line package existing found line
  local -a merged=()

  [[ "${#PACMAN_IGNORE_PACKAGES[@]}" -gt 0 ]] || return 0

  active_conf="$(target_path /etc/pacman.conf)"
  line="IgnorePkg   = ${PACMAN_IGNORE_PACKAGES[*]}"
  log "Phase: configure pacman ignored packages"

  if [[ "$APPLY" != true ]]; then
    log "Would ensure $active_conf contains: $line"
    return 0
  fi

  [[ -f "$active_conf" ]] || die "pacman config not found: $active_conf"

  existing_line="$(grep -E '^[[:space:]]*IgnorePkg[[:space:]]*=' "$active_conf" | head -n1 || true)"
  if [[ -n "$existing_line" ]]; then
    read -r -a merged <<<"${existing_line#*=}"
  fi

  for package in "${PACMAN_IGNORE_PACKAGES[@]}"; do
    found=false
    for existing in "${merged[@]}"; do
      if [[ "$existing" == "$package" ]]; then
        found=true
        break
      fi
    done
    [[ "$found" == true ]] || merged+=("$package")
  done

  line="IgnorePkg   = ${merged[*]}"
  if [[ -n "$existing_line" ]]; then
    sed -i -E "0,/^[[:space:]]*IgnorePkg[[:space:]]*=.*/s//${line}/" "$active_conf"
  elif grep -qE '^[[:space:]]*#IgnorePkg[[:space:]]*=' "$active_conf"; then
    sed -i -E "0,/^[[:space:]]*#IgnorePkg[[:space:]]*=.*/s//${line}/" "$active_conf"
  else
    printf '\n%s\n' "$line" >>"$active_conf"
  fi
}

install_packages() {
  log "Phase: install official pacman packages"
  log "Package list:"
  printf '  %s\n' "${PACMAN_PACKAGES[@]}"
  configure_pacman_ignore_packages
  if [[ "$APPLY" == true ]]; then
    ensure_target_resolver
    check_pacman_packages_available "${PACMAN_PACKAGES[@]}"
    target_run pacman -Syu --needed --noconfirm "${PACMAN_PACKAGES[@]}"
  fi
}

configure_users() {
  log "Phase: users and groups"
  target_run groupadd -f "$NAS_GROUP"
  if [[ "$APPLY" != true ]] || ! target_run_capture id "$NAS_USER" >/dev/null 2>&1; then
    target_run useradd -m "$NAS_USER"
  fi
  target_run usermod -aG "wheel,docker,$NAS_GROUP" "$NAS_USER"
  warn "Group membership changes require a new login."
}

aur_dependency_names() {
  awk -F'= ' '
    /^[[:space:]]*(depends|makedepends|checkdepends) = / {
      dep=$2
      sub(/[<>=:].*/, "", dep)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", dep)
      if (dep != "") print dep
    }
  ' "$1" | sort -u
}

build_aur_package_with_makepkg() {
  local package="$1"
  local active_build_dir active_pkg_dir pkg_dir aur_url srcinfo
  active_build_dir="$(target_path "$AUR_BUILD_DIR")"
  ensure_dir "$active_build_dir"
  target_run chown "$NAS_USER" "$AUR_BUILD_DIR"

  if [[ "$APPLY" == true ]] && target_run_capture pacman -Q "$package" >/dev/null 2>&1; then
    log "AUR package already installed: $package"
    return 0
  fi

  pkg_dir="$AUR_BUILD_DIR/$package"
  active_pkg_dir="$(target_path "$pkg_dir")"
  aur_url="https://aur.archlinux.org/$package.git"
  if [[ -d "$active_pkg_dir/.git" ]]; then
    target_run sudo -Hu "$NAS_USER" git -C "$pkg_dir" pull --ff-only
  else
    target_run sudo -Hu "$NAS_USER" git clone "$aur_url" "$pkg_dir"
  fi
  target_run chown -R "$NAS_USER" "$pkg_dir"

  srcinfo="$active_pkg_dir/.SRCINFO.generated"
  if [[ "$APPLY" == true ]]; then
    target_run sudo -Hu "$NAS_USER" bash -lc "cd '$pkg_dir' && makepkg --printsrcinfo > .SRCINFO.generated"
    local deps=()
    mapfile -t deps < <(aur_dependency_names "$srcinfo")
    if [[ "${#deps[@]}" -gt 0 ]]; then
      log "Installing official dependencies for $package:"
      printf '  %s\n' "${deps[@]}"
      target_run pacman -S --needed --noconfirm "${deps[@]}"
    fi
  else
    target_run sudo -Hu "$NAS_USER" bash -lc "cd '$pkg_dir' && makepkg --printsrcinfo"
  fi

  target_run sudo -Hu "$NAS_USER" bash -lc "cd '$pkg_dir' && makepkg --cleanbuild --force --noconfirm --nocheck"
  if [[ "$APPLY" == true ]]; then
    local artifacts=()
    local artifact active_artifact relative_artifacts=()
    if [[ "$TARGET_MODE" == "live" ]]; then
      mapfile -t artifacts < <(find "$active_pkg_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' | sort)
      for active_artifact in "${artifacts[@]}"; do
        artifact="$pkg_dir/$(basename -- "$active_artifact")"
        relative_artifacts+=("$artifact")
      done
      artifacts=("${relative_artifacts[@]}")
    else
      mapfile -t artifacts < <(find "$pkg_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' | sort)
    fi
    [[ "${#artifacts[@]}" -gt 0 ]] || die "no built package artifact found for $package"
    target_run pacman -U --needed --noconfirm "${artifacts[@]}"
  fi
}

install_aur_packages() {
  log "Phase: install AUR packages with makepkg"
  log "AUR package list:"
  printf '  %s\n' "${AUR_PACKAGES[@]}"
  warn "AUR packages execute PKGBUILD build scripts. Review package sources before applying."
  if [[ "$APPLY" != true ]]; then
    log "Would build AUR packages with makepkg as $NAS_USER: ${AUR_PACKAGES[*]}"
    return 0
  fi
  target_command_available git || die "git is required in target for AUR builds"
  target_command_available makepkg || die "makepkg is required in target for AUR builds"
  target_command_available sudo || die "sudo is required in target for AUR builds"
  local uid
  uid="$(target_run_capture id -u "$NAS_USER")"
  [[ "$uid" != "0" ]] || die "AUR builds must not run as root"

  local package
  for package in "${AUR_PACKAGES[@]}"; do
    build_aur_package_with_makepkg "$package"
  done
  return 0
}
