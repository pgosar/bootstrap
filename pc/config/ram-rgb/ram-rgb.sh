#!/bin/bash
# RAM lighting on a clock: black 22:00-08:00, rainbow otherwise.
# Callers: the 22:00/08:00 timers (both run "apply") and the systemd
# system-sleep hook (black before suspend, apply after resume).
# Failures are logged and exit non-zero so a dead write is visible.
fail=0
set_stick() {
  timeout 45 openrgb -d "$1" $2 >/dev/null 2>&1 || { logger -t ram-rgb "openrgb write failed: device $1 args [$2]"; fail=1; }
}
all_sticks() {
  set_stick 0 "$1"
  set_stick 1 "$1"
}
case "$1" in
  off) all_sticks "-m static -c 000000" ;;
  on) all_sticks "-m rainbow" ;;
  apply)
    hour=$(date +%H)
    if [ "$hour" -ge 22 ] || [ "$hour" -lt 8 ]; then
      all_sticks "-m static -c 000000"
    else
      all_sticks "-m rainbow"
    fi
    ;;
  *) echo "usage: ram-rgb.sh on|off|apply" >&2; exit 2 ;;
esac
exit $fail
