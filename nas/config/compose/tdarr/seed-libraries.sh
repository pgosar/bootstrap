#!/usr/bin/env bash
set -euo pipefail

TDARR_URL="${TDARR_URL:-http://nas:8266}"
TDARR_ENV_FILE="${TDARR_ENV_FILE:-/data/docker/compose/tdarr/.env}"
TDARR_CONTAINER="${TDARR_CONTAINER:-tdarr}"

if [ -z "${TDARR_API_KEY:-}" ] && [ -f "$TDARR_ENV_FILE" ]; then
  TDARR_API_KEY="$(awk -F= '/^TDARR_API_KEY=/{print $2}' "$TDARR_ENV_FILE" | tail -1)"
fi

if [ -z "${TDARR_API_KEY:-}" ]; then
  echo "TDARR_API_KEY is required" >&2
  exit 1
fi

tdarr_post() {
  local data="${1:-}"
  if [ -z "$data" ]; then
    data="$(cat)"
  fi

  curl -fsS \
    -H "x-api-key: $TDARR_API_KEY" \
    -H "Content-Type: application/json" \
    "$TDARR_URL/api/v2/cruddb" \
    -d "$data"
}

library_exists() {
  local id="$1"
  tdarr_post '{"data":{"collection":"LibrarySettingsJSONDB","mode":"getAll"}}' \
    | jq -e --arg id "$id" 'any(.[]; ._id == $id)' >/dev/null
}

build_payload() {
  local mode="$1"
  local id="$2"
  local name="$3"
  local folder="$4"

  docker exec -i "$TDARR_CONTAINER" node - "$mode" "$id" "$name" "$folder" <<'NODE'
const mode = process.argv[2];
const id = process.argv[3];
const name = process.argv[4];
const folder = process.argv[5];
const defaults = require("/app/Tdarr_Server/srcug/commonModules/jobs/libraryDefaults.js");
const lib = {...(defaults.default || defaults)};

Object.assign(lib, {
  _id: id,
  name,
  folder,
  cache: "/temp",
  output: "",
  folderWatching: true,
  useFsEvents: true,
  scheduledScanFindNew: false,
  scanOnStart: false,
  processLibrary: true,
  processTranscodes: true,
  processHealthChecks: false,
  exifToolScan: false,
  mediaInfoScan: true,
  closedCaptionScan: false,
  ffprobeShowData: false,
  scannerThreadCount: 1,
  holdNewFiles: false,
  filterHardlinked: false,
  createdAt: Date.now()
});

process.stdout.write(JSON.stringify({
  data: {
    collection: "LibrarySettingsJSONDB",
    mode,
    docID: id,
    obj: lib
  }
}));
NODE
}

seed_library() {
  local id="$1"
  local name="$2"
  local folder="$3"
  local mode="insert"

  if library_exists "$id"; then
    mode="update"
  fi

  build_payload "$mode" "$id" "$name" "$folder" | tdarr_post >/dev/null
  printf 'seeded %s -> %s\n' "$name" "$folder"
}

seed_library "movies" "Movies" "/media/movies"
seed_library "tv" "TV" "/media/tv"
seed_library "anime-movies" "Anime Movies" "/media/anime-movies"
seed_library "anime-tv" "Anime TV" "/media/anime-tv"
