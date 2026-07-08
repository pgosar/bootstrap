#!/usr/bin/env bash
set -euo pipefail

TDARR_URL="${TDARR_URL:-http://nas:8266}"
TDARR_API_KEY="${TDARR_API_KEY:-}"
TDARR_ENV_FILE="${TDARR_ENV_FILE:-/data/docker/compose/tdarr/.env}"
ENSURE_SCRIPT="${ENSURE_SCRIPT:-/data/docker/compose/nightly-orchestrator/pc-worker-ensure.sh}"
LOG_FILE="${LOG_FILE:-/data/docker/appdata/nightly-orchestrator/tdarr-wake-monitor.log}"
LOCK_FILE="${LOCK_FILE:-/tmp/tdarr-wake-monitor.lock}"
PC_HOST="${PC_HOST:-pc}"
PC_WORKER_DIR="${PC_WORKER_DIR:-~/docker/pc-workers}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"
NIGHT_START="${NIGHT_START:-04:00}"
NIGHT_END="${NIGHT_END:-10:00}"
STOP_WORKERS_OUTSIDE_WINDOW="${STOP_WORKERS_OUTSIDE_WINDOW:-true}"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE"
}

load_api_key() {
  if [ -n "$TDARR_API_KEY" ]; then
    return 0
  fi
  if [ -f "$TDARR_ENV_FILE" ]; then
    TDARR_API_KEY="$(awk -F= '/^TDARR_API_KEY=/{print $2}' "$TDARR_ENV_FILE" | tail -1)"
  fi
  if [ -z "$TDARR_API_KEY" ] && [ -f /data/docker/appdata/tdarr/configs/Tdarr_Server_Config.json ]; then
    TDARR_API_KEY="$(jq -r '.seededApiKey // empty' /data/docker/appdata/tdarr/configs/Tdarr_Server_Config.json)"
  fi
  [ -n "$TDARR_API_KEY" ]
}

tdarr_post() {
  curl -fsS --max-time 15 \
    -H "x-api-key: $TDARR_API_KEY" \
    -H "Content-Type: application/json" \
    "$TDARR_URL/api/v2/cruddb" \
    -d "$1"
}

minutes_since_midnight() {
  local value="$1"
  printf '%d\n' "$((10#${value%:*} * 60 + 10#${value#*:}))"
}

in_night_window() {
  local now start end
  now="$(minutes_since_midnight "$(date +%H:%M)")"
  start="$(minutes_since_midnight "$NIGHT_START")"
  end="$(minutes_since_midnight "$NIGHT_END")"

  if [ "$start" -eq "$end" ]; then
    return 0
  elif [ "$start" -lt "$end" ]; then
    [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
  else
    [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
  fi
}

pc_reachable() {
  ssh -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" "$PC_HOST" 'true' >/dev/null 2>&1
}

stop_pc_workers() {
  ssh -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" "$PC_HOST" \
    "cd $PC_WORKER_DIR && docker compose stop tdarr-node immich-machine-learning-pc >/dev/null 2>&1 || docker compose stop >/dev/null 2>&1"
}

has_work() {
  local queued
  queued="$(tdarr_post '{"data":{"collection":"FileJSONDB","mode":"getAll"}}' \
    | jq '[.[] | select((.TranscodeDecisionMaker == "Queued") or (.HealthCheck == "Queued"))] | length')"
  [ "${queued:-0}" -gt 0 ]
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

if ! load_api_key; then
  log "no Tdarr API key available"
  exit 1
fi

if ! in_night_window; then
  if [ "$STOP_WORKERS_OUTSIDE_WINDOW" = "true" ] && pc_reachable; then
    stop_pc_workers || log "failed to stop PC worker containers outside ${NIGHT_START}-${NIGHT_END}"
  fi
  exit 0
fi

if has_work; then
  log "Tdarr has queued/staged work; ensuring PC worker stack"
  CHECK_TDARR=true "$ENSURE_SCRIPT" >>"$LOG_FILE" 2>&1 || log "pc-worker-ensure failed"
fi
