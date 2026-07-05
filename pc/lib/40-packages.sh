configure_pacman_for_target() {
  local pacman_conf
  pacman_conf="$(target_path /etc/pacman.conf)"

  if [[ "$APPLY" != true ]]; then
    log "+ enable ParallelDownloads and multilib in $(printf '%q' "$pacman_conf")"
    return 0
  fi

  [[ -f "$pacman_conf" ]] || die "pacman config not found: $pacman_conf"
  backup_file "$pacman_conf"

  if grep -Eq '^[#[:space:]]*ParallelDownloads[[:space:]]*=' "$pacman_conf"; then
    sed -i 's/^[#[:space:]]*ParallelDownloads[[:space:]]*=.*/ParallelDownloads = 50/' "$pacman_conf"
  else
    printf '\nParallelDownloads = 50\n' >>"$pacman_conf"
  fi

  sed -i '/^\#\[multilib\]/{s/^#//;n;s/^#//;}' "$pacman_conf"
}

install_packages() {
  [[ "$PACKAGES" == true ]] || return 0
  require_root
  load_package_lists
  [[ "${#PACMAN_PACKAGES[@]}" -gt 0 ]] || die "package list is empty: $PACKAGE_FILE"
  if [[ "$APPLY" == true ]]; then
    configure_pacman_for_target
    target_run pacman -Sy --noconfirm
    check_target_pacman_packages_available "${PACMAN_PACKAGES[@]}"
    target_run pacman -Syu --needed --noconfirm "${PACMAN_PACKAGES[@]}"
  else
    log "+ pacman -Syu --needed --noconfirm ${PACMAN_PACKAGES[*]}"
  fi
}

configure_makepkg_for_aur_user() {
  local makepkg_conf="/home/$PC_USER/.makepkg.conf"

  if [[ "$APPLY" != true ]]; then
    log "+ write $(printf '%q' "$makepkg_conf") with !debug makepkg options"
    return 0
  fi

  target_run install -d -o "$PC_USER" -g "$PC_USER" "/home/$PC_USER/.cache"
  target_run bash -lc "cat >$(printf '%q' "$makepkg_conf") <<'EOF'
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
EOF
chown $(printf '%q' "$PC_USER"):$(printf '%q' "$PC_USER") $(printf '%q' "$makepkg_conf")"
}

ensure_yay_installed() {
  if check_run_target pacman -Q yay >/dev/null 2>&1; then
    log "yay already installed"
    return 0
  fi

  local build_root package
  build_root="/home/$PC_USER/.cache/aur-builds"
  package="yay"

  configure_makepkg_for_aur_user
  target_run install -d -o "$PC_USER" -g "$PC_USER" "$build_root"
  target_run chown -R "$PC_USER:$PC_USER" "/home/$PC_USER/.cache"
  target_run rm -rf "$build_root/$package"
  target_run runuser -u "$PC_USER" -- git clone "https://aur.archlinux.org/$package.git" "$build_root/$package"
  target_run runuser -u "$PC_USER" -- bash -lc "cd $(printf '%q' "$build_root/$package") && makepkg --syncdeps --noconfirm"
  target_run bash -lc "pkg_file=\$(find $(printf '%q' "$build_root/$package") -maxdepth 1 -type f -name '$package-*.pkg.tar.*' ! -name '*-debug-*' | sort | tail -n 1); [[ -n \"\$pkg_file\" ]] || exit 1; pacman -U --noconfirm \"\$pkg_file\""
}

install_aur_packages() {
  [[ "$PACKAGES" == true ]] || return 0
  require_root
  load_package_lists
  [[ "${#AUR_PACKAGES[@]}" -gt 0 ]] || return 0

  local build_root
  build_root="/home/$PC_USER/.cache/aur-builds"

  if [[ "$APPLY" != true ]]; then
    log "+ bootstrap yay, then install AUR packages as $PC_USER: ${AUR_PACKAGES[*]}"
    return 0
  fi

  target_run install -d -o "$PC_USER" -g "$PC_USER" "$build_root"
  target_run chown -R "$PC_USER:$PC_USER" "/home/$PC_USER/.cache"
  configure_makepkg_for_aur_user
  ensure_yay_installed
  target_run runuser -u "$PC_USER" -- yay -S --needed --noconfirm --answerclean None --answerdiff None --mflags --skippgpcheck "${AUR_PACKAGES[@]}"
}
