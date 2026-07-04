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
nas/qemu/bin/run-nas-bootstrap-qemu.sh --force /path/to/archlinux.iso
```

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

It uses `nas/qemu/qemu-nas.env`, which is intentionally QEMU-only and allows
`/dev/vdX` paths. Do not use that env file on real hardware.

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

Success means the VM boots from GRUB, `/data` and `/mnt/snapshots` are mounted
exactly once, `/data` is writable, `/mnt/snapshots` rejects writes, Docker
waits for `/data`, SnapRAID/btrbk/Snapper are configured, and the final health
check reports no failures.

Logs are written under:

```text
nas/qemu/work/logs/
```
