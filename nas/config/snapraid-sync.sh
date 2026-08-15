#!/bin/bash
# Guarded snapraid sync wrapper
set -euo pipefail

# Accommodate normal batch conversions/renames (notably photo-library repairs)
# while still stopping a meaningful unexpected deletion set for review.
THRESHOLD=250
FORCE=false
FORCE_ZERO=false
LOCK_FILE=${SNAPRAID_LOCK_FILE:-/run/lock/snapraid-operation.lock}
SNAPRAID_CONF=${SNAPRAID_CONF:-/etc/snapraid.conf}

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
    elif [[ "$arg" == "--force-zero" || "$arg" == "-Z" ]]; then
        FORCE_ZERO=true
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

mapfile -t data_roots < <(
    awk '$1 == "data" {print $3}' "$SNAPRAID_CONF"
)

if [[ "${#data_roots[@]}" -eq 0 ]]; then
    echo "ERROR: Could not find any SnapRAID data roots in $SNAPRAID_CONF."
    exit 1
fi

# PostgreSQL and other application databases can legitimately truncate files to
# zero bytes. The cross-disk backup preserves those files in an atomically
# replaced `current` replica, but SnapRAID requires --force-zero before it will
# record a nonzero-to-zero transition. Automatically allow that transition only
# inside these stable Docker-state replicas; keep the normal safety stop for
# every other protected path.
zero_update_paths=()
unsafe_zero_update_paths=()
while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue

    for data_root in "${data_roots[@]}"; do
        candidate="${data_root%/}/$relative_path"
        if [[ -f "$candidate" && ! -s "$candidate" ]]; then
            zero_update_paths+=("$relative_path")
            if [[ ! "$relative_path" =~ ^backups/docker-state/[^/]+/current/ ]]; then
                unsafe_zero_update_paths+=("$relative_path")
            fi
            break
        fi
    done
done < <(printf '%s\n' "$diff_out" | sed -n 's/^update[[:space:]]\+//p')

if [[ "${#unsafe_zero_update_paths[@]}" -gt 0 && "$FORCE_ZERO" != "true" ]]; then
    echo "ERROR: Refusing to sync unexpected zero-byte updates outside Docker-state current replicas:"
    printf '  %s\n' "${unsafe_zero_update_paths[@]}"
    echo "Review these files, then rerun with '--force-zero' or '-Z' only if the changes are intentional."
    exit 4
fi

if [[ "${#zero_update_paths[@]}" -gt 0 ]]; then
    if [[ "${#unsafe_zero_update_paths[@]}" -eq 0 ]]; then
        echo "Allowing ${#zero_update_paths[@]} expected zero-byte Docker-state replica update(s)."
    else
        echo "Warning: Explicitly allowing ${#zero_update_paths[@]} reviewed zero-byte update(s)."
    fi
    FORCE_ZERO=true
fi

echo "Running snapraid sync..."
# Docker backup fragments can contain same-name, same-size, same-timestamp
# database files with different contents on separate mergerfs branches. Disable
# copy detection so SnapRAID hashes each file instead of assuming they match.
sync_args=(--force-nocopy)
if [[ "$FORCE_ZERO" == "true" ]]; then
    sync_args+=(--force-zero)
fi
exec snapraid "${sync_args[@]}" sync
