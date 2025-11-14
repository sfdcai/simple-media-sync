# MENU_NAME: _init_sqlite
# MENU_DESC: No description yet
# MENU_SHOW: no
# MENU_SECTION: main
# MENU_POSITION: 10
#!/usr/bin/env bash
# _init_sqlite.sh - initialize SQLite DB schema (idempotent)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# load central config (project root expected to contain 05_config.sh)
source "$SCRIPT_DIR/../05_config.sh"

mkdir -p "$(dirname "$DB_PATH")"
if [ ! -f "$DB_PATH" ]; then
  echo "Initializing sqlite DB at $DB_PATH"
  "$SQLITE3_BIN" "$DB_PATH" <<'SQL'
BEGIN;
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
COMMIT;
SQL
else
  echo "DB already exists: $DB_PATH"
fi
