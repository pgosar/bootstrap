# NAS kernel update reminder for interactive shells.

case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

if [ -n "${NAS_KERNEL_REMINDER_SHOWN:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
NAS_KERNEL_REMINDER_SHOWN=1
export NAS_KERNEL_REMINDER_SHOWN

if ! command -v pacman-conf >/dev/null 2>&1 || ! command -v pacman >/dev/null 2>&1; then
  return 0 2>/dev/null || exit 0
fi

ignore_pkg="$(pacman-conf IgnorePkg 2>/dev/null || true)"
case "
$ignore_pkg
" in
  *"
linux
"*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

running_kernel="$(uname -r 2>/dev/null || printf unknown)"
installed_linux="$(pacman -Q linux 2>/dev/null | awk '{print $2}')"
installed_release="${installed_linux/.arch/-arch}"

if [ -z "$installed_release" ] || [ "$installed_release" = "$running_kernel" ]; then
  return 0 2>/dev/null || exit 0
fi

printf '\n[NAS] Kernel package updates are pinned: IgnorePkg includes linux/linux-headers.\n'
printf '[NAS] Running kernel: %s; installed linux package: %s.\n' "$running_kernel" "${installed_linux:-not installed}"
printf '[NAS] Reboot pending: installed linux appears newer/different than the running kernel.\n'
printf '[NAS] Intentional kernel upgrade: sudo pacman -Syu linux\n\n'
