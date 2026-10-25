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
* the live host's `/etc` configuration: the Docker daemon's NVIDIA runtime,
  the LACT GPU tuning, the plasmalogin autologin, the keyd keyboard configs,
  the sysctl network tuning, and the saved WiFi profile (installed with a
  placeholder psk; the real one is set on the machine, never in the repo)
* service enablement matching the live host exactly: bpftune and the NVIDIA
  suspend/resume hooks on, snapper-timeline and systemd-oomd off
* the Docker workers stack under `~/docker` (the Tdarr node and the Immich
  machine-learning worker). The compose files are tracked; the two env
  files are installed as placeholders. There is no boot-time unit: like
  the live machine, the workers are started on demand through the
  dotfiles `pc-worker-ensure` / `tdarr-wake-monitor` tools once the real
  `TDARR_API_KEY` is filled in

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
