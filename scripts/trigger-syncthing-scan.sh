#!/usr/bin/env bash
# MENU_SHOW: yes
# MENU_SECTION: main
# MENU_POSITION: 2
# MENU_NAME: Initiate Sync
# MENU_DESC: sends signal to syncthing to initiate sync
# MENU_HELP: Produces debug tarball in /tmp with timestamps for sharing/troubleshooting.

# === Load central config ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/05_config.sh" || { echo "❌ Failed to load config"; exit 1; }

LOG="$LOG_DIR/trigger-syncthing-scan.log"
mkdir -p "$LOG_DIR"

echo "[$(date)] 🚀 Triggering Syncthing scan for folder: $ST_FOLDER_ID" | tee -a "$LOG"

# === Validate config values ===
[[ -z "$ST_URL" || -z "$ST_API_KEY" || -z "$ST_FOLDER_ID" ]] && {
  echo "❌ Syncthing config missing in 05_config.sh" | tee -a "$LOG"
  exit 1
}

# === Trigger scan ===
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST -H "X-API-Key: $ST_API_KEY" "$ST_URL/db/scan?folder=$ST_FOLDER_ID")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "❌ Failed to trigger scan (HTTP $HTTP_CODE)" | tee -a "$LOG"
  exit 1
fi

echo "✅ Scan triggered successfully!" | tee -a "$LOG"

# === Wait and show progress ===
echo "⏳ Monitoring scan progress..." | tee -a "$LOG"
while true; do
  STATUS=$(curl -s -H "X-API-Key: $ST_API_KEY" "$ST_URL/db/status?folder=$ST_FOLDER_ID")
  STATE=$(echo "$STATUS" | jq -r '.state')
  NEED=$(echo "$STATUS" | jq -r '.needFiles')
  echo "  → State: $STATE | Pending files: $NEED"

  if [[ "$STATE" == "idle" && "$NEED" == "0" ]]; then
    echo "✅ Sync up-to-date and idle." | tee -a "$LOG"
    break
  fi

  sleep 3
done

echo "🎉 Scan completed!" | tee -a "$LOG"
