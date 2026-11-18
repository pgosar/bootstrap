#!/usr/bin/env bash
# Switch a monitor's input source via DDC/CI (ddcutil, VCP 0x60).
# Usage: monitor-input.sh <monitor> <input>
#   monitor: 4k | samsung | dp-2 | dp-1
#   input:   dp | hdmi1 | hdmi2   (samsung also: vga | dvi1 | dvi2)
# Examples:
#   monitor-input.sh 4k hdmi2   # MSI 4K panel to HDMI-2 (PS5)
#   monitor-input.sh 4k dp      # MSI 4K panel back to DisplayPort (PC)
# Input codes are the standard VCP values, confirmed live on both panels
# (MSI MPG321UX OLED on DP-2, Samsung Odyssey G5 on DP-1):
# dp=0x0f, hdmi1=0x11, hdmi2=0x12.
# Display numbers are resolved from `ddcutil detect` by DRM connector,
# because ddcutil renumbers displays when one is disabled (e.g. the MSI
# is Display 2 normally but Display 1 when DP-1 is off in Big Picture mode).
set -euo pipefail

usage() {
  echo "usage: monitor-input.sh <4k|samsung|dp-2|dp-1> <dp|hdmi1|hdmi2|vga|dvi1|dvi2>" >&2
  exit 2
}

[ $# -eq 2 ] || usage

case "$1" in
  4k|dp-2) connector="card1-DP-2"; name="MSI 4K (DP-2)" ;;
  samsung|dp-1) connector="card1-DP-1"; name="Samsung (DP-1)" ;;
  *) usage ;;
esac

case "$2" in
  dp)    code=0x0f; label="DisplayPort" ;;
  hdmi1) code=0x11; label="HDMI-1" ;;
  hdmi2) code=0x12; label="HDMI-2" ;;
  vga)   code=0x01; label="VGA-1" ;;
  dvi1)  code=0x03; label="DVI-1" ;;
  dvi2)  code=0x04; label="DVI-2" ;;
  *) usage ;;
esac

disp="$(ddcutil detect 2>/dev/null | awk -v want="$connector" '
  /^Display [0-9]+/ { num = $2 }
  /DRM_connector:/ && $2 == want { print num; exit }')"
if [ -z "$disp" ]; then
  echo "monitor-input: $name ($connector) not found in ddcutil detect" >&2
  exit 1
fi

ddcutil setvcp 0x60 "$code" --display "$disp"
sleep 2
current="$(ddcutil getvcp 0x60 --display "$disp" 2>/dev/null)"
echo "monitor-input: $name -> $label ($code); now: $current"
