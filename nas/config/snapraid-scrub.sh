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

sync_result="$(systemctl show snapraid-sync.service -p Result --value 2>/dev/null || true)"
if [[ "$sync_result" != "success" ]]; then
  printf 'Scrub deferred because the latest SnapRAID sync result is %s.\n' "${sync_result:-unknown}" >&2
  /usr/local/sbin/nas-notify snapraid-scrub \
    "Weekly scrub deferred because the latest snapraid-sync.service result is ${sync_result:-unknown}. Resolve the sync failure, then rerun the scrub." || true
  exit 0
fi

output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

/usr/bin/snapraid scrub -p 12 -o 10 2>&1 | tee "$output_file"
status="${PIPESTATUS[0]}"

if (( status != 0 )); then
  summary="$(tail -n 12 "$output_file")"
  # SnapRAID exits non-zero for every error class, including soft errors:
  # files that changed since the last sync, which are expected in the gap
  # between the daily sync and this weekly scrub. Only data errors (failed
  # integrity checks) and io errors (disk read failures) are real failures.
  # If the summary counts cannot be parsed, fall through to failure.
  soft_errors="$(grep -oE '[0-9]+ soft errors' "$output_file" | tail -n 1 | grep -oE '^[0-9]+')"
  io_errors="$(grep -oE '[0-9]+ io errors' "$output_file" | tail -n 1 | grep -oE '^[0-9]+')"
  data_errors="$(grep -oE '[0-9]+ data errors' "$output_file" | tail -n 1 | grep -oE '^[0-9]+')"
  if [[ -n "$soft_errors" && -n "$io_errors" && -n "$data_errors" ]] \
    && (( io_errors == 0 && data_errors == 0 )); then
    /usr/local/sbin/nas-notify snapraid-scrub \
      "Weekly 12% scrub completed with warnings: $soft_errors soft errors (files changed since the last sync); no data or io errors."$'\n'"$summary" || true
    exit 0
  fi
  /usr/local/sbin/nas-notify snapraid-scrub \
    "Weekly 12% scrub failed with exit status $status."$'\n'"$summary" || true
fi

exit "$status"
