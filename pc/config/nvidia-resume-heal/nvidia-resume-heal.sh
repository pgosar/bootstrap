#!/bin/bash
# Post-resume healer for the NVIDIA 615.78 KWin wedge: after some resumes the
# driver throws Xid 13 and kwin_wayland floods "Atomic commit failed: EBUSY"
# with a frozen display while the system stays alive. Run by the
# nvidia-resume-heal system-sleep hook after every resume; exits quietly
# when the resume was healthy.
# NVIDIA_HEAL_BOOT / NVIDIA_HEAL_DRY_RUN exist for testing against old boots.

set -u
TAG=nvidia-resume-heal
BOOT="${NVIDIA_HEAL_BOOT:-0}"
DRY="${NVIDIA_HEAL_DRY_RUN:-0}"

log() { logger -t "$TAG" -- "$*"; printf '%s: %s\n' "$TAG" "$*"; }

count_since() { # $1 = start (unix), $2 = pattern, $3 = "k" for kernel log only
    local args=(-b "$BOOT" --since "@$1" --no-pager -o cat)
    [ "${3:-}" = "k" ] && args+=(-k)
    timeout 15 journalctl "${args[@]}" 2>/dev/null | grep -c "$2" || true
}

trailing_bad() { # live boot only: EBUSY/pageflip lines in the last $1 seconds
    local start=$(( $(date +%s) - $1 )) n
    n=$(timeout 15 journalctl -b 0 --since "@$start" --no-pager -o cat 2>/dev/null | grep -cE "Atomic commit failed|Pageflip timed out" || true)
    [ "${n:-0}" -ge 10 ]
}

pid_dead() { # $1 = pid; true when gone or a zombie
    [ ! -d "/proc/$1" ] || grep -qs "^State:.*Z" "/proc/$1/status" 2>/dev/null
}

resume_unix=$(timeout 15 journalctl -b "$BOOT" -k -g "PM: suspend exit" --no-pager -o short-unix 2>/dev/null | tail -1 | cut -d. -f1)
case "${resume_unix:-}" in
    ''|*[!0-9]*)
        log "no resume found in boot $BOOT; nothing to do"
        exit 0
        ;;
esac

# The signature lags the resume by a few seconds (first Xid ~5s after the
# suspend exit in both observed wedges); let it develop before counting.
[ "$BOOT" = "0" ] && sleep 10

start=$(( resume_unix - 5 ))
xid=$(count_since "$start" "NVRM: Xid" "k")
ebusy=$(count_since "$start" "Atomic commit failed")
flips=$(count_since "$start" "Pageflip timed out")

if [ "${xid:-0}" -lt 1 ] || { [ "${ebusy:-0}" -lt 30 ] && [ "${flips:-0}" -lt 3 ]; }; then
    log "resume healthy (xid=$xid ebusy=$ebusy pageflips=$flips)"
    exit 0
fi

log "WEDGE detected (xid=$xid ebusy=$ebusy pageflips=$flips)"
if [ "$DRY" = "1" ]; then
    log "dry run: no recovery actions taken"
    exit 0
fi

# Step 1: VT bounce. Forces kwin to drop and reacquire DRM master.
cur=$(fgconsole 2>/dev/null || echo 2)
alt=3; [ "$cur" = "3" ] && alt=4
chvt "$alt"; sleep 3; chvt "$cur"; sleep 6
if ! trailing_bad 6; then
    log "healed by VT bounce (was on tty$cur)"
    exit 0
fi
log "VT bounce did not clear the wedge"

# Step 2: kill the wedged compositor first, then restart its service. A
# service restart alone spawns a second kwin that cannot take over while
# the wedged one still holds DRM master (seen Nov 9).
kwin_pid=""
for pid in $(pgrep -x kwin_wayland || true); do
    kwin_pid=$pid
    [ "$(stat -c %U "/proc/$pid" 2>/dev/null || echo "")" != "plasmalogin" ] && break
done
if [ -n "${kwin_pid:-}" ]; then
    kwin_user=$(stat -c %U "/proc/$kwin_pid" 2>/dev/null || echo "")
    kill "$kwin_pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        pid_dead "$kwin_pid" && break
        sleep 1
    done
    if ! pid_dead "$kwin_pid"; then
        kill -9 "$kwin_pid" 2>/dev/null || true
        sleep 2
    fi
    if pid_dead "$kwin_pid"; then
        if [ -n "$kwin_user" ]; then
            timeout 30 systemctl --user -M "$kwin_user@" restart plasma-kwin_wayland.service || true
            log "killed wedged kwin pid $kwin_pid; restarted plasma-kwin_wayland.service for $kwin_user"
        fi
    else
        log "wedged kwin pid $kwin_pid would not die; skipping to reboot"
    fi
fi
sleep 8
if ! trailing_bad 6; then
    log "healed by kwin restart"
    exit 0
fi

# Step 3: one guarded reboot per boot. A direct reboot is refused here: the
# hook runs inside the suspend transaction, so schedule it on a 15s timer.
marker="/run/nvidia-resume-heal.rebooted-$(cat /proc/sys/kernel/random/boot_id)"
if [ -e "$marker" ]; then
    log "still wedged after kwin restart; already auto-rebooted once this boot, giving up"
    exit 0
fi
if systemd-run --on-active=15s --unit=nvidia-resume-heal-reboot \
        --description="Deferred reboot for NVIDIA resume wedge" \
        /usr/bin/systemctl reboot 2>/dev/null; then
    touch "$marker"
    log "still wedged after kwin restart; reboot scheduled in 15s (once per boot)"
elif (setsid sh -c 'sleep 15; /usr/bin/systemctl reboot' >/dev/null 2>&1 < /dev/null &); then
    touch "$marker"
    log "still wedged after kwin restart; reboot scheduled in 15s via fallback (once per boot)"
else
    log "still wedged after kwin restart; FAILED to schedule reboot, giving up"
fi
exit 0
