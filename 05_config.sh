# Safe defaults (won't override existing settings if present)
: "${SQLITE_WEB_PORT:=4000}"
: "${ST_POLL_INTERVAL:=10}"

#!/usr/bin/env bash
# Central configuration for media batcher
# Edit these to match your environment
SKIP_ARCHIVE_ROOT="/mnt/wd_all_pictures/SKIPPED"
SKIP_DUPLICATE_ROOT="$SKIP_ARCHIVE_ROOT/duplicates"
mkdir -p "$SKIP_ARCHIVE_ROOT" "$SKIP_DUPLICATE_ROOT"

skipped_ext=0
skipped_name=0
skipped_path=0
skipped_dupes=0

# Source of media (where original photos/videos live)
SOURCE_DIR="/mnt/wd_all_pictures/Synced_Sorted_Pics/2007/"

# Staging directory for a single batch
BATCH_DIR="/mnt/wd_all_pictures/BATCH_STAGE/current_batch/"

# Archive root where sorted files land
ARCHIVE_DIR="/mnt/wd_all_pictures/Synced_Sorted_Pics/"

# Logs and DB
LOG_DIR="/var/log/media-batcher"
DB_PATH="$LOG_DIR/media_meta.sqlite3"

# Batch controls
BATCH_SIZE_GB=9       # primary: batch by size
BATCH_FILE_COUNT=0    # fallback: batch by number if size threshold not hit (set 0 to disable)
DRY_RUN=false          # set to true for dry-run (no copies/moves)

# Hashing config (hybrid mode): size of head/tail in bytes
HASH_HEAD_TAIL_BYTES=$((5 * 1024 * 1024))  # 5MB head + 5MB tail

# Transfer orchestration (syncthing or scp)
TRANSFER_METHOD="syncthing"   # accepted values: "syncthing" or "scp"

# Syncthing REST API (used when TRANSFER_METHOD="syncthing")
ST_URL="http://192.168.1.102:8384/rest"
ST_API_KEY="yEPu9sGF3mvg2pMDDG3mdsTrWWpW9y33"
ST_FOLDER_ID="1rnqu-tho7f"   # syncthing folder ID for the BATCH_DIR
ST_POLL_INTERVAL=10          # seconds between checks
ST_POLL_TIMEOUT=3600         # seconds to give a folder to finish syncing

# SCP transfer configuration (used when TRANSFER_METHOD="scp")
SCP_USER="android"
SCP_HOST="192.168.1.150"
SCP_PORT=8022
SCP_REMOTE_PATH="/sdcard/DCIM/MediaBatch"
# optional identity file for key-based auth (leave empty to use default agent/ssh config)
SCP_IDENTITY_FILE=""

# SQLite Web UI Port (optional, but safe default)
SQLITE_WEB_PORT=4000
export SQLITE_WEB_PORT=${SQLITE_WEB_PORT:-4000}

# Utilities
CP_CMD="mv"
# to copy use this -> CP_CMD="rsync -rltDv --info=progress2 --partial --inplace --no-perms --no-owner --no-group --no-times"
SQLITE3_BIN="sqlite3"

# Ensure directories exist
mkdir -p "$BATCH_DIR" "$LOG_DIR" "$ARCHIVE_DIR"

# ARCHIVE RULES
ALLOW_EXTENSIONS=("jpg" "jpeg" "png" "mp4" "mov" "heic" "gif" "avi" "mkv")

EXCLUDE_NAMES=(
  ".stfolder"
  ".stfolder.removed"
  "@eaDir"
  "Thumbs.db"
  ".DS_Store"
  "lost+found"
  "DO_NOT_DELETE.txt"
)

EXCLUDE_PATHS=(
  "/@eaDir/"
  "/.stfolder"
  "/.sync"
  "/.git/"
)

