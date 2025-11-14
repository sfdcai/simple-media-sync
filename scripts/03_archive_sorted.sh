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
  fi

  target_dir="$ARCHIVE_DIR/$y/$m/$d"
  mkdir -p "$target_dir"
  target="$target_dir/$filename"

  # avoid collision
  if [ -e "$target" ]; then
    base="${filename%.*}" ext="${filename##*.}" n=1
    while [ -e "$target_dir/${base}-$n.$ext" ]; do ((n++)); done
    target="$target_dir/${base}-$n.$ext"
  fi

  log "📥 Moving: $f → $target"
  [ "$DRY_RUN" = false ] && mv "$f" "$target"
done

log "✅ Archive complete"
