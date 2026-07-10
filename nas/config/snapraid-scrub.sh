#!/usr/bin/env bash
set -uo pipefail

LOCK_FILE=/run/lock/snapraid-operation.lock

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  printf 'Another SnapRAID operation is active; skipping this scrub.\n' >&2
  /usr/local/sbin/nas-notify snapraid-scrub \
    "Scrub skipped because another SnapRAID operation holds $LOCK_FILE." || true
  exit 0
fi

output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

/usr/bin/snapraid scrub -p 12 -o 10 2>&1 | tee "$output_file"
status="${PIPESTATUS[0]}"

if (( status != 0 )); then
  summary="$(tail -n 12 "$output_file")"
  /usr/local/sbin/nas-notify snapraid-scrub \
    "Weekly 12% scrub failed with exit status $status."$'\n'"$summary" || true
fi

exit "$status"
