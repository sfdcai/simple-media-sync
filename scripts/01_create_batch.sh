#!/usr/bin/env bash
# MENU_SHOW: yes
# MENU_SECTION: main
# MENU_POSITION: 1
# MENU_NAME: Create Batch
# MENU_DESC: Create a single batch from SOURCE_DIR into BATCH_DIR (size or count)
# MENU_HELP: Builds a batch folder, deduplicates using DB (hybrid hash head+tail+size),
#           copies files into batch directory, and records entries into DB.

set -euo pipefail

# ---- bootstrap ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/05_config.sh"

# Colors
C1=$'\033[1;36m'; C2=$'\033[1;32m'; C3=$'\033[1;33m'; C4=$'\033[1;31m'; CR=$'\033[0m'

# Ensure basic dirs exist
mkdir -p "$LOG_DIR" "$SKIP_ARCHIVE_ROOT" "$SKIP_DUPLICATE_ROOT" "$BATCH_DIR" "$ARCHIVE_DIR"

# Normalize batch dir to always point to 'current_batch'
BATCH_DIR="${BATCH_DIR%/}"
[[ "$(basename "$BATCH_DIR")" != "current_batch" ]] && BATCH_DIR="$BATCH_DIR/current_batch"
mkdir -p "$BATCH_DIR"

# Tools & cmds
SQLITE_BIN="${SQLITE3_BIN:-sqlite3}"
CP_CMD="${CP_CMD:-rsync -a --info=progress2 --partial --inplace}"
LOG="$LOG_DIR/create_batch.log"
DRY_RUN="${DRY_RUN:-false}"

# Counters
skipped_ext=0; skipped_name=0; skipped_path=0; skipped_dupes=0
current_bytes=0; current_count=0

# Batch id & limits
batch_id="batch_$(date +%Y%m%d_%H%M%S)"
SIZE_LIMIT_BYTES=$((BATCH_SIZE_GB * 1024 * 1024 * 1024))
# allow one file to overshoot to avoid tiny batch issues
overshoot_allowed=true

# Logging helper
log(){ echo -e "$(date --iso-8601=seconds) - $*" | tee -a "$LOG"; }

log "${C1}📦 Batch folder: $BATCH_DIR${CR}"
log "🎯 Target batch size: ${BATCH_SIZE_GB}GB ($SIZE_LIMIT_BYTES bytes) | DRY_RUN=$DRY_RUN"

# Ensure skipped_files table exists
"$SQLITE_BIN" "$DB_PATH" "CREATE TABLE IF NOT EXISTS skipped_files (
  id INTEGER PRIMARY KEY,
  original_path TEXT,
  file_name TEXT,
  reason TEXT,
  moved_to TEXT,
  batch_id TEXT,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);" >/dev/null 2>&1 || log "${C3}⚠ Could not create/check skipped_files table${CR}"

# Ensure files table exists minimally (if not present, create a simple structure)
"$SQLITE_BIN" "$DB_PATH" "CREATE TABLE IF NOT EXISTS files (
  id INTEGER PRIMARY KEY,
  source_path TEXT,
  batch_path TEXT,
  file_path TEXT UNIQUE,
  file_name TEXT,
  size_bytes INTEGER,
  hash TEXT,
  exif_date TEXT,
  batch_id TEXT,
  synced INTEGER DEFAULT 0,
  archived INTEGER DEFAULT 0,
  archived_at DATETIME,
  archived_path TEXT,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);" >/dev/null 2>&1

# Ensure required columns exist for legacy databases
ensure_column() {
  local table="$1" column="$2" definition="$3"
  if ! "$SQLITE_BIN" "$DB_PATH" "PRAGMA table_info($table);" | awk -F'|' '{print $2}' | grep -qx "$column"; then
    "$SQLITE_BIN" "$DB_PATH" "ALTER TABLE $table ADD COLUMN $definition;" >/dev/null 2>&1 || \
      log "${C3}⚠ Failed to add column $column to $table${CR}"
  fi
}

ensure_column files source_path "TEXT"
ensure_column files batch_path "TEXT"
ensure_column files exif_date "TEXT"
ensure_column files archived_at "DATETIME"
ensure_column files archived_path "TEXT"

# Hybrid hash function (head + tail + size)
compute_hybrid_hash() {
  local file="$1"
  local n="$HASH_HEAD_TAIL_BYTES"
  local tmp; tmp="$(mktemp)"
  # file size first for additional safety
  stat -c%s "$file" >>"$tmp" 2>/dev/null || echo "0" >>"$tmp"
  if [[ "$n" -gt 0 ]]; then
    # head
    dd if="$file" bs=1 count="$n" status=none 2>/dev/null >>"$tmp" || true
    # tail
    tail -c "$n" "$file" 2>/dev/null >>"$tmp" || true
  else
    # fallback: whole file if n == 0 (not recommended for big files)
    cat "$file" >>"$tmp"
  fi
  sha256sum "$tmp" | awk '{print $1}'
  rm -f "$tmp"
}

# DB duplicate checker
db_has_hash() {
  local h="$1"
  if "$SQLITE_BIN" "$DB_PATH" "SELECT 1 FROM files WHERE hash='${h}' LIMIT 1;" | grep -q 1; then
    return 0
  fi
  return 1
}

# Insert into files table
db_insert_file() {
  local src_path="$1" batch_path="$2" fname="$3" fsize="$4" fhash="$5" fbatch="$6"
  # escape single quotes for sqlite
  src_path=$(printf "%s" "$src_path" | sed "s/'/''/g")
  batch_path=$(printf "%s" "$batch_path" | sed "s/'/''/g")
  fname=$(printf "%s" "$fname" | sed "s/'/''/g")
  "$SQLITE_BIN" "$DB_PATH" "INSERT OR IGNORE INTO files (source_path,batch_path,file_path,file_name,size_bytes,hash,batch_id,archived,synced)
  VALUES ('$src_path','$batch_path','$batch_path','$fname',$fsize,'$fhash','$fbatch',0,0);"
}

# Move skipped files (ext, name, path, dupe)
move_skip() {
  local file="$1" reason="$2" batch="$3"
  local is_dupe=false
  [[ "$reason" == "dupe" ]] && is_dupe=true

  local fname ext dest_dir dest base n
  fname="$(basename "$file")"
  ext="${fname##*.}"; ext="${ext,,}"
  [[ "$fname" != *.* ]] && ext="noext"

  if [[ "$is_dupe" == true ]]; then
    dest_dir="${SKIP_DUPLICATE_ROOT%/}/$ext"
  else
    dest_dir="${SKIP_ARCHIVE_ROOT%/}/$ext"
  fi
  mkdir -p "$dest_dir"

  dest="$dest_dir/$fname"
  if [[ -e "$dest" ]]; then
    base="${fname%.*}"; n=1
    while [[ -e "$dest_dir/${base}-$n.$ext" ]]; do ((n++)); done
    dest="$dest_dir/${base}-$n.$ext"
  fi

  if [[ "$DRY_RUN" == "false" ]]; then
    mv -- "$file" "$dest"
  else
    log "${C3}DRY_RUN: Would mv '$file' -> '$dest'${CR}"
  fi

  # insert into skipped_files DB
  "$SQLITE_BIN" "$DB_PATH" "INSERT INTO skipped_files (original_path,file_name,reason,moved_to,batch_id)
  VALUES ('$(echo "$file" | sed "s/'/''/g")','$(echo "$fname" | sed "s/'/''/g")','$reason','$dest','$batch');" >/dev/null 2>&1 || true

  log "${C3}⏭ SKIPPED ($reason) → $dest${CR}"

  case "$reason" in
    ext)  ((skipped_ext++));;
    name) ((skipped_name++));;
    path) ((skipped_path++));;
    dupe) ((skipped_dupes++));;
  esac
}

# Decide skip reason
should_skip_reason() {
  local file="$1"
  local fname; fname="$(basename "$file")"

  # Exclude by name
  for s in "${EXCLUDE_NAMES[@]}"; do
    [[ "$fname" == *"$s"* ]] && echo "name" && return
  done

  # Exclude by path
  for p in "${EXCLUDE_PATHS[@]}"; do
    [[ "$file" == *"$p"* ]] && echo "path" && return
  done

  # Extension allow list
  local ext="${fname##*.}"; ext="${ext,,}"
  local allowed=false
  for a in "${ALLOW_EXTENSIONS[@]}"; do
    [[ "$ext" == "$a" ]] && allowed=true && break
  done
  [[ "$allowed" == "false" ]] && echo "ext" && return

  echo "ok"
}

# ----------------------
# MAIN loop (no subshell so counters persist)
# ----------------------
log "${C1}Starting scan of: $SOURCE_DIR${CR}"

# Use process substitution so we can iterate in current shell
while IFS= read -r -d '' file; do
  # quick sanity skip if file disappeared
  [[ ! -e "$file" ]] && continue

  # compute skip reason
  reason="$(should_skip_reason "$file")"
  if [[ "$reason" != "ok" ]]; then
    move_skip "$file" "$reason" "$batch_id"
    continue
  fi

  # size & name
  size=$(stat -c%s "$file" 2>/dev/null || echo 0)
  name="$(basename "$file")"

  # Log hashing start
  log "🔍 Hashing: $name ($((size/1024/1024)) MB)"

  # compute hybrid hash
  hash="$(compute_hybrid_hash "$file")"

  # check duplicate in DB
  if db_has_hash "$hash"; then
    move_skip "$file" "dupe" "$batch_id"
    continue
  fi

  # size limit test: allow one file to overshoot, but ensure we keep filling until we reach at least SIZE_LIMIT_BYTES
  if [[ $current_bytes -ge $SIZE_LIMIT_BYTES ]]; then
    # we've already hit the target; but overshoot allowed only to finish current file — so break now
    log "${C2}Target reached previously; stopping additional files.${CR}"
    break
  fi

  # Destination name uniqueness inside batch
  dest="$BATCH_DIR/$name"
  if [[ -e "$dest" ]]; then
    base="${name%.*}"; ext="${name##*.}"; n=1
    while [[ -e "$BATCH_DIR/${base}-$n.$ext" ]]; do ((n++)); done
    dest="$BATCH_DIR/${base}-$n.$ext"
  fi

  # Copy (or simulate in DRY_RUN)
  log "${C2}📥 Copying → $dest${CR}"
  if [[ "$DRY_RUN" == "false" ]]; then
    if ! $CP_CMD -- "$file" "$dest"; then
      log "${C4}❌ Copy failed for $file${CR}"
      # leave file in place and continue
      continue
    fi
  else
    log "${C3}DRY_RUN: would copy $file -> $dest${CR}"
  fi

  # Insert into DB
  if [[ "$DRY_RUN" == "false" ]]; then
    db_insert_file "$file" "$dest" "$name" "$size" "$hash" "$batch_id"
    # update counts
    current_bytes=$((current_bytes + size))
    current_count=$((current_count + 1))
  else
    # simulate update counters in dry-run
    current_bytes=$((current_bytes + size))
    current_count=$((current_count + 1))
  fi

  log "📊 Batch progress: $current_count files | $((current_bytes/1024/1024)) MB / $((SIZE_LIMIT_BYTES/1024/1024)) MB"

  # If we've reached the limit (>= SIZE_LIMIT_BYTES) then allow loop to finish current file and then break
  if [[ $current_bytes -ge $SIZE_LIMIT_BYTES ]]; then
    log "${C2}Target reached: $((current_bytes/1024/1024)) MB >= $((SIZE_LIMIT_BYTES/1024/1024)) MB${CR}"
    # break after finishing this file (we are already after copy)
    break
  fi

done < <(find "$SOURCE_DIR" -type f -print0)

# Summary
log ""
log "${C2}✅ Batch Complete${CR}"
log "📌 Added to batch    : $current_count"
log "📌 Batch total size  : $((current_bytes/1024/1024)) MB"
log "⚠ Skipped by ext    : $skipped_ext"
log "⚠ Skipped by name   : $skipped_name"
log "⚠ Skipped by path   : $skipped_path"
log "⚠ Duplicates moved  : $skipped_dupes"
log "📂 Batch folder     : $BATCH_DIR"

# Trigger Syncthing scan if configured and not dry-run
if [[ -n "${ST_API_KEY:-}" && -n "${ST_URL:-}" && -n "${ST_FOLDER_ID:-}" && "$DRY_RUN" == "false" ]]; then
  # call syncthing rest API to request scan
  if curl -s -X POST -H "X-API-Key: $ST_API_KEY" "$ST_URL/db/scan?folder=$ST_FOLDER_ID" >/dev/null 2>&1; then
    log "${C1}🔄 Syncthing scan triggered for folder $ST_FOLDER_ID${CR}"
  else
    log "${C3}⚠ Syncthing scan trigger failed${CR}"
  fi
fi

echo "$BATCH_DIR"
exit 0
