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
