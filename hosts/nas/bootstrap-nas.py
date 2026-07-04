#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
DEFAULT_ENV_FILE = REPO_ROOT / ".env"
EXAMPLE_ENV_FILE = REPO_ROOT / ".env.example"
STAGING_DIR = Path("/tmp/nas-bootstrap")
AUR_BUILD_DIR = Path("/var/tmp/nas-bootstrap-aur")
YAY_PACKAGE = "yay"
CONFIRM_PHRASE = "yes, do as I say"
PACMAN_PACKAGES = [
    "base-devel",
    "linux",
    "linux-firmware",
    "git",
    "python",
    "vim",
    "neovim",
    "tmux",
    "openssh",
    "rsync",
    "curl",
    "wget",
    "jq",
    "smartmontools",
    "btrfs-progs",
    "docker",
    "docker-compose",
    "tailscale",
    "samba",
    "ufw",
    "nftables",
    "btrbk",
    "restic",
    "age",
    "gocryptfs",
    "msmtp",
    "mailutils",
    "cronie",
    "pacman-contrib",
    "networkmanager",
    "sudo",
    "dosfstools",
    "efibootmgr",
    "gptfdisk",
]
AUR_PACKAGES = ["mergerfs", "snapraid"]

POOL_SUBVOLUMES = [
    "media",
    "downloads",
    "personal",
    "replicas",
    "secrets",
    "staging",
    "appdata-bulk",
    "docker",
    "backups",
]


def log(message: str) -> None:
    print(f"[nas-bootstrap] {message}", flush=True)


def warn(message: str) -> None:
    print(f"[nas-bootstrap] WARNING: {message}", file=sys.stderr, flush=True)


def die(message: str) -> None:
    print(f"[nas-bootstrap] ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def is_placeholder(value: str | None) -> bool:
    return not value or "REPLACE_ME" in value


def shlex_join(cmd: list[str]) -> str:
    return subprocess.list2cmdline(cmd)


@dataclass
class Config:
    nas_hostname: str = "nas"
    timezone: str = "America/Los_Angeles"
    locale: str = "en_US.UTF-8"
    os_disk: str = "/dev/disk/by-id/REPLACE_ME_OS_DISK"
    efi_partition: str = "/dev/disk/by-id/REPLACE_ME_OS_DISK-part1"
    root_partition: str = "/dev/disk/by-id/REPLACE_ME_OS_DISK-part2"
    target_root: str = "/mnt"
    data_disks: list[str] = field(default_factory=list)
    data_disk_labels: list[str] = field(default_factory=list)
    parity_disk: str = "/dev/disk/by-id/REPLACE_ME_PARITY_DISK"
    parity_label: str = "nas-parity"
    parity_mount: str = "/mnt/parity"
    mergerfs_mount: str = "/data"
    snapshot_view_mount: str = "/mnt/snapshots"
    docker_root: str = "/data/docker"
    docker_compose_dir: str = "/data/docker/compose"
    docker_appdata_dir: str = "/data/docker/appdata"
    nas_user: str = "nasuser"
    nas_group: str = "nas"
    puid: str = "1000"
    pgid: str = "1000"
    tailscale_enable: str = "true"
    smb_enable: str = "true"
    docker_enable: str = "true"
    snapraid_enable: str = "true"
    btrbk_enable: str = "true"


class Bootstrap:
    def __init__(self, args: argparse.Namespace, config: Config) -> None:
        self.args = args
        self.config = config
        self.apply = bool(args.apply)

    def run(
        self, cmd: list[str], *, check: bool = True, cwd: Path | None = None
    ) -> subprocess.CompletedProcess[str] | None:
        prefix = f"(cd {cwd} &&) " if cwd else ""
        log(f"+ {prefix}{shlex_join(cmd)}")
        if not self.apply:
            return None
        return subprocess.run(cmd, check=check, text=True, cwd=cwd)

    def run_capture(self, cmd: list[str], *, cwd: Path | None = None) -> str:
        prefix = f"(cd {cwd} &&) " if cwd else ""
        log(f"+ {prefix}{shlex_join(cmd)}")
        if not self.apply:
            return ""
        return subprocess.check_output(cmd, text=True, cwd=cwd).strip()

    def append_command_output(self, cmd: list[str], path: Path) -> None:
        log(f"+ {shlex_join(cmd)} >> {path}")
        if self.apply:
            output = subprocess.check_output(cmd, text=True)
            with path.open("a") as handle:
                handle.write(output)

    def require_root(self) -> None:
        if os.geteuid() != 0:
            die("this phase must be run as root")

    def require_cmd(self, command: str) -> None:
        if shutil.which(command) is None:
            die(f"required command not found: {command}")

    def ensure_dir(self, path: str | Path) -> None:
        path = Path(path)
        if path.is_dir():
            return
        self.run(["mkdir", "-p", str(path)])

    def backup_file(self, path: str | Path) -> None:
        path = Path(path)
        if not path.exists():
            return
        backup = path.with_name(f"{path.name}.backup.{datetime.now():%Y%m%d-%H%M%S}")
        self.run(["cp", "-a", str(path), str(backup)])

    def copy_with_backup(self, src: str | Path, dst: str | Path) -> None:
        src = Path(src)
        dst = Path(dst)
        self.backup_file(dst)
        self.ensure_dir(dst.parent)
        self.run(["cp", str(src), str(dst)])

    def selected_mutating_phase(self) -> bool:
        return any(
            [
                self.args.install_arch,
                self.args.packages,
                self.args.storage,
                self.args.services,
                self.args.enable_services,
            ]
        )

    def preflight(self) -> None:
        log(f"Mode: {'apply' if self.apply else 'dry-run'}")
        if self.args.partition_os_disk:
            warn("OS disk partitioning is permitted by --partition-os-disk.")
        if self.apply and self.selected_mutating_phase():
            self.require_root()
        if self.apply and self.args.packages:
            self.require_cmd("pacman")
        if self.args.install_arch:
            for command in ["pacstrap", "genfstab", "arch-chroot"]:
                if shutil.which(command) is None:
                    if self.apply:
                        die(f"--install-arch requires {command} from the Arch ISO")
                    warn(f"--install-arch will require {command} from the Arch ISO")
        if self.args.storage:
            self.preflight_storage()
        STAGING_DIR.mkdir(parents=True, exist_ok=True)

    def preflight_storage(self) -> None:
        if not self.config.data_disks:
            warn("DATA_DISKS is empty.")
        if len(self.config.data_disks) != len(self.config.data_disk_labels):
            if self.apply:
                die("DATA_DISKS and DATA_DISK_LABELS must have the same length")
            warn("DATA_DISKS and DATA_DISK_LABELS lengths differ.")
        for disk in self.config.data_disks:
            if is_placeholder(disk):
                warn(f"Data disk placeholder still present: {disk}")
            elif not Path(disk).exists():
                if self.apply:
                    die(f"configured data disk does not exist: {disk}")
                warn(f"Configured data disk not present on this machine: {disk}")
        data_mount = Path(self.config.mergerfs_mount)
        if self.args.storage and data_mount.is_dir() and shutil.which("findmnt"):
            mounted = subprocess.run(
                ["findmnt", "-n", str(data_mount)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if mounted.returncode != 0:
                try:
                    populated = any(data_mount.iterdir())
                except PermissionError:
                    populated = True
                if populated:
                    if self.apply:
                        die(f"{data_mount} exists, is not a mount, and is not empty")
                    warn(f"{data_mount} exists, is not a mount, and is not empty")

    def print_summary(self) -> None:
        log("Planned actions:")
        log(
            f"  install_arch={self.args.install_arch} packages={self.args.packages} storage={self.args.storage}"
        )
        log(
            f"  services={self.args.services} enable_services={self.args.enable_services} validate={self.args.validate}"
        )

    def confirm_destructive(self, title: str, targets: list[str]) -> None:
        if not self.apply:
            warn(f"Would require confirmation before: {title}")
            for target in targets:
                warn(f"  {target}")
            return
        warn(title)
        warn("This is destructive. Affected targets:")
        for target in targets:
            warn(f"  {target}")
        response = input(f'Type "{CONFIRM_PHRASE}" to continue: ')
        if response != CONFIRM_PHRASE:
            die("confirmation phrase did not match; aborting")

    def blkid_value(self, device: str, field: str) -> str | None:
        if (
            shutil.which("blkid") is None
            or is_placeholder(device)
            or not Path(device).exists()
        ):
            return None
        result = subprocess.run(
            ["blkid", "-s", field, "-o", "value", device],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        return result.stdout.strip() or None

    def filesystem_matches(
        self, device: str, fs_type: str, label: str | None = None
    ) -> bool:
        if self.blkid_value(device, "TYPE") != fs_type:
            return False
        return label is None or self.blkid_value(device, "LABEL") == label

    def install_arch_system(self) -> None:
        cfg = self.config
        log("Phase: install minimal Arch from ISO")
        if is_placeholder(cfg.root_partition) or is_placeholder(cfg.efi_partition):
            die(
                "--install-arch requires --root-partition and --efi-partition or edited env values"
            )
        if self.args.partition_os_disk:
            if is_placeholder(cfg.os_disk):
                die("--partition-os-disk requires --os-disk")
            self.confirm_destructive(
                "About to wipe and repartition the OS disk.", [cfg.os_disk]
            )
            self.run(["sgdisk", "--zap-all", cfg.os_disk])
            self.run(
                ["sgdisk", "-n", "1:0:+1G", "-t", "1:ef00", "-c", "1:EFI", cfg.os_disk]
            )
            self.run(
                [
                    "sgdisk",
                    "-n",
                    "2:0:0",
                    "-t",
                    "2:8304",
                    "-c",
                    "2:arch-root",
                    cfg.os_disk,
                ]
            )
            self.run(["partprobe", cfg.os_disk])
        if not self.filesystem_matches(
            cfg.efi_partition, "vfat"
        ) or not self.filesystem_matches(cfg.root_partition, "btrfs", "arch-root"):
            self.confirm_destructive(
                "About to format the OS EFI/root partitions.",
                [cfg.efi_partition, cfg.root_partition],
            )
            self.run(["mkfs.fat", "-F32", cfg.efi_partition])
            self.run(["mkfs.btrfs", "-f", "-L", "arch-root", cfg.root_partition])
        self.ensure_dir(cfg.target_root)
        self.run(["mount", cfg.root_partition, cfg.target_root])
        self.ensure_dir(Path(cfg.target_root) / "boot")
        self.run(["mount", cfg.efi_partition, f"{cfg.target_root}/boot"])
        self.run(
            [
                "pacstrap",
                "-K",
                cfg.target_root,
                "base",
                "base-devel",
                "linux",
                "linux-firmware",
                "btrfs-progs",
                "networkmanager",
                "sudo",
                "openssh",
                "git",
                "python",
                "vim",
                "neovim",
                "tmux",
            ]
        )
        self.append_command_output(
            ["genfstab", "-U", cfg.target_root], Path(cfg.target_root) / "etc/fstab"
        )
        self.run(
            [
                "arch-chroot",
                cfg.target_root,
                "ln",
                "-sf",
                f"/usr/share/zoneinfo/{cfg.timezone}",
                "/etc/localtime",
            ]
        )
        self.run(["arch-chroot", cfg.target_root, "hwclock", "--systohc"])
        self.uncomment_locale(Path(cfg.target_root) / "etc/locale.gen", cfg.locale)
        self.run(["arch-chroot", cfg.target_root, "locale-gen"])
        self.write_text(
            Path(cfg.target_root) / "etc/locale.conf", f"LANG={cfg.locale}\n"
        )
        self.write_text(Path(cfg.target_root) / "etc/hostname", f"{cfg.nas_hostname}\n")
        self.write_text(
            Path(cfg.target_root) / "etc/hosts",
            f"127.0.0.1 localhost\n::1 localhost\n127.0.1.1 {cfg.nas_hostname}.localdomain {cfg.nas_hostname}\n",
        )
        self.ensure_chroot_user(cfg.target_root, cfg.nas_user)
        self.write_text(
            Path(cfg.target_root) / "etc/sudoers.d/10-wheel",
            "%wheel ALL=(ALL:ALL) ALL\n",
        )
        self.run(["chmod", "0440", f"{cfg.target_root}/etc/sudoers.d/10-wheel"])
        self.run(["arch-chroot", cfg.target_root, "bootctl", "install"])
        root_uuid = (
            self.run_capture(["blkid", "-s", "UUID", "-o", "value", cfg.root_partition])
            or "REPLACE_ME_ROOT_UUID_AFTER_FORMAT"
        )
        self.ensure_dir(Path(cfg.target_root) / "boot/loader/entries")
        self.write_text(
            Path(cfg.target_root) / "boot/loader/loader.conf",
            "default arch.conf\ntimeout 3\nconsole-mode max\neditor no\n",
        )
        self.write_text(
            Path(cfg.target_root) / "boot/loader/entries/arch.conf",
            f"title Arch NAS\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions root=UUID={root_uuid} rw\n",
        )
        self.run(
            [
                "arch-chroot",
                cfg.target_root,
                "systemctl",
                "enable",
                "NetworkManager",
                "sshd",
            ]
        )
        warn(
            f"Set passwords before rebooting: arch-chroot {cfg.target_root} passwd; arch-chroot {cfg.target_root} passwd {cfg.nas_user}"
        )

    def write_text(self, path: Path, content: str) -> None:
        log(f"+ write {path}")
        if self.apply:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)

    def uncomment_locale(self, path: Path, locale: str) -> None:
        log(f"+ uncomment {locale} UTF-8 in {path}")
        if not self.apply:
            return
        text = path.read_text()
        text = text.replace(f"#{locale} UTF-8", f"{locale} UTF-8")
        path.write_text(text)

    def ensure_chroot_user(self, target_root: str, user: str) -> None:
        log(f"+ arch-chroot {target_root} ensure user {user}")
        if not self.apply:
            return
        exists = (
            subprocess.run(
                ["arch-chroot", target_root, "id", user],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode
            == 0
        )
        if not exists:
            subprocess.run(
                ["arch-chroot", target_root, "useradd", "-m", "-G", "wheel", user],
                check=True,
            )

    def install_packages(self) -> None:
        log("Phase: install official pacman packages")
        packages = PACMAN_PACKAGES
        log("Package list:")
        for package in packages:
            print(f"  {package}")
        if self.apply and packages:
            self.run(["pacman", "-Syu", "--needed", *packages])

    def configure_users(self) -> None:
        cfg = self.config
        log("Phase: users and groups")
        self.run(["groupadd", "-f", cfg.nas_group])
        exists = (
            subprocess.run(
                ["id", cfg.nas_user],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode
            == 0
        )
        if not exists:
            self.run(["useradd", "-m", cfg.nas_user])
        self.run(["usermod", "-aG", f"wheel,docker,{cfg.nas_group}", cfg.nas_user])
        warn("Group membership changes require a new login.")

    def bootstrap_yay(self) -> None:
        if shutil.which("yay"):
            log("yay already installed.")
            return
        warn("yay is not installed; bootstrapping yay from AUR with makepkg.")
        self.build_aur_package_with_makepkg(YAY_PACKAGE)
        if shutil.which("yay") is None:
            die("yay install completed but yay is not on PATH")

    def build_aur_package_with_makepkg(self, package: str) -> None:
        self.ensure_dir(AUR_BUILD_DIR)
        self.run(["chown", self.config.nas_user, str(AUR_BUILD_DIR)])
        if (
            self.apply
            and subprocess.run(
                ["pacman", "-Q", package],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode
            == 0
        ):
            log(f"AUR package already installed: {package}")
            return
        pkg_dir = AUR_BUILD_DIR / package
        aur_url = f"https://aur.archlinux.org/{package}.git"
        if pkg_dir.joinpath(".git").is_dir():
            self.run(
                [
                    "sudo",
                    "-Hu",
                    self.config.nas_user,
                    "git",
                    "-C",
                    str(pkg_dir),
                    "pull",
                    "--ff-only",
                ]
            )
        else:
            self.run(
                [
                    "sudo",
                    "-Hu",
                    self.config.nas_user,
                    "git",
                    "clone",
                    aur_url,
                    str(pkg_dir),
                ]
            )
        self.run(["chown", "-R", self.config.nas_user, str(pkg_dir)])
        srcinfo = pkg_dir / ".SRCINFO.generated"
        if self.apply:
            srcinfo.write_text(
                self.run_capture(
                    ["sudo", "-Hu", self.config.nas_user, "makepkg", "--printsrcinfo"],
                    cwd=pkg_dir,
                )
                + "\n"
            )
        else:
            self.run(
                ["sudo", "-Hu", self.config.nas_user, "makepkg", "--printsrcinfo"],
                cwd=pkg_dir,
            )
        if self.apply:
            deps = aur_dependency_names(srcinfo)
            if deps:
                log(f"Installing official dependencies for {package}:")
                for dep in deps:
                    print(f"  {dep}")
                self.run(["pacman", "-S", "--needed", *deps])
        self.run(
            [
                "sudo",
                "-Hu",
                self.config.nas_user,
                "makepkg",
                "--cleanbuild",
                "--force",
                "--noconfirm",
            ],
            cwd=pkg_dir,
        )
        if self.apply:
            artifacts = [
                p for p in pkg_dir.glob("*.pkg.tar.*") if not p.name.endswith(".sig")
            ]
            if not artifacts:
                die(f"no built package artifact found for {package}")
            self.run(["pacman", "-U", "--needed", *map(str, artifacts)])

    def install_aur_packages(self) -> None:
        log("Phase: install AUR packages with yay")
        packages = AUR_PACKAGES
        log("AUR package list:")
        for package in packages:
            print(f"  {package}")
        warn(
            "AUR packages execute PKGBUILD build scripts. yay will prompt for review unless configured otherwise."
        )
        if not self.apply:
            log(
                f"Would install yay if missing, then run: yay -S --needed {' '.join(packages)}"
            )
            return
        for command in ["git", "makepkg", "sudo"]:
            self.require_cmd(command)
        uid = subprocess.check_output(
            ["id", "-u", self.config.nas_user], text=True
        ).strip()
        if uid == "0":
            die("AUR builds must not run as root")
        self.bootstrap_yay()
        self.run(
            ["sudo", "-Hu", self.config.nas_user, "yay", "-S", "--needed", *packages]
        )

    def configure_data_disk(self, index: int, disk: str, label: str) -> None:
        mountpoint = Path(f"/mnt/disk{index}")
        if is_placeholder(disk):
            if self.apply:
                die(f"refusing placeholder data disk for disk{index}")
            warn(f"Would refuse placeholder data disk for disk{index}: {disk}")
            return
        self.ensure_dir(mountpoint)
        if not self.filesystem_matches(disk, "btrfs", label):
            self.confirm_destructive(
                f"About to format data disk {index} as btrfs.", [disk]
            )
            self.run(["mkfs.btrfs", "-f", "-L", label, disk])
        self.run(["mountpoint", "-q", str(mountpoint)], check=False)
        if self.apply:
            mounted = (
                subprocess.run(["mountpoint", "-q", str(mountpoint)]).returncode == 0
            )
            if not mounted:
                self.run(["mount", disk, str(mountpoint)])
        self.ensure_dir(mountpoint / "pool")
        self.ensure_dir(mountpoint / "snapshots")
        for subvol in POOL_SUBVOLUMES:
            path = mountpoint / "pool" / subvol
            if path.is_dir():
                continue
            self.run(["btrfs", "subvolume", "create", str(path)])

    def generate_fstab_text(self) -> str:
        cfg = self.config
        lines = ["# Generated by bootstrap-nas.py. Review before applying."]
        branches: list[str] = []
        requires: list[str] = []
        for idx, label in enumerate(cfg.data_disk_labels, start=1):
            mountpoint = f"/mnt/disk{idx}"
            lines.append(
                f"LABEL={label} {mountpoint} btrfs "
                "rw,noatime,compress=zstd:3,space_cache=v2,nofail,x-systemd.device-timeout=10s 0 0"
            )
            branches.append(f"{mountpoint}/pool")
            requires.append(f"x-systemd.requires-mounts-for={mountpoint}")
        if not is_placeholder(cfg.parity_label):
            lines.append(
                f"LABEL={cfg.parity_label} {cfg.parity_mount} ext4 rw,noatime,nofail,x-systemd.device-timeout=10s 0 2"
            )
        if branches:
            options = ",".join(
                [
                    "defaults",
                    "category.create=mfs",
                    "moveonenospc=true",
                    "minfreespace=100G",
                    "fsname=mergerfs-data",
                    "nofail",
                    *requires,
                ]
            )
            lines.append(
                f"{':'.join(branches)} {cfg.mergerfs_mount} fuse.mergerfs {options} 0 0"
            )
        return "\n".join(lines) + "\n"

    def generate_fstab_file(self) -> None:
        output = STAGING_DIR / "fstab.generated"
        text = self.generate_fstab_text()
        log(f"Generating fstab at {output}")
        output.write_text(text)
        if self.apply:
            self.backup_file("/etc/fstab")
            self.replace_managed_block(Path("/etc/fstab"), text, "nas-bootstrap")

    def replace_managed_block(self, path: Path, block: str, name: str) -> None:
        begin = f"# BEGIN {name} managed block"
        end = f"# END {name} managed block"
        log(f"+ update managed block in {path}")
        if not self.apply:
            return
        existing = path.read_text() if path.exists() else ""
        pattern = re.compile(
            rf"^{re.escape(begin)}$.*?^{re.escape(end)}$\n?", re.MULTILINE | re.DOTALL
        )
        cleaned = pattern.sub("", existing).rstrip()
        new_text = (
            f"{cleaned}\n\n{begin}\n{block.rstrip()}\n{end}\n"
            if cleaned
            else f"{begin}\n{block.rstrip()}\n{end}\n"
        )
        path.write_text(new_text)

    def configure_storage(self) -> None:
        cfg = self.config
        log("Phase: storage, btrfs layout, and mergerfs")
        if shutil.which("mergerfs") is None:
            warn("mergerfs command not found; install it before mounting /data.")
        for idx, (disk, label) in enumerate(
            zip(cfg.data_disks, cfg.data_disk_labels), start=1
        ):
            self.configure_data_disk(idx, disk, label)
        self.ensure_dir(cfg.parity_mount)
        if not is_placeholder(cfg.parity_disk) and not self.filesystem_matches(
            cfg.parity_disk, "ext4", cfg.parity_label
        ):
            self.confirm_destructive(
                "About to format the SnapRAID parity disk as ext4.", [cfg.parity_disk]
            )
            self.run(["mkfs.ext4", "-F", "-L", cfg.parity_label, cfg.parity_disk])
        self.ensure_dir(cfg.mergerfs_mount)
        self.ensure_dir(cfg.snapshot_view_mount)
        self.generate_fstab_file()
        if self.apply:
            self.run(["findmnt", "--verify"])
            self.run(["systemctl", "daemon-reload"])
            self.run(["mount", "-a"])
            self.run(["findmnt", cfg.mergerfs_mount])

    def configure_snapraid(self) -> None:
        log("Phase: SnapRAID config and timers")
        if shutil.which("snapraid") is None:
            warn("snapraid command not found; install it before enabling timers.")
        self.copy_with_backup(
            SCRIPT_DIR / "snapraid.conf.example", "/etc/snapraid.conf"
        )
        for unit in [
            "snapraid-sync.service",
            "snapraid-sync.timer",
            "snapraid-scrub.service",
            "snapraid-scrub.timer",
        ]:
            self.copy_with_backup(
                SCRIPT_DIR / "systemd" / unit, Path("/etc/systemd/system") / unit
            )
        warn(
            "SnapRAID sync is not started automatically. Review deletion guard TODO first."
        )

    def configure_btrbk(self) -> None:
        log("Phase: btrbk config and timer")
        self.copy_with_backup(
            SCRIPT_DIR / "btrbk.conf.example", "/etc/btrbk/btrbk.conf"
        )
        for unit in ["btrbk.service", "btrbk.timer"]:
            self.copy_with_backup(
                SCRIPT_DIR / "systemd" / unit, Path("/etc/systemd/system") / unit
            )

    def configure_docker(self) -> None:
        cfg = self.config
        log("Phase: Docker directories and /data dependency")
        if (
            self.apply
            and subprocess.run(
                ["findmnt", "-n", cfg.mergerfs_mount],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode
            != 0
        ):
            die(f"{cfg.mergerfs_mount} must be mounted before Docker setup")
        self.ensure_dir(cfg.docker_root)
        self.ensure_dir(cfg.docker_compose_dir)
        self.ensure_dir(cfg.docker_appdata_dir)
        self.run(["chown", "-R", f"{cfg.puid}:{cfg.pgid}", cfg.docker_root])
        self.copy_with_backup(
            SCRIPT_DIR / "systemd/docker.service.d/wait-for-data.conf",
            "/etc/systemd/system/docker.service.d/wait-for-data.conf",
        )
        self.copy_with_backup(
            SCRIPT_DIR / "docker-daemon.json.example", "/etc/docker/daemon.json"
        )

    def configure_samba(self) -> None:
        log("Phase: Samba config")
        self.copy_with_backup(SCRIPT_DIR / "smb.conf.example", "/etc/samba/smb.conf")
        if shutil.which("testparm"):
            self.run(["testparm", "-s", "/etc/samba/smb.conf"])
        else:
            warn("testparm not found; install samba before validation.")

    def configure_tailscale(self) -> None:
        log("Phase: SSH and Tailscale")
        warn("Tailscale auth keys are not stored in this repo.")
        log("Manual next step after service enablement: sudo tailscale up")

    def configure_firewall(self) -> None:
        log("Phase: firewall placeholder")
        self.ensure_dir("/etc/nas-bootstrap")
        self.write_text(
            Path("/etc/nas-bootstrap/firewall-notes.txt"),
            "Review UFW with Docker carefully; Docker can bypass UFW rules. Prefer Tailscale and LAN-only binds.\n",
        )

    def configure_alerts(self) -> None:
        log("Phase: alert placeholders")
        self.ensure_dir("/etc/nas-bootstrap/alerts")
        self.write_text(
            Path("/etc/nas-bootstrap/alerts/alerts.env.example"),
            "DISCORD_WEBHOOK_URL=REPLACE_ME\nHEALTHCHECKS_URL=REPLACE_ME\n",
        )

    def configure_services(self) -> None:
        self.configure_snapraid()
        self.configure_btrbk()
        self.configure_docker()
        self.configure_samba()
        self.configure_tailscale()
        self.configure_firewall()
        self.configure_alerts()

    def enable_services(self) -> None:
        cfg = self.config
        log("Phase: enable services")
        self.run(["systemctl", "daemon-reload"])
        if cfg.docker_enable == "true":
            self.run(["systemctl", "enable", "docker"])
            if self.args.start_services:
                self.run(["systemctl", "start", "docker"])
        if cfg.tailscale_enable == "true":
            self.run(["systemctl", "enable", "sshd", "tailscaled"])
            if self.args.start_services:
                self.run(["systemctl", "start", "sshd", "tailscaled"])
        if cfg.smb_enable == "true":
            self.run(["systemctl", "enable", "smb", "nmb"])
            if self.args.start_services:
                self.run(["systemctl", "start", "smb", "nmb"])
        if cfg.snapraid_enable == "true":
            self.run(
                ["systemctl", "enable", "snapraid-sync.timer", "snapraid-scrub.timer"]
            )
        if cfg.btrbk_enable == "true":
            self.run(["systemctl", "enable", "btrbk.timer"])

    def validate_system(self) -> None:
        log("Phase: read-only validation")
        checks = [
            ("findmnt /data", ["findmnt", self.config.mergerfs_mount]),
            ("findmnt /mnt/disk1", ["findmnt", "/mnt/disk1"]),
            ("docker info", ["docker", "info"]),
            ("sshd enabled", ["systemctl", "is-enabled", "sshd"]),
            ("sshd active", ["systemctl", "is-active", "sshd"]),
            ("tailscaled active", ["systemctl", "is-active", "tailscaled"]),
            ("snapraid status", ["snapraid", "status"]),
            ("btrfs filesystem show", ["btrfs", "filesystem", "show"]),
            (
                "btrfs subvolume list /mnt/disk1",
                ["btrfs", "subvolume", "list", "/mnt/disk1"],
            ),
        ]
        failed = False
        for label, cmd in checks:
            if shutil.which(cmd[0]) is None:
                print(f"[SKIP] {label} ({cmd[0]} not installed)")
                continue
            result = subprocess.run(
                cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            if result.returncode == 0:
                print(f"[PASS] {label}")
            else:
                print(f"[FAIL] {label}")
                failed = True
        for path in [
            Path(self.config.mergerfs_mount) / "media",
            Path(self.config.docker_root),
        ]:
            if path.is_dir():
                print(f"[PASS] directory {path} exists")
            else:
                print(f"[FAIL] directory {path} exists")
                failed = True
        if failed:
            raise SystemExit(1)

    def main(self) -> None:
        self.preflight()
        self.print_summary()
        if self.args.install_arch:
            self.install_arch_system()
        if self.args.packages:
            self.install_packages()
            self.configure_users()
            self.install_aur_packages()
        if self.args.storage:
            self.configure_storage()
        if self.args.services:
            self.configure_services()
        if self.args.enable_services:
            self.enable_services()
        if self.args.validate:
            self.validate_system()


def aur_dependency_names(srcinfo: Path) -> list[str]:
    deps: set[str] = set()
    for raw_line in srcinfo.read_text().splitlines():
        line = raw_line.strip()
        if not re.match(r"^(depends|makedepends|checkdepends) = ", line):
            continue
        dep = line.split("=", 1)[1].strip()
        dep = re.split(r"[<>=:]", dep, maxsplit=1)[0].strip()
        if dep:
            deps.add(dep)
    return sorted(deps)


def parse_env_file(path: Path, config: Config) -> None:
    if not path.exists():
        return
    lines = path.read_text().splitlines()
    idx = 0
    while idx < len(lines):
        line = lines[idx].strip()
        idx += 1
        if not line or line.startswith("#"):
            continue
        array_match = re.match(r"^([A-Z0-9_]+)=\($", line)
        if array_match:
            key = array_match.group(1)
            values: list[str] = []
            while idx < len(lines):
                item = lines[idx].strip()
                idx += 1
                if item == ")":
                    break
                if not item or item.startswith("#"):
                    continue
                values.append(unquote(item))
            set_config_value(config, key, values)
            continue
        scalar_match = re.match(r"^([A-Z0-9_]+)=(.*)$", line)
        if scalar_match:
            set_config_value(
                config, scalar_match.group(1), unquote(scalar_match.group(2).strip())
            )


def unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def set_config_value(config: Config, key: str, value: str | list[str]) -> None:
    mapping = {
        "NAS_HOSTNAME": "nas_hostname",
        "TIMEZONE": "timezone",
        "LOCALE": "locale",
        "OS_DISK": "os_disk",
        "EFI_PARTITION": "efi_partition",
        "ROOT_PARTITION": "root_partition",
        "TARGET_ROOT": "target_root",
        "DATA_DISKS": "data_disks",
        "DATA_DISK_LABELS": "data_disk_labels",
        "PARITY_DISK": "parity_disk",
        "PARITY_LABEL": "parity_label",
        "PARITY_MOUNT": "parity_mount",
        "MERGERFS_MOUNT": "mergerfs_mount",
        "DATA_ROOT": "mergerfs_mount",
        "SNAPSHOT_VIEW_MOUNT": "snapshot_view_mount",
        "DOCKER_ROOT": "docker_root",
        "DOCKER_COMPOSE_DIR": "docker_compose_dir",
        "DOCKER_APPDATA_DIR": "docker_appdata_dir",
        "NAS_USER": "nas_user",
        "NAS_GROUP": "nas_group",
        "PUID": "puid",
        "PGID": "pgid",
        "TAILSCALE_ENABLE": "tailscale_enable",
        "SMB_ENABLE": "smb_enable",
        "DOCKER_ENABLE": "docker_enable",
        "SNAPRAID_ENABLE": "snapraid_enable",
        "BTRBK_ENABLE": "btrbk_enable",
    }
    attr = mapping.get(key)
    if attr:
        if attr in {"data_disks", "data_disk_labels"} and isinstance(value, str):
            value = [item.strip() for item in value.split(",") if item.strip()]
        setattr(config, attr, value)


def load_config(env_file: Path) -> Config:
    config = Config()
    if env_file.exists():
        parse_env_file(env_file, config)
        log(f"Loaded private config: {env_file}")
    elif EXAMPLE_ENV_FILE.exists():
        warn(f"Private config not found: {env_file}")
        warn("Create it with: cp .env.example .env")
        parse_env_file(EXAMPLE_ENV_FILE, config)
    else:
        warn("No env file found; using built-in placeholders.")
    return config


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="hosts/nas/bootstrap-nas.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "Safe Arch NAS bootstrap. Dry-run is the default. Formatting requires\n"
            f'exact interactive confirmation: "{CONFIRM_PHRASE}".'
        ),
        epilog=(
            "Common first run:\n"
            "  cp .env.example .env\n"
            "  sudo hosts/nas/bootstrap-nas.py --dry-run --all\n\n"
            "Apply the full NAS host setup:\n"
            "  sudo hosts/nas/bootstrap-nas.py --apply --all\n\n"
            "Minimal Arch install from the ISO with existing partitions:\n"
            "  sudo hosts/nas/bootstrap-nas.py --apply --install-arch \\\n"
            "    --efi-partition /dev/disk/by-id/REPLACE_ME-part1 \\\n"
            "    --root-partition /dev/disk/by-id/REPLACE_ME-part2"
        ),
    )
    parser.set_defaults(apply=False)
    parser.add_argument(
        "--dry-run",
        action="store_false",
        dest="apply",
        help="Print planned actions; do not mutate anything. Default.",
    )
    parser.add_argument("--apply", action="store_true", help="Apply requested phases.")
    parser.add_argument(
        "--partition-os-disk",
        action="store_true",
        help="Permit partitioning OS disk in Arch ISO install phase.",
    )
    parser.add_argument(
        "--start-services",
        action="store_true",
        help="Start services after enabling them where supported.",
    )
    parser.add_argument(
        "--install-arch",
        action="store_true",
        help="Install minimal Arch to TARGET_ROOT from the live ISO.",
    )
    parser.add_argument(
        "--packages",
        action="store_true",
        help="Install official packages, create NAS user/group, install yay, then install AUR packages.",
    )
    parser.add_argument(
        "--storage",
        action="store_true",
        help="Configure btrfs data disks, fstab, and mergerfs.",
    )
    parser.add_argument(
        "--services",
        action="store_true",
        help="Configure SnapRAID, btrbk, Docker, Samba, Tailscale, firewall notes, and alert placeholders.",
    )
    parser.add_argument(
        "--enable-services",
        action="store_true",
        help="Enable systemd services/timers selected by phases.",
    )
    parser.add_argument(
        "--validate", action="store_true", help="Run read-only validation checks."
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Run packages, storage, services, and enable-services. Does not install Arch or start services.",
    )
    parser.add_argument(
        "--env-file",
        default=str(DEFAULT_ENV_FILE),
        help="Load private env file. Default .env.",
    )
    parser.add_argument("--os-disk", help="Stable /dev/disk/by-id OS disk path.")
    parser.add_argument("--efi-partition", help="EFI partition path.")
    parser.add_argument("--root-partition", help="Root partition path.")
    parser.add_argument("--target-root", help="Install mountpoint, default /mnt.")
    return parser


def normalize_args(args: argparse.Namespace) -> argparse.Namespace:
    if len(sys.argv) == 1:
        args.validate = True
    if args.all:
        args.packages = True
        args.storage = True
        args.services = True
        args.enable_services = True
    return args


def apply_cli_overrides(args: argparse.Namespace, config: Config) -> None:
    if args.os_disk:
        config.os_disk = args.os_disk
    if args.efi_partition:
        config.efi_partition = args.efi_partition
    if args.root_partition:
        config.root_partition = args.root_partition
    if args.target_root:
        config.target_root = args.target_root


def main() -> None:
    parser = build_parser()
    args = normalize_args(parser.parse_args())
    config = load_config(Path(args.env_file))
    apply_cli_overrides(args, config)
    Bootstrap(args, config).main()


if __name__ == "__main__":
    main()
