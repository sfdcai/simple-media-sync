#!/usr/bin/env bash
# MENU_SHOW: yes
# MENU_SECTION: main
# MENU_POSITION: 4
# MENU_NAME: Archive
# MENU_DESC: sends signal move files to archive folder
# MENU_HELP: ..............
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../05_config.sh"

SQLITE_BIN="${SQLITE3_BIN:-sqlite3}"

escape_sql() {
  printf "%s" "$1" | sed "s/'/''/g"
}

update_archive_metadata() {
  local batch_path="$1" archived_path="$2" exif_date="$3"
  local batch_sql archive_sql exif_sql sql record_count

  batch_sql="$(escape_sql "$batch_path")"
  archive_sql="$(escape_sql "$archived_path")"

  record_count=$("$SQLITE_BIN" "$DB_PATH" "SELECT COUNT(1) FROM files WHERE batch_path='$batch_sql' OR file_path='$batch_sql';" 2>/dev/null || echo "0")
  if ! [[ "$record_count" =~ ^[0-9]+$ ]] || [[ "$record_count" -eq 0 ]]; then
    log "⚠️ No DB record found for $batch_path"
    return
  fi

  sql="UPDATE files SET archived=1, file_path='$archive_sql', archived_path='$archive_sql', archived_at=COALESCE(archived_at, CURRENT_TIMESTAMP)"
  if [[ -n "$exif_date" ]]; then
    exif_sql="$(escape_sql "$exif_date")"
    sql+=" , exif_date='$exif_sql'"
  fi
  sql+=" WHERE batch_path='$batch_sql' OR file_path='$batch_sql';"

  if ! "$SQLITE_BIN" "$DB_PATH" "$sql" >/dev/null 2>&1; then
    log "⚠️ Failed to update archive metadata for $batch_path"
  fi
}

LOG="$LOG_DIR/archive.log"
mkdir -p "$LOG_DIR"
log(){ echo "$(date --iso-8601=seconds) - $*" | tee -a "$LOG"; }

batch_path="${BATCH_DIR:-}"
[ -z "$batch_path" ] && { log "Batch path not set"; exit 1; }
[ ! -d "$batch_path" ] && { log "Batch path missing"; exit 2; }

log "📦 Archiving batch folder: $batch_path"

find "$batch_path" -type f -print0 | while IFS= read -r -d '' f; do
  filename=$(basename "$f")

  # 1️⃣ Exclude system filenames
  for bad in "${EXCLUDE_NAMES[@]}"; do
    [[ "$filename" == *"$bad"* ]] && { log "⛔ Skipping system file: $f"; continue 2; }
  done

  # 2️⃣ Exclude bad paths
  for badpath in "${EXCLUDE_PATHS[@]}"; do
    [[ "$f" == *"$badpath"* ]] && { log "⛔ Skipping system path file: $f"; continue 2; }
  done

  # 3️⃣ Allow only certain extensions
  ext="${filename##*.}"
  ext="${ext,,}"  # lowercase
  if [[ ! " ${ALLOW_EXTENSIONS[*]} " =~ " $ext " ]]; then
    log "⛔ Skipping unsupported file: $f"
    continue
  fi

  # 4️⃣ EXIF date or fallback
  exif_date=$(exiftool -DateTimeOriginal -d "%Y:%m:%d" -s -s -s "$f" 2>/dev/null || true)
  if [ -n "$exif_date" ]; then
    y=$(echo "$exif_date" | cut -d: -f1)
    m=$(echo "$exif_date" | cut -d: -f2)
    d=$(echo "$exif_date" | cut -d: -f3)
  else
    y=$(date -r "$f" +%Y)
    m=$(date -r "$f" +%m)
    d=$(date -r "$f" +%d)
    exif_date="$y:$m:$d"
  fi

  target_dir="$ARCHIVE_DIR/$y/$m/$d"
  mkdir -p "$target_dir"
  target="$target_dir/$filename"

  # avoid collision
  if [ -e "$target" ]; then
    base="${filename%.*}"
    ext="${filename##*.}"
    if [[ "$base" == "$filename" ]]; then
      ext=""
      base="$filename"
    fi
    n=1
    while true; do
      if [[ -n "$ext" ]]; then
        candidate="$target_dir/${base}-$n.$ext"
      else
        candidate="$target_dir/${base}-$n"
      fi
      [[ -e "$candidate" ]] || break
      ((n++))
    done
    target="$candidate"
  fi

  log "📥 Moving: $f → $target"
  if [ "$DRY_RUN" = false ]; then
    mv "$f" "$target"
    update_archive_metadata "$f" "$target" "$exif_date"
  else
    log "DRY_RUN: would move and record archive metadata"
  fi
done

log "✅ Archive complete"
