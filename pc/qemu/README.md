# PC QEMU Validation

This directory holds the disposable validation path for the PC bootstrap.

Layout:

```text
pc/qemu/
  bin/      host-side launcher
  guest/    commands intended to run inside the VM
  checks/   read-only wrappers for the live-target and health checks
  qemu-pc.env
```

## What each entrypoint does

`pc/qemu/bin/run-pc-bootstrap-qemu.sh` prepares the fake disk and OVMF state
and launches the test VM.

`pc/qemu/guest/stage1.sh` is the ISO-side command sequence. It mounts the repo,
runs the live one-phase install, and then runs the live-target check.

`pc/qemu/guest/stage2.sh` is the installed-system health check command.

`pc/qemu/checks/verify-live-target.sh` runs the read-only live-target check
directly.

`pc/qemu/checks/verify-installed-health.sh` runs the post-reboot host health
check directly.

The QEMU env file `pc/qemu/qemu-pc.env` is disposable test configuration only.
It is safe to use for the fake disk harness, not for real hardware.

The harness creates a throwaway SSH key in `pc/qemu/work/` for post-reboot
automation. It does not set or store VM passwords.
