#!/bin/bash
# Sync the NAS Minecraft replica to the PC and MacBook.
# An offline target is skipped, not a failure: there is nothing to sync to.
SRC="/data/replicas/minecraft/"
KEY="/home/chilly/.ssh/minecraft_sync"
PC="chilly@100.91.239.107"
MAC="chilly@100.89.119.15"
DEST="minecraft/"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)
RSYNC_SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

fail=0
for host in "$PC" "$MAC"; do
  if ! ssh "${SSH_OPTS[@]}" "$host" true >/dev/null 2>&1; then
    echo "$(date -Iseconds) SKIP $host: unreachable"
    continue
  fi
  if ! /usr/bin/rsync -az --delete -e "$RSYNC_SSH" "$SRC" "$host:$DEST"; then
    echo "$(date -Iseconds) FAIL $host: rsync error"
    fail=1
  fi
done
exit "$fail"
