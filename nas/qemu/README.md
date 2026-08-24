# NAS QEMU Validation

This directory contains the disposable fake-disk harness for proving the NAS
bootstrap before real hardware is touched.

## Layout

- `bin/` holds the host-side entrypoint that launches QEMU and stages the VM.
- `guest/` holds scripts that run inside the Arch ISO or inside the installed
  guest during the test flow.
- `checks/` holds thin read-only wrappers for live-target and installed-health
  checks.
- `qemu-nas.env` is the disposable QEMU-only config.
- `work/` is generated output: qcow2 disks, logs, HTTP staging, and exported
  artifacts.

The separation is intentional:

- `bin/` is the top-level launcher, so it stays out of the way of the scripts
  it ships into the guest.
- `guest/` contains code that only makes sense once you are inside the VM.
- `checks/` stays small and boring so a human can run the same verification
  steps without the full VM harness.

## Host requirements

Install tools equivalent to:

```text
qemu-system-x86
qemu-img
edk2-ovmf
python
openssh
```

KVM is used when available. OVMF paths are detected from common locations or
can be supplied with:

```bash
OVMF_CODE=/path/to/OVMF_CODE.4m.fd
OVMF_VARS_TEMPLATE=/path/to/OVMF_VARS.4m.fd
```

## Run

From the repo root:

```bash
git -C /path/to/nas-docker bundle create /tmp/nas-docker.bundle --all
NAS_DOCKER_BUNDLE=/tmp/nas-docker.bundle \
  nas/qemu/bin/run-nas-bootstrap-qemu.sh --force /path/to/archlinux.iso
```

The bundle contains tracked Git history only; ignored runtime `.env` files,
appdata, databases, and secrets are not included. The harness requires it so
the installed guest exercises the same tracked Docker and PC-orchestration
source expected by the host bootstrap.

The default work directory is:

```text
nas/qemu/work/
```

The harness creates these fake disks:

```text
/dev/vda = OS disk, 32G
/dev/vdb = data disk 1, 4G
/dev/vdc = data disk 2, 4G
/dev/vdd = data disk 3, 4G
/dev/vde = SnapRAID parity disk, 4G
```

It uses `nas/qemu/qemu-nas.env`, which is intentionally QEMU-only, allows
`/dev/vdX` paths, and restores the staged nas-docker Git bundle. Do not use
that env file on real hardware.

## What it checks

The harness boots the Arch ISO, stages the repo locally inside the VM, then
runs the one-phase installer:

```bash
sudo nas/bootstrap-nas.sh \
  --env-file /root/bootstrap/nas/qemu/qemu-nas.env \
  --target-mode live \
  --target-root /mnt \
  --apply \
  --all
```

It then runs the live-target check before reboot:

```bash
sudo nas/bootstrap-nas.sh \
  --env-file /root/bootstrap/nas/qemu/qemu-nas.env \
  --check-live-target
```

After rebooting without the ISO, the installed VM runs:

```bash
sudo nas/qemu/checks/verify-installed-health.sh /root/bootstrap/nas/qemu/qemu-nas.env
```

The checks are source-driven where possible. Every official and AUR package in
the bootstrap arrays must be installed, UFW must be absent, every managed
config/script/systemd unit must match its bootstrap source (allowing only
reviewed substitutions), scripts must parse, and systemd must load and verify
every unit. The harness also checks host identity, users/groups, locale,
timezone, networking, IPv4-only settings, GRUB and the initial Snapper
snapshot, exact filesystem labels/mounts/options/permissions, mergerfs write
behavior, SnapRAID and btrbk topology, the nftables live rules table, Samba on
the QEMU guest address, Docker live-restore and repository branch, and all
enabled services/timers.

Finally, safe smoke tests execute the installed health-alert, uptime-ledger,
recent-files, duplicate-report, and weekly-digest helpers without delivering
notifications. Success requires both pre-reboot and post-reboot health checks
to report zero failures, no failed systemd units, and a clean QEMU shutdown.

QEMU cannot prove hardware-only SMART reporting or SATA standby behavior, and
a tracked Git bundle cannot contain ignored Compose environments, databases,
appdata, notification credentials, or gocryptfs keys. Those remain explicit
post-install restore and real-hardware checks.

Logs are written under:

```text
nas/qemu/work/logs/
```
