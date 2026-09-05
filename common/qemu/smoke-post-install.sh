#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
test -f /etc/os-release
test -d /run/systemd/system
test -r /repo/pc/bin/bootstrap-pc.sh
test -r /repo/nas/bootstrap-nas.sh
findmnt /repo
bash -n /repo/pc/bin/bootstrap-pc.sh /repo/nas/bootstrap-nas.sh
printf 'Installed guest can execute post-install tests as root.\n'
