#!/usr/bin/env bash
# MENU_SHOW: yes
# MENU_SECTION: plugin
# MENU_POSITION: 1
# MENU_NAME: Setup Environment
# MENU_DESC: Install dependencies and validate runtime environment
# MENU_HELP: Ensures DB, tools, web UI, permissions, and folders are configured.

set -euo pipefail

echo "🚀 Media Batcher Setup & Verification Starting..."

LOG_DIR="/var/log/media-batcher"
DB_PATH="$LOG_DIR/media_meta.sqlite3"
DEBUG_LOG="$LOG_DIR/debug.log"

mkdir -p "$LOG_DIR"

log() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$DEBUG_LOG"
}

log "Checking system..."

sudo apt update -y
sudo apt install -y sqlite3 jq curl rsync python3 pipx libimage-exiftool-perl parallel net-tools

export PIPX_HOME="/root/.local/pipx"
export PIPX_BIN_DIR="/root/.local/bin"
export PATH="$PATH:$PIPX_BIN_DIR"

if ! command -v sqlite_web >/dev/null; then
  log "Installing sqlite-web using pipx..."
  pipx install sqlite-web || true
fi

if ! command -v sqlite_web >/dev/null; then
  log "ERROR: sqlite_web still not found"
  exit 1
fi

log "sqlite_web found ✅"

log "Killing old sqlite_web instances if any..."
pkill -f sqlite_web || true
pkill -f sqlite-web || true
sleep 2

log "Setting up SQLite DB..."
sqlite3 "$DB_PATH" <<EOF
CREATE TABLE IF NOT EXISTS files (
  id INTEGER PRIMARY KEY,
  file_path TEXT UNIQUE,
  file_name TEXT,
  size_bytes INTEGER,
  hash TEXT,
  exif_date TEXT,
  batch_id TEXT,
  synced INTEGER DEFAULT 0,
  archived INTEGER DEFAULT 0,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_hash ON files(hash);
CREATE INDEX IF NOT EXISTS idx_archived ON files(archived);
EOF

# Find free port
for port in 3000 4000 5000 6000 7000 8000 8080 9000; do
  if ! ss -tuln | grep -q ":$port "; then
    DB_PORT=$port
    break
  fi
done

[[ -z "${DB_PORT:-}" ]] && { log "No free port found"; exit 1; }

log "Launching SQLite Web UI on port $DB_PORT..."
nohup sqlite_web "$DB_PATH" --port "$DB_PORT" --host 0.0.0.0 > "$LOG_DIR/sqlite_web.log" 2>&1 &
sleep 3

# Verify Web UI is reachable
if curl -s --head "http://127.0.0.1:$DB_PORT" | grep -q "200 OK" || \
   curl -s --head "http://$(hostname -I | awk '{print $1}'):$DB_PORT" | grep -q "200 OK"; then
  log "✅ Web UI is reachable!"
  log "📌 Open in browser: http://$(hostname -I | awk '{print $1}'):$DB_PORT"
else
  log "❌ Web UI failed to start!"
  exit 1
fi

# Correct hash test
echo -n "hello" > /tmp/hash_test
HASH=$(sha256sum /tmp/hash_test | awk '{print $1}')
EXPECTED="2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
rm -f /tmp/hash_test

if [[ "$HASH" == "$EXPECTED" ]]; then
  log "Hash test passed ✅"
else
  log "Hash test failed ❌ (Actual: $HASH)"
  exit 1
fi

log "🎉 Setup complete!"
echo ""
echo "📌 Web UI: http://$(hostname -I | awk '{print $1}'):$DB_PORT"
echo "📌 Debug Log: $DEBUG_LOG"
echo ""
echo "Run next: ./04_menu.sh"
echo ""
tail -n 200 -f "$DEBUG_LOG"
