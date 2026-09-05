#!/usr/bin/env bash
# Cache immutable native cloud images for QEMU tests; never update existing bases.
set -euo pipefail
source_dir="${1:-$HOME/Server/media/linux-isos}"
cache_dir="${QEMU_CLOUD_CACHE:-$HOME/.cache/bootstrap-cloud/images}"
if [[ "${1:-}" == --help ]]; then
  printf 'Usage: %s [NAS-mirror-directory]\nCache: QEMU_CLOUD_CACHE or ~/.cache/bootstrap-cloud/images\nCreate test disks with: qemu-img create -f qcow2 -F qcow2 -b /absolute/checksum-base.qcow2 test.qcow2\n' "$0"
  exit 0
fi
command -v qemu-img >/dev/null
mkdir -p "$cache_dir"
exec 9>"$cache_dir/.prepare.lock"
flock -n 9 || { echo 'Another image preparation is running' >&2; exit 1; }
for entry in \
  archlinux:archlinux-latest-x86_64-cloudimg.qcow2 \
  debian:debian-latest-genericcloud-amd64.qcow2 \
  fedora:fedora-cloud-latest-x86_64.qcow2; do
  distro="${entry%%:*}"
  source_file="$source_dir/${entry#*:}"
  checksum="$(sha256sum "$source_file" | cut -d ' ' -f1)"
  base="$cache_dir/$distro-$checksum.qcow2"
  if [[ ! -f "$base" ]]; then
    temporary="$(mktemp "$cache_dir/.incoming.XXXXXX")"
    cp -- "$source_file" "$temporary"
    [[ "$(sha256sum "$temporary" | cut -d ' ' -f1)" == "$checksum" ]] || {
      echo "Copy verification failed; retained $temporary" >&2; exit 1;
    }
    qemu-img check -f qcow2 "$temporary"
    chmod 0444 "$temporary"
    mv -- "$temporary" "$base"
  else
    [[ "$(sha256sum "$base" | cut -d ' ' -f1)" == "$checksum" ]]
    qemu-img check -f qcow2 "$base"
  fi
  printf '%s\t%s\n' "$distro" "$base"
done
