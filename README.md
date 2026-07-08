# System Builds

Scripts and templates for recreating personal systems.

## Repo Layout

The repository is split by environment:

```text
nas/   NAS bootstrap and disposable storage validation
pc/    Workstation/bootstrap installer and QEMU validation
```

Each environment follows the same basic structure, with NAS retaining its
existing entrypoint layout:

```text
nas/
  bootstrap-nas.sh
  lib/
  qemu/
  .env.example

pc/
  bin/
  lib/
  qemu/
  .env.example
```

## NAS entrypoints

`nas/bootstrap-nas.sh` is the main NAS installer.

Common commands:

```bash
nas/bootstrap-nas.sh --help
nas/bootstrap-nas.sh --init-env
nas/bootstrap-nas.sh --list-disks
```

It supports a dry-run/default review mode, a one-phase live ISO install, and
read-only live-target / post-boot health checks.

Recommended NAS install from the Arch ISO:

```bash
nas/bootstrap-nas.sh --init-env
$EDITOR nas/.env
nas/bootstrap-nas.sh --list-disks
sudo nas/bootstrap-nas.sh \
  --env-file nas/.env \
  --target-mode live \
  --target-root /mnt \
  --apply \
  --all
```

That command installs Arch into `/mnt`, partitions the configured OS disk, sets
up packages, storage, services, and systemd enablement in the target system.
Formatting still requires typing `yes, do as I say`.

Before rebooting, run the live target check:

```bash
sudo nas/bootstrap-nas.sh --env-file nas/.env --check-live-target
```

After booting into the installed NAS OS:

```bash
sudo nas/bootstrap-nas.sh --env-file nas/.env --check-health
```

If `--all` runs in `TARGET_MODE=host`, it performs installed-OS setup only and
skips Arch install/OS partitioning. From the Arch ISO, use `--target-mode live`.

## PC entrypoints

`pc/bin/bootstrap-pc.sh` is the workstation installer.

Common commands:

```bash
pc/bin/bootstrap-pc.sh --help
pc/bin/bootstrap-pc.sh --init-env
pc/bin/bootstrap-pc.sh --list-disks
sudo pc/bin/bootstrap-pc.sh --dry-run --all
```

Recommended first-run flow:

```bash
pc/bin/bootstrap-pc.sh --init-env
$EDITOR pc/.env
pc/bin/bootstrap-pc.sh --list-disks
sudo pc/bin/bootstrap-pc.sh --dry-run --all
```

The PC script mirrors the current host layout:

* GRUB on UEFI
* Btrfs subvolumes for `@`, `@home`, `@root`, `@srv`, `@cache`, `@tmp`, `@log`
* `amd-ucode`
* core workstation packages
* `NetworkManager`, `ly`, `libvirt`, `ufw`, `avahi`, `systemd-timesyncd`

The PC bootstrap does not set up dotfiles-only shell plugins. Those stay in the
dotfiles repo’s own install flow.

## QEMU validation

Both environments have a disposable QEMU harness under `<env>/qemu/`.
The host-side launcher is separated from the guest-side stage scripts and the
read-only checks so the structure is obvious.
