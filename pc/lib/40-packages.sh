set_pacman_conf_basics() {
  # $1 = pacman.conf path (plain file edit): ParallelDownloads + multilib.
  local pacman_conf="$1"
  # Stock pacman only accepts x86_64 packages unless the v3/v4 levels are
  # listed explicitly (auto-detection of the levels is a CachyOS-pacman
  # feature); the CachyOS znver4 packages require x86_64_v4 here.
  local arch_list="x86_64 x86_64_v3 x86_64_v4"
  [[ "${CACHYOS_VARIANT:-znver4}" == "v3" ]] && arch_list="x86_64 x86_64_v3"
  sed -i '/^[#[:space:]]*Architecture[[:space:]]*=/d' "$pacman_conf"
  sed -i "s/^\[options\]/[options]\nArchitecture = $arch_list/" "$pacman_conf"
  if grep -Eq '^[#[:space:]]*ParallelDownloads[[:space:]]*=' "$pacman_conf"; then
    sed -i 's/^[#[:space:]]*ParallelDownloads[[:space:]]*=.*/ParallelDownloads = 50/' "$pacman_conf"
  else
    printf '\nParallelDownloads = 50\n' >>"$pacman_conf"
  fi
  sed -i '/^\#\[multilib\]/{s/^#//;n;s/^#//;}' "$pacman_conf"
  # Mirror the live [options]: Spotify stays held at its pinned build,
  # and the output options match what the live machine uses.
  if grep -Eq '^[#[:space:]]*IgnorePkg[[:space:]]*=' "$pacman_conf"; then
    sed -i 's/^[#[:space:]]*IgnorePkg[[:space:]]*=.*/IgnorePkg = spotify/' "$pacman_conf"
  else
    sed -i 's/^\[options\]/[options]\nIgnorePkg = spotify/' "$pacman_conf"
  fi
  local opt
  for opt in Color ILoveCandy VerbosePkgLists DisableDownloadTimeout; do
    grep -Eq "^$opt([[:space:]]|$)" "$pacman_conf" || sed -i "s/^\[options\]/[options]\n$opt/" "$pacman_conf"
  done
}

cachyos_repo_sections() {
  local variant="${CACHYOS_VARIANT:-znver4}"
  local mirrorlist="cachyos-v4-mirrorlist"
  [[ "$variant" == "v3" ]] && mirrorlist="cachyos-v3-mirrorlist"
  cat <<EOF
[cachyos-$variant]
Include = /etc/pacman.d/$mirrorlist

[cachyos-core-$variant]
Include = /etc/pacman.d/$mirrorlist

[cachyos-extra-$variant]
Include = /etc/pacman.d/$mirrorlist

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
EOF
}

add_cachyos_repo_sections() {
  # $1 = pacman.conf path. Inserts the CachyOS sections before [core].
  local pacman_conf="$1"
  grep -q '^\[cachyos\]' "$pacman_conf" && return 0
  local sections
  sections="$(cachyos_repo_sections)"
  awk -v block="$sections" 'BEGIN { done=0 } /^\[core\]/ { if (!done) { print block; print ""; done=1 } } { print }' "$pacman_conf" >"$pacman_conf.tmp"
  mv "$pacman_conf.tmp" "$pacman_conf"
}

install_cachyos_keyring_host() {
  # Trusts the CachyOS key on the CURRENT system (the ISO in live mode, the
  # host in host mode) and installs the mirrorlist packages pacman needs to
  # use the new repos. No-op when the key is already trusted.
  if pacman-key --list-keys 2>/dev/null | grep -q "$CACHYOS_KEY_FPR"; then
    return 0
  fi
  # The cachyos-repo bundle tarball is gone from the mirror; do what
  # upstream's cachyos-repo.sh does now: trust the key, then install the
  # keyring/mirrorlist packages from the repo (names resolved from its
  # index, versions unpinned). Fetch the key over HTTPS instead of a
  # keyserver lookup: dirmngr fetches hang behind the QEMU NAT.
  local staging="$STAGING_DIR/cachyos-repo"
  run mkdir -p "$staging"
  run curl -fsSL -o "$staging/cachyos-key.asc" "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$CACHYOS_KEY_FPR"
  run pacman-key --add "$staging/cachyos-key.asc"
  run pacman-key --lsign-key "$CACHYOS_KEY_FPR"
  local repo_url="https://mirror.cachyos.org/repo/x86_64/cachyos"
  run curl -fsSL -o "$staging/repo-index.html" "$repo_url/"
  local name
  while IFS= read -r name; do
    run curl -fsSL -o "$staging/$name" "$repo_url/$name"
  done < <(grep -oE 'cachyos-(keyring|[a-z0-9-]*mirrorlist)-[0-9][^"]*\.pkg\.tar\.zst' "$staging/repo-index.html" | sort -u)
  local pkgs=() f
  while IFS= read -r f; do pkgs+=("$f"); done < <(find "$staging" -name "cachyos-keyring-*.pkg.tar.zst" -o -name "cachyos-mirrorlist-*.pkg.tar.zst" -o -name "cachyos-*-mirrorlist-*.pkg.tar.zst")
  [[ "${#pkgs[@]}" -gt 0 ]] || die "cachyos keyring/mirrorlist packages not found in repo index"
  run pacman -U --noconfirm "${pkgs[@]}"
}

configure_pacman_for_target() {
  local pacman_conf
  pacman_conf="$(target_path /etc/pacman.conf)"

  if [[ "$APPLY" != true ]]; then
    log "+ configure CachyOS repos, ParallelDownloads and multilib in $(printf '%q' "$pacman_conf")"
    return 0
  fi

  [[ -f "$pacman_conf" ]] || die "pacman config not found: $pacman_conf"
  backup_file "$pacman_conf"

  if ! grep -q '^\[cachyos\]' "$pacman_conf"; then
    if [[ "$TARGET_MODE" == "live" ]]; then
      # The bundle was fetched during the pacstrap phase; install its
      # keyring + mirrorlist packages into the target.
      local host_bundle="$STAGING_DIR/cachyos-repo"
      [[ -d "$host_bundle" ]] || die "cachyos repo bundle missing: $host_bundle (pacstrap phase must run first in live mode)"
      # Staged under /root: arch-chroot mounts a tmpfs over the target /tmp.
      run mkdir -p "$(target_path /root/cachyos-repo)"
      run find "$host_bundle" \( -name "cachyos-keyring-*.pkg.tar.zst" -o -name "cachyos-mirrorlist-*.pkg.tar.zst" -o -name "cachyos-*-mirrorlist-*.pkg.tar.zst" \) -exec cp -t "$(target_path /root/cachyos-repo/)" {} +
      target_run bash -lc "pacman -U --noconfirm /root/cachyos-repo/*.pkg.tar.zst"
      target_run rm -rf /root/cachyos-repo
    else
      install_cachyos_keyring_host
    fi
    add_cachyos_repo_sections "$pacman_conf"
  fi
  set_pacman_conf_basics "$pacman_conf"
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
