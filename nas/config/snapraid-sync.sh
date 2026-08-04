#!/bin/bash
# Guarded snapraid sync wrapper
set -euo pipefail

# Accommodate normal batch conversions/renames (notably photo-library repairs)
# while still stopping a meaningful unexpected deletion set for review.
THRESHOLD=250
FORCE=false
LOCK_FILE=/run/lock/snapraid-operation.lock

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another SnapRAID operation is active; skipping this sync."
    /usr/local/sbin/nas-notify snapraid-sync \
        "Sync skipped because another SnapRAID operation holds $LOCK_FILE." || true
    exit 0
fi

# Check for force flag
for arg in "$@"; do
    if [[ "$arg" == "--force" || "$arg" == "-f" ]]; then
        FORCE=true
    fi
done

# Run diff and check for deleted files
echo "Running snapraid diff..."
diff_out=$(snapraid diff 2>&1 || true)

if echo "$diff_out" | grep -q "WARNING! Ignoring mount point"; then
    echo "ERROR: SnapRAID is ignoring one or more mount points."
    echo "This usually means a data path contains Btrfs subvolumes or nested mounts"
    echo "that SnapRAID will not protect from the parent path."
    echo "$diff_out"
    exit 3
fi

removed_count=$(echo "$diff_out" | awk '/^[[:space:]]*[0-9]+[[:space:]]+removed/ {print $1}')

if [[ -z "$removed_count" ]]; then
    # If there is no "removed" line (or if diff ran without differences), it means 0 deleted files
    if echo "$diff_out" | grep -q "No differences"; then
        removed_count=0
    else
        echo "ERROR: Could not parse snapraid diff output."
        echo "$diff_out"
        exit 1
    fi
fi

# The cross-disk Docker-state backup atomically replaces its `current` copies.
# Those replicas remain parity-protected, but their expected cache/log/database
# rotation must not mask a large removal elsewhere in the protected pool.
docker_state_removed_count="$(printf '%s\n' "$diff_out" |
    awk '/^remove[[:space:]]+backups\/docker-state\/[^/]+\/current\// {count++} END {print count + 0}')"
guard_removed_count=$((removed_count - docker_state_removed_count))

echo "Files to be removed: $removed_count ($docker_state_removed_count expected Docker-state replica churn; $guard_removed_count subject to safety threshold)"

if [[ "$guard_removed_count" -gt "$THRESHOLD" ]]; then
    if [[ "$FORCE" == "true" ]]; then
        echo "Warning: Guarded deletion count ($guard_removed_count) exceeds threshold ($THRESHOLD), but force is enabled. Proceeding with sync..."
    else
        echo "ERROR: Guarded deletion count ($guard_removed_count) exceeds safety threshold ($THRESHOLD)!"
        echo "Sync aborted to prevent accidental data loss."
        echo "Run manually with '--force' or '-f' if this deletion is intentional."
        exit 2
    fi
fi

echo "Running snapraid sync..."
# Docker backup fragments can contain same-name, same-size, same-timestamp
# database files with different contents on separate mergerfs branches. Disable
# copy detection so SnapRAID hashes each file instead of assuming they match.
exec snapraid --force-nocopy sync
