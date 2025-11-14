#!/usr/bin/env bash
# MENU_SHOW: yes
# MENU_SECTION: plugin
# MENU_POSITION: 2
# MENU_NAME: Collect Debug
# MENU_DESC: Gather logs, system info, syncthing status, sqlite DB info into one archive
# MENU_HELP: Produces debug tarball in /tmp with timestamps for sharing/troubleshooting.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../05_config.sh"

OUTDIR="/tmp/media-batcher-debug-$(date +%Y%m%d%H%M%S)"
mkdir -p "$OUTDIR"

echo "Collecting logs to $OUTDIR"

# copy logs
cp -a "$LOG_DIR" "$OUTDIR/" 2>/dev/null || true

# sqlite DB info
if [ -f "$DB_PATH" ]; then
  echo "SQLite schema and counts" > "$OUTDIR/sqlite_info.txt"
  echo "Tables:" >> "$OUTDIR/sqlite_info.txt"
  sqlite3 "$DB_PATH" ".schema" >> "$OUTDIR/sqlite_info.txt" 2>/dev/null || true
  echo "" >> "$OUTDIR/sqlite_info.txt"
  sqlite3 "$DB_PATH" "SELECT count(*) FROM files;" >> "$OUTDIR/sqlite_info.txt" 2>/dev/null || true
fi

# syncthing status
if curl -s -H "X-API-Key: $ST_API_KEY" "$ST_URL/system/status" > "$OUTDIR/syncthing_status.json" 2>/dev/null; then
  echo "Syncthing status saved"
fi

if curl -s -H "X-API-Key: $ST_API_KEY" "$ST_URL/config" > "$OUTDIR/syncthing_config.json" 2>/dev/null; then
  echo "Syncthing config saved"
fi

# process snapshots
ps aux > "$OUTDIR/ps_aux.txt"
ss -tulnp > "$OUTDIR/ss.txt" 2>/dev/null || true

# list scripts and permissions
ls -l "$SCRIPT_DIR" > "$OUTDIR/scripts_list.txt"

# tarball
tar czf "/tmp/media-batcher-debug-$(date +%Y%m%d%H%M%S).tar.gz" -C /tmp "$(basename "$OUTDIR")"
echo "Debug archive created: /tmp/media-batcher-debug-*.tar.gz"
