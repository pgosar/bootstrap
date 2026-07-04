# System Builds

Minimal public-safe bootstrap files for rebuilding an Arch Linux NAS.

The NAS bootstrap configures:

- Arch packages plus `yay` AUR packages
- btrfs data disks under `/mnt/diskN`
- mergerfs mounted at `/data`
- SnapRAID parity and timers
- btrbk snapshot timers
- Docker directories under `/data/docker`
- Docker startup dependency on `/data`
- Samba, Tailscale, SSH, and basic service enablement

## Setup

Boot the Arch ISO, connect networking, clone this repo, then create a private
config:

```bash
cp .env.example .env
vim .env
```

Use `/dev/disk/by-id/...` paths only. Do not use `/dev/sdX`.

Preview the full host setup:

```bash
sudo hosts/nas/bootstrap-nas.py --dry-run --all
```

Apply the full host setup:

```bash
sudo hosts/nas/bootstrap-nas.py --apply --all
```

If a configured disk or partition needs formatting, the script prints the target
and requires this exact phrase:

```text
yes, do as I say
```

Install Arch from the ISO when needed:

```bash
sudo hosts/nas/bootstrap-nas.py --apply --install-arch
```

Useful focused commands:

```bash
sudo hosts/nas/bootstrap-nas.py --apply --packages
sudo hosts/nas/bootstrap-nas.py --apply --storage
sudo hosts/nas/bootstrap-nas.py --apply --services --enable-services
sudo hosts/nas/bootstrap-nas.py --validate
```
