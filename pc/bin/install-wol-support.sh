#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sudo install -Dm755 "$repo_root/config/wol/pc-arm-wol" /usr/local/sbin/pc-arm-wol
sudo install -Dm644 "$repo_root/config/wol/pc-wol.service" /etc/systemd/system/pc-wol.service

if [ ! -f /etc/default/pc-wol ]; then
  iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
  printf 'WOL_INTERFACE=%s\n' "$iface" | sudo tee /etc/default/pc-wol >/dev/null
fi

if command -v nmcli >/dev/null 2>&1; then
  iface="$(awk -F= '/^WOL_INTERFACE=/{print $2}' /etc/default/pc-wol 2>/dev/null || true)"
  if [ -n "${iface:-}" ]; then
    while IFS=: read -r name _; do
      [ -n "$name" ] || continue
      sudo nmcli connection modify "$name" \
        connection.autoconnect yes \
        connection.permissions "" \
        802-3-ethernet.wake-on-lan magic
    done < <(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v iface="$iface" '$2 == iface {print}')
  fi
fi

mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
install -m755 "$repo_root/config/wol/pc-blank-displays" "$HOME/.local/bin/pc-blank-displays"
install -m644 "$repo_root/config/wol/pc-blank-displays.service" "$HOME/.config/systemd/user/pc-blank-displays.service"

sudo systemctl daemon-reload
sudo systemctl enable --now pc-wol.service

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if systemctl --user daemon-reload >/dev/null 2>&1; then
  systemctl --user disable pc-blank-displays.service >/dev/null 2>&1 || true
else
  echo "User systemd is not reachable from this shell; installed pc-blank-displays but did not enable it." >&2
fi

echo "Installed WOL support. Check firmware settings if wake from S4/S5 still fails."
