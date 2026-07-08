#!/bin/sh
set -eu

mkdir -p /isos

resolve_url() {
  name="$1"
  mode="$2"
  source="$3"

  case "$mode" in
    direct)
      printf '%s\n' "$source"
      ;;
    directory-latest)
      page="$(curl -fsSL "$source")"
      iso="$(printf '%s\n' "$page" |
        sed -n 's/.*href="\([^"]*amd64-DVD-1\.iso\)".*/\1/p' |
        sort -V |
        tail -n1)"
      [ -n "$iso" ] || {
        echo "Could not discover latest ISO for $name from $source" >&2
        return 1
      }
      printf '%s%s\n' "$source" "$iso"
      ;;
    fedora-workstation)
      page="$(curl -fsSL "$source")"
      release="$(printf '%s\n' "$page" |
        sed -n 's/.*href="\([0-9][0-9]*\)\/".*/\1/p' |
        sort -n |
        tail -n1)"
      [ -n "$release" ] || {
        echo "Could not discover latest Fedora release from $source" >&2
        return 1
      }
      iso_dir="${source%/}/${release}/Workstation/x86_64/iso/"
      iso_page="$(curl -fsSL "$iso_dir")"
      iso="$(printf '%s\n' "$iso_page" |
        sed -n 's/.*href="\(Fedora-Workstation-Live-[^"]*x86_64\.iso\)".*/\1/p' |
        sort -V |
        tail -n1)"
      [ -n "$iso" ] || {
        echo "Could not discover Fedora Workstation ISO from $iso_dir" >&2
        return 1
      }
      printf '%s%s\n' "$iso_dir" "$iso"
      ;;
    *)
      echo "Unknown ISO mode for $name: $mode" >&2
      return 1
      ;;
  esac
}

cleanup_old_versions() {
  name="$1"
  keep="$2"

  case "$name" in
    archlinux)
      find /isos -maxdepth 1 -type f -name 'archlinux-*.iso' ! -name "$keep" -delete
      ;;
    debian)
      find /isos -maxdepth 1 -type f -name 'debian-*-amd64-DVD-1.iso' ! -name "$keep" -delete
      ;;
    fedora-workstation)
      find /isos -maxdepth 1 -type f -name 'Fedora-Workstation-Live-*.iso' ! -name "$keep" -delete
      ;;
    *)
      find /isos -maxdepth 1 -type f \( \
        -name "${name}-*.iso" -o \
        -name "${name}_*.iso" -o \
        -name "${name}*.iso" \
      \) ! -name "$keep" -delete
      ;;
  esac
}

while IFS="$(printf '\t')" read -r name mode source output; do
  case "${name:-}" in
    ""|\#*) continue ;;
  esac
  if [ -n "${ISO_ONLY:-}" ] && [ "$name" != "$ISO_ONLY" ]; then
    continue
  fi
  if [ -z "${mode:-}" ] || [ -z "${source:-}" ] || [ -z "${output:-}" ]; then
    echo "Skipping invalid distro row: $name $mode $source $output" >&2
    continue
  fi
  url="$(resolve_url "$name" "$mode" "$source")"
  tmp="/isos/.${output}.tmp"
  dst="/isos/${output}"
  echo "Syncing $name from $url"
  curl -fL --retry 3 --retry-delay 5 -o "$tmp" "$url"
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    echo "$name unchanged"
  else
    mv "$tmp" "$dst"
    echo "$name updated: $dst"
  fi
  cleanup_old_versions "$name" "$output"
done < /config/distros.tsv
