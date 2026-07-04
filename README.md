# System Builds

Scripts and templates for recreating personal systems. NAS-specific bootstrap
code lives under `nas/`.

## Repo Layout

The NAS tree is split by role:

```text
nas/
  bootstrap-nas.sh        top-level entrypoint
  lib/                     sourced implementation modules
  config/                  tracked config templates copied into the target
  qemu/                    disposable fake-disk validation harness
  .env.example             tracked private-config template
```

`bootstrap-nas.sh` is the public entrypoint. It only loads the files in
`nas/lib/` and dispatches the requested phase. The library files are not meant
to be run directly.

`nas/config/` contains the install-time templates for SnapRAID, btrbk, Samba,
Docker, and systemd units. Those files are copied into the target system or its
staging area by the bootstrap script.

`nas/qemu/` contains the disposable test harness. It is separated from the
bootstrap implementation so the VM runner, guest-side automation, and
read-only verification wrappers are clearly distinct from the code they invoke.

## NAS entrypoints

Common entrypoints:

```bash
nas/bootstrap-nas.sh --help
nas/bootstrap-nas.sh --init-env
nas/bootstrap-nas.sh --list-disks
```

What they do:

```text
--help              Show every supported bootstrap mode and example flow.
--init-env          Create nas/.env from nas/.env.example without overwriting.
--list-disks        Read-only inventory of disks with /dev/disk/by-id hints.
--dry-run           Print planned actions only.
--apply             Allow the selected phases to mutate the system.
--install-arch      Install the base Arch OS to the target disk.
--storage           Configure data disks, mergerfs, fstab, and parity layout.
--services          Write NAS service/config templates into the target system.
--enable-services   Enable systemd units and timers in the target system.
--check-live-target Read-only check from the Arch ISO before reboot.
--check-health      Read-only check after booting the installed NAS.
```

Recommended first-run flow on real hardware:

```bash
nas/bootstrap-nas.sh --init-env
$EDITOR nas/.env
nas/bootstrap-nas.sh --list-disks
sudo nas/bootstrap-nas.sh --dry-run --all
```

`nas/.env` is local and gitignored. Do not put secrets in it. Use stable
`/dev/disk/by-id/...` paths on real hardware and set
`DISK_LAYOUT_REVIEWED="true"` only after confirming OS, data, and parity disk
mapping.

From the Arch ISO, a full one-phase NAS install looks like:

```bash
sudo /repo/nas/bootstrap-nas.sh \
  --env-file /repo/nas/.env \
  --target-mode live \
  --target-root /mnt \
  --apply \
  --all
```

Before rebooting out of the ISO:

```bash
sudo /repo/nas/bootstrap-nas.sh --env-file /repo/nas/.env --check-live-target
arch-chroot /mnt passwd
arch-chroot /mnt passwd "$NAS_USER"
```

After rebooting into the installed NAS:

```bash
sudo /repo/nas/bootstrap-nas.sh --env-file /repo/nas/.env --check-health
```

## QEMU validation

The QEMU test env at `nas/qemu/qemu-nas.env` is for disposable fake disks only.
It intentionally allows `/dev/vdX` device names. Do not use it on real hardware.

The QEMU harness has three distinct entrypoints:

```text
nas/qemu/bin/run-nas-bootstrap-qemu.sh
nas/qemu/guest/stage1.sh
nas/qemu/guest/stage2.sh
```

`run-nas-bootstrap-qemu.sh` is the host-side launcher. It creates the fake
disks, starts the ISO, stages the repo into the guest, and collects logs.

`guest/stage1.sh` runs inside the Arch ISO. It performs the one-phase install,
the live-target check, and installs the post-reboot verifier into the target.

`guest/stage2.sh` runs inside the installed NAS after reboot. It performs the
host-style health checks and exports the final verification log.

The read-only wrappers in `nas/qemu/checks/` are for running the checks without
the full QEMU harness.

To run the full QEMU fake-disk proof:

```bash
nas/qemu/bin/run-nas-bootstrap-qemu.sh --force /path/to/archlinux.iso
```

The harness creates fresh qcow2 disks, runs the one-phase live install, performs
the live target check, reboots without the ISO, and runs the installed health
check. Logs are written under `nas/qemu/work/logs/`.
