DEFAULT_ENV_FILE="$PC_ROOT/.env"
EXAMPLE_ENV_FILE="$PC_ROOT/.env.example"
PACKAGE_FILE="$PC_ROOT/packages.txt"
AUR_PACKAGE_FILE="$PC_ROOT/aur-packages.txt"
STAGING_DIR="$PC_ROOT/.work/bootstrap"
CONFIRM_PHRASE="yes, do as I say"

TARGET_MODE="host"
TARGET_ROOT="/mnt"

APPLY=false
INSTALL_ARCH=false
PARTITION_OS_DISK=false
PACKAGES=false
SYSTEM=false
SERVICES=false
ENABLE_SERVICES=false
START_SERVICES=false
CHECK_LIVE_TARGET=false
CHECK_HEALTH=false
ALL=false
INIT_ENV=false
LIST_DISKS=false

ENV_FILE="$DEFAULT_ENV_FILE"
CLI_TARGET_MODE=""
CLI_TARGET_ROOT=""
LOADED_REAL_ENV=false
LOADED_EXAMPLE_ENV=false
DESTRUCTIVE_CONFIRMED=false

PC_HOSTNAME="REPLACE_ME_HOSTNAME"
PC_USER="REPLACE_ME_USERNAME"
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"
KEYMAP="us"
OS_DISK="/dev/disk/by-id/REPLACE_ME_OS_DISK"
EFI_PARTITION="/dev/disk/by-id/REPLACE_ME_OS_DISK-part1"
ROOT_PARTITION="/dev/disk/by-id/REPLACE_ME_OS_DISK-part2"
BOOTLOADER="grub"
GRUB_BOOTLOADER_ID="Arch"
KERNEL_PACKAGE="linux"
KERNEL_HEADERS_PACKAGE="linux-headers"
MICROCODE_PACKAGE="amd-ucode"
INSTALL_MICROCODE="true"
BTRFS_OS_MOUNT_OPTS="rw,noatime,compress=zstd:1"
OS_SUBVOL_TEMP_MOUNT="/run/pc-bootstrap-rootfs"
ROOT_SUBVOL_LAYOUT=(
  "@|/"
  "@home|/home"
  "@root|/root"
  "@srv|/srv"
  "@cache|/var/cache"
  "@tmp|/var/tmp"
  "@log|/var/log"
  "@snapshots|/.snapshots"
)
USER_SUPPLEMENTAL_GROUPS=(
  wheel
  network
  libvirt
  audio
  video
  storage
  lp
  rfkill
  docker
  users
  nopasswdlogin
)
ENABLE_UFW="true"
ENABLE_SYSTEMD_TIMESYNCD="true"
ENABLE_SYSTEMD_RESOLVED="true"
ENABLE_NETWORKMANAGER="true"
ENABLE_BLUETOOTH="true"
ENABLE_LIBVIRTD="true"
ENABLE_LY="true"
LY_UNIT="ly@tty2.service"
ENABLE_AVAHI="true"
ENABLE_FSTRIM_TIMER="true"
ENABLE_SMARTD="false"
ENABLE_NFTABLES="false"
ENABLE_PODMAN="true"
ENABLE_DISTROBOX="true"
ENABLE_FIREFOX="true"
ENABLE_ZSH="true"
START_SERVICES_AFTER_ENABLE="false"
ALLOW_RAW_DEV_PATHS="false"
ALLOW_QEMU_DEVICE_NAMES="false"
DISK_LAYOUT_REVIEWED="false"
VALIDATE_WRITE_TESTS="true"

declare -a PACMAN_PACKAGES=()
declare -a AUR_PACKAGES=()
declare -A AUR_PACKAGE_VERSIONS=()
