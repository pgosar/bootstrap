#!/bin/bash
# Guarded snapraid sync wrapper
set -euo pipefail

THRESHOLD=50
FORCE=false

# Check for force flag
for arg in "$@"; do
    if [[ "$arg" == "--force" || "$arg" == "-f" ]]; then
        FORCE=true
    fi
done

# Run diff and check for deleted files
echo "Running snapraid diff..."
diff_out=$(snapraid diff 2>&1 || true)
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

echo "Files to be removed: $removed_count"

if [[ "$removed_count" -gt "$THRESHOLD" ]]; then
    if [[ "$FORCE" == "true" ]]; then
        echo "Warning: Deletion count ($removed_count) exceeds threshold ($THRESHOLD), but force is enabled. Proceeding with sync..."
    else
        echo "ERROR: Deletion count ($removed_count) exceeds safety threshold ($THRESHOLD)!"
        echo "Sync aborted to prevent accidental data loss."
        echo "Run manually with '--force' or '-f' if this deletion is intentional."
        exit 2
    fi
fi

echo "Running snapraid sync..."
exec snapraid sync
