#!/usr/bin/env bash
set -uo pipefail

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
