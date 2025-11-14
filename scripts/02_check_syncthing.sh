#!/usr/bin/env bash
# MENU_SHOW: yes
# MENU_SECTION: main
# MENU_POSITION: 3
# MENU_NAME: Check Syncthing Sync
# MENU_DESC: Wait until Syncthing finishes syncing the batch directory
# MENU_HELP: Polls Syncthing API using ST_URL and ST_API_KEY; uses ST_FOLDER_ID from config.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../05_config.sh"

LOG="$LOG_DIR/syncthing_check.log"
mkdir -p "$LOG_DIR"
log() { echo "$(date --iso-8601=seconds) - $*" | tee -a "$LOG"; }

# validate syncthing reachable
if ! curl -s -H "X-API-Key: $ST_API_KEY" "$ST_URL/system/status" >/dev/null; then
  log "ERROR: Syncthing unreachable or invalid API key (try curl -H 'X-API-Key:...' $ST_URL/system/status)"
  exit 2
fi

# validate folder exists in config
conf_json=$(curl -s -H "X-API-Key: $ST_API_KEY" "$ST_URL/config")
folder_path=$(echo "$conf_json" | jq -r --arg id "$ST_FOLDER_ID" '.folders[] | select(.id == $id) | .path // empty')

if [ -z "$folder_path" ]; then
  # try to find a folder with path == BATCH_DIR or trailing slash
  folder_path=$(echo "$conf_json" | jq -r --arg path "$BATCH_DIR" '.folders[] | select(.path == $path or .path == ($path + "/")) | .id' | head -n1)
  if [ -n "$folder_path" ]; then
    ST_FOLDER_ID="$folder_path"
  else
    log "ERROR: ST_FOLDER_ID $ST_FOLDER_ID not present in Syncthing config."
    exit 3
  fi
fi

log "Monitoring Syncthing folder id: $ST_FOLDER_ID (path: $(echo "$conf_json" | jq -r --arg id "$ST_FOLDER_ID" '.folders[] | select(.id == $id) | .path'))"

start=$(date +%s)
while true; do
  json=$(curl -s -H "X-API-Key: $ST_API_KEY" "$ST_URL/db/status?folder=$ST_FOLDER_ID" || echo "{}")

  need=$(echo "$json" | jq -r '.needTotalItems // -1')
  state=$(echo "$json" | jq -r '.state // "unknown"')
  errors=$(echo "$json" | jq -r '.errors // 0')

  log "State=$state | NeedTotalItems=$need | Errors=$errors"

  if [[ "$need" == "0" && "$state" == "idle" ]]; then
    log "✅ Folder is fully synced!"
    exit 0
  fi

  if [[ "$errors" != "0" ]]; then
    log "⚠️ Syncthing reported errors!"
  fi

  now=$(date +%s)
  if (( now - start > ST_POLL_TIMEOUT )); then
    log "❌ Timeout waiting for sync!"
    exit 1
  fi

  sleep "$ST_POLL_INTERVAL"
done
