#!/usr/bin/env bash
# Big Picture mode: single 4K panel (DP-2) only, monitor input to DisplayPort,
# then launch Steam in Big Picture. If Steam is already running (autostart),
# shut it down first; otherwise launch directly with no restart.
# Runs on the PC. Invoke via SSH, ideally under systemd-inhibit --what=idle
# so the PC does not auto-suspend mid-setup.
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/1000/bus}"
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
  for s in /run/user/1000/wayland-*; do
    case "$s" in *.lock) ;; *) WAYLAND_DISPLAY="$(basename "$s")"; export WAYLAND_DISPLAY; break ;; esac
  done
fi

# Resolve a kscreen-doctor mode id by output + mode spec (same as desk-mode.sh).
mode_id() {
  kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -v out="$1" -v want="$2" '
    /^Output:/ { cur = ($3 == out) }
    cur && /Modes:/ {
      line = $0
      while (match(line, /[0-9]+:[0-9]+x[0-9]+@[0-9.]+/)) {
        tok = substr(line, RSTART, RLENGTH)
        split(tok, a, ":")
        if (a[2] == want) { print a[1]; exit }
        line = substr(line, RSTART + RLENGTH)
      }
    }'
}

M2="$(mode_id DP-2 3840x2160@239.99)"
[ -z "$M2" ] && { echo "bigpicture-mode: DP-2 4K mode not found" >&2; exit 1; }

# Single-monitor layout: DP-2 only, primary, 4K240, scale 1.5.
kscreen-doctor output.DP-2.enable output.DP-2.priority.1 output.DP-2.position.0,0 output.DP-2.mode."$M2" output.DP-2.scale.1.5 output.DP-1.disable output.DP-3.disable
echo "bigpicture-mode: layout set (DP-2 mode $M2 only, DP-1 and DP-3 disabled)"

# Monitor input to DisplayPort (PC), in case it was on HDMI for the PS5.
if [ -x /home/chilly/.local/bin/monitor-input.sh ]; then
  /home/chilly/.local/bin/monitor-input.sh 4k dp
else
  ddcutil setvcp 0x60 0x0f --display 2
fi

# Wake the panel.
kscreen-doctor --dpms on >/dev/null 2>&1 || true

# Steam: shut down only if it is already running, else launch directly.
if pgrep -x steam >/dev/null 2>&1; then
  echo "bigpicture-mode: Steam is running, shutting it down first"
  steam -shutdown
  for _ in $(seq 1 30); do
    pgrep -x steam >/dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -x steam >/dev/null 2>&1; then
    echo "bigpicture-mode: Steam did not exit" >&2
    exit 1
  fi
else
  echo "bigpicture-mode: Steam not running, launching directly"
fi

export DISPLAY=:0
XAUTHORITY="$(ls /run/user/1000/xauth_* 2>/dev/null | head -1)"
export XAUTHORITY
export HOME=/home/chilly
setsid steam -bigpicture >/tmp/steam-bigpicture.log 2>&1 < /dev/null & disown

for _ in $(seq 1 30); do
  if pgrep -a steamwebhelper 2>/dev/null | grep -q "uimode=4"; then
    echo "bigpicture-mode: Steam Big Picture is up (uimode=4)"
    exit 0
  fi
  sleep 1
done
echo "bigpicture-mode: Big Picture did not confirm uimode=4" >&2
exit 1
