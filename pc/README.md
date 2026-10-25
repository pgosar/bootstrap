# PC Bootstrap

This tree holds the reproducible installer and validation flow for the current
desktop/workstation host profile.

The structure is intentionally split by role:

```text
pc/
  bin/      top-level entrypoints
  lib/      sourced implementation modules
  packages.txt
  .env.example
  qemu/     disposable validation harness
```

## Entry points

`pc/bin/bootstrap-pc.sh` is the main script.

Common modes:

```bash
pc/bin/bootstrap-pc.sh --help
pc/bin/bootstrap-pc.sh --init-env
pc/bin/bootstrap-pc.sh --list-disks
pc/bin/bootstrap-pc.sh --dry-run --all
```

Install from an Arch ISO:

```bash
sudo pc/bin/bootstrap-pc.sh \
  --env-file pc/.env \
  --target-mode live \
  --target-root /mnt \
  --apply \
  --all
```

Read-only checks:

```bash
sudo pc/bin/bootstrap-pc.sh --env-file pc/.env --check-live-target
sudo pc/bin/bootstrap-pc.sh --env-file pc/.env --check-health
```

`--check-live-target` is for the Arch ISO before rebooting. It inspects the
target mounted at `TARGET_ROOT` and uses `arch-chroot` for target-only package
and unit checks.

`--check-health` is for the installed host after reboot. It checks the real
system at `/` and never calls `arch-chroot`.

## What this installs

The PC bootstrap mirrors the current host shape:

* GRUB on UEFI
* Btrfs root subvolumes for `@`, `@home`, `@root`, `@srv`, `@cache`, `@tmp`, and `@log`
* `amd-ucode`
* The CachyOS pacman repos (znver4) with the `linux-cachyos` + `linux-cachyos-lts`
  kernels and their NVIDIA open modules
* the host package set from `packages.txt` + `aur-packages.txt` (kept at parity
  with the live host: every change to the PC ships as a bootstrap commit)
* system services such as NetworkManager, libvirt, plasmalogin, ufw, avahi,
  tailscaled, docker, keyd, and timesync
* the PC's own pieces from `pc/config/`: Wake-on-LAN support, ssh-inhibit,
  the RAM RGB clock schedule, the NVIDIA suspend workaround, the Keychron
  udev rule, the static-IP NetworkManager profile, and the NAS CIFS mounts
  (credentials come from `NAS_CREDS_SOURCE`, never from the repo)

With `SETUP_DOTFILES=true` (the default) the services phase also clones
`pgosar/dotfiles` into `~/code/dotfiles` and runs its `install.sh`, so a
rebuild lands the full user setup in one run.

## QEMU

`pc/qemu/` holds the disposable fake-disk validation path. The guest-side
scripts are separated from the host launcher so the roles stay obvious.

The expected host-side flow is:

```bash
pc/qemu/bin/run-pc-bootstrap-qemu.sh /path/to/archlinux.iso
```

That launcher is paired with the live-target and installed-health checks in
`pc/qemu/checks/`.

`pc/qemu/qemu-pc.env` is the tracked disposable env for the fake-disk test.
`pc/.env` is the real local config for actual installs.
