#!/usr/bin/env bash
# menu.sh - final dynamic menu (single-level plugins, MENU_POSITION ordering)
set -euo pipefail
# load central config
if [[ ! -f ./05_config.sh ]]; then
  echo "Missing ./05_config.sh - create or copy it first"; exit 1
fi
source ./05_config.sh

# ensure safe defaults so menu never fails
: "${SQLITE_WEB_PORT:=4000}"
: "${ST_POLL_INTERVAL:=10}"

LOG_DIR="${LOG_DIR:-/var/log/media-batcher}"
mkdir -p "$LOG_DIR"
MENU_LOG="$LOG_DIR/menu.log"
log(){ echo "$(date --iso-8601=seconds) - $*" >> "$MENU_LOG"; }

# UI strings
MENU_TITLE="MEDIA PIPELINE CONTROLLER"

# helpers ------------------------------------------------
detect_sqlite_web_port() {
  local pids ports
  pids=$(pgrep -f "sqlite-web") || true
  [[ -z "$pids" ]] && echo "NOT RUNNING" && return

  ports=$(ss -tunlp 2>/dev/null | grep "$pids" | awk '{print $5}' | cut -d: -f2 | sort -u)
  [[ -n "$ports" ]] && echo "$ports" || echo "RUNNING (port unknown)"
}

syncthing_status() {
  if [[ -z "${ST_API_KEY:-}" || -z "${ST_URL:-}" || -z "${ST_FOLDER_ID:-}" ]]; then
    echo "ST CONFIG MISSING"
    return
  fi
  if ! curl -s -H "X-API-Key: $ST_API_KEY" "$ST_URL/system/status" >/dev/null 2>&1; then
    echo "UNREACHABLE"
    return
  fi
  cfg=$(curl -s -H "X-API-Key: $ST_API_KEY" "$ST_URL/config" 2>/dev/null)
  if echo "$cfg" | jq -e --arg id "$ST_FOLDER_ID" '.folders[]|select(.id==$id)' >/dev/null 2>&1; then
    echo "CONNECTED (folder id: $ST_FOLDER_ID)"
  else
    echo "CONNECTED (folder missing in config)"
  fi
}
local_folder_status() {
  missing=()
  for d in "$SOURCE_DIR" "$BATCH_DIR" "$ARCHIVE_DIR"; do [[ -d "$d" ]] || missing+=("$d"); done
  if [ ${#missing[@]} -eq 0 ]; then echo "OK"; else printf "MISSING: %s" "$(IFS=,; echo "${missing[*]}")"; fi
}

# Build core fixed menu items (positions 1..6)
declare -A CORE_MAP  # position->script slug (used for display only)
# NOTE: these are the canonical core operations and their menu positions
CORE_MAP[1]="scripts/01_create_batch.sh"
CORE_MAP[2]="scripts/trigger-syncthing-scan.sh"
CORE_MAP[3]="scripts/02_check_syncthing.sh"
CORE_MAP[4]="scripts/03_archive_sorted.sh"

# dynamic plugin collection ------------------------------------------------
# plugin files live in ./scripts and have headers:
# # MENU_SHOW: yes
# # MENU_SECTION: plugin       (or main)
# # MENU_POSITION: <number>    (position within plugin submenu)
# # MENU_NAME: Friendly name
# # MENU_DESC: short desc
collect_plugins() {
  plugins=()            # filenames
  plugin_data=()        # "pos|name|desc|file"
  # find candidate scripts
  while IFS= read -r -d '' f; do
    # read headers
    show=$(grep -m1 -i "^# MENU_SHOW:" "$f" 2>/dev/null || true)
    show=${show#*MENU_SHOW:}; show=$(echo "$show" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [[ -z "$show" ]] && show="yes"
    [[ "$show" != "yes" && "$show" != "y" && "$show" != "true" ]] && continue
    section=$(grep -m1 -i "^# MENU_SECTION:" "$f" 2>/dev/null || true)
    section=${section#*MENU_SECTION:}; section=$(echo "$section" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
    [[ -z "$section" ]] && section="plugin"
    [[ "$section" != "plugin" ]] && continue
    pos=$(grep -m1 -i "^# MENU_POSITION:" "$f" 2>/dev/null || true)
    pos=${pos#*MENU_POSITION:}; pos=$(echo "$pos" | tr -d '[:space:]')
    [[ -z "$pos" ]] && pos="1000"   # default large so unspecified go to end
    name=$(grep -m1 -i "^# MENU_NAME:" "$f" 2>/dev/null || true); name=${name#*MENU_NAME:}; name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$name" ]] && name=$(basename "$f")
    desc=$(grep -m1 -i "^# MENU_DESC:" "$f" 2>/dev/null || true); desc=${desc#*MENU_DESC:}; desc=$(echo "$desc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$desc" ]] && desc="No description"
    plugin_data+=("${pos}|${name}|${desc}|${f}")
  done < <(find ./scripts -maxdepth 1 -type f -name "*.sh" -print0 | sort -z)
  # sort plugin_data by pos numeric
  IFS=$'\n' sorted=($(printf "%s\n" "${plugin_data[@]}" | sort -t'|' -k1,1n))
  unset IFS
  # create plugin arrays
  PLUGIN_LABELS=(); PLUGIN_FILES=()
  for e in "${sorted[@]}"; do
    IFS='|' read -r p n d file <<< "$e"
    PLUGIN_LABELS+=("${n} :: ${d}")
    PLUGIN_FILES+=("$file")
  done
}

# print header (separator then header, per your choice)
print_header() {
  echo
  echo "------------------------------------------------------------"
  echo
  printf "%s\n" "${MENU_TITLE}"
  echo
  printf "SQLite WebUI Port: %s\n" "$(detect_sqlite_web_port)"
  printf "Database         : %s\n" "$DB_PATH"
  printf "Syncthing Status : %s\n" "$(syncthing_status)"
  printf "Folders Status   : %s\n" "$(local_folder_status)"
  printf "Source           : %s\n" "$SOURCE_DIR"
  printf "Batch Stage      : %s\n" "$BATCH_DIR"
  printf "Archive          : %s\n" "$ARCHIVE_DIR"
  printf "Logs             : %s (menu log: %s)\n" "$LOG_DIR" "$MENU_LOG"
  echo
  echo "------------------------------------------------------------"
  echo
}

# run helper (foreground; user reads output; wait ENTER)
run_and_wait() {
  local script="$1"
  if [[ ! -x "$script" ]]; then
    log "Running $script (non-executable or missing), try with bash"
  fi
  echo
  echo "---- Running: $script ----"
  log "Run: $script"
  # run under bash (preserves output in terminal)
  bash "$script"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo
    echo "[OK] Completed successfully"
  else
    echo
    echo "[ERROR] Exit code $rc"
  fi
  echo
  read -rp "Press ENTER to return to menu..."
}

# main interactive loop ------------------------------------------------
while true; do
  # build dynamic lists
  collect_plugins

  # print header
  print_header

  # print core fixed menu (1..6)
  echo "CORE OPERATIONS"
for idx in $(printf "%s\n" "${!CORE_MAP[@]}" | sort -n); do
  item="${CORE_MAP[$idx]:-}"
  if [[ -f "$item" ]]; then
    name=$(grep -m1 -i "^# MENU_NAME:" "$item" 2>/dev/null || true)
    name=${name#*MENU_NAME:}
    name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$name" ]] && name=$(basename "$item")
    printf "%2d ) %s\n" "$idx" "$name"
  else
    printf "%2d ) (missing) %s\n" "$idx" "$item"
  fi
done

  echo "------------------------------------------------------------"

  # print plugin area (if plugins present)
  if [ ${#PLUGIN_LABELS[@]} -gt 0 ]; then
    echo "PLUGINS (loaded dynamically)"
    base=$((6+1))
    for i in "${!PLUGIN_LABELS[@]}"; do
      num=$((base + i))
      printf "%2d) %s\n" "$num" "${PLUGIN_LABELS[$i]}"
    done
    echo "------------------------------------------------------------"
  fi

  # system options
  SYS_BASE=$((6 + ${#PLUGIN_LABELS[@]} + 1))
  INFO_IDX=$((SYS_BASE))
  HELP_IDX=$((SYS_BASE+1))
  RELOAD_IDX=$((SYS_BASE+2))
  EXIT_IDX=$((SYS_BASE+3))

  printf "%2d) %s\n" "$INFO_IDX" "Show script info"
  printf "%2d) %s\n" "$HELP_IDX" "Show script help"
  printf "%2d) %s\n" "$RELOAD_IDX" "Reload menu"
  printf "%2d) %s\n" "$EXIT_IDX" "Exit"

  echo
  read -rp "Select option number (or press ENTER for fuzzy select): " choice
  if [[ -z "$choice" ]]; then
    # build composite list for fzf
    composite=()
    # core
    for idx in $(printf "%s\n" "${!CORE_MAP[@]}" | sort -n); do
      item="${CORE_MAP[$idx]}"
      label=$(grep -m1 -i "^# MENU_NAME:" "$item" 2>/dev/null || true); label=${label#*MENU_NAME:}; label=$(echo "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -z "$label" ]] && label=$(basename "$item")
      composite+=("$(printf "%2d" "$idx") ) $label")
    done
    # plugins
    base=$((6+1))
    for i in "${!PLUGIN_LABELS[@]}"; do
      num=$((base + i))
      composite+=("$(printf "%2d" "$num") ) ${PLUGIN_LABELS[$i]}")
    done
    # system
    composite+=("$(printf "%2d" "$INFO_IDX") ) Show script info")
    composite+=("$(printf "%2d" "$HELP_IDX") ) Show script help")
    composite+=("$(printf "%2d" "$RELOAD_IDX") ) Reload menu")
    composite+=("$(printf "%2d" "$EXIT_IDX") ) Exit")
    picked=$(printf "%s\n" "${composite[@]}" | fzf --height 60% --border --prompt="Choose > ")
    [[ -z "$picked" ]] && { echo "No selection"; continue; }
    choice=$(echo "$picked" | awk -F')' '{print $1}' | tr -d '[:space:]')
  fi

  # validate numeric
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then echo "Invalid selection"; continue; fi
  choice_num=$((choice + 0))

  # core 1..6
  if (( choice_num >= 1 && choice_num <= 6 )); then
    script="${CORE_MAP[$choice_num]}"
    if [[ -f "$script" ]]; then run_and_wait "$script"; else echo "Script missing: $script"; read -rp "Press ENTER..."; fi
    echo "------------------ Returning to menu ------------------"
    continue
  fi

  # plugin area
  plugin_start=$((6+1))
  plugin_end=$((6 + ${#PLUGIN_LABELS[@]}))
  if (( choice_num >= plugin_start && choice_num <= plugin_end )); then
    idx=$((choice_num - plugin_start))
    script="${PLUGIN_FILES[$idx]}"
    run_and_wait "$script"
    echo "------------------ Returning to menu ------------------"
    continue
  fi

  # system actions
  if (( choice_num == INFO_IDX )); then
    # pick a script to show info
    alllist=()
    for idx in $(seq 1 6); do alllist+=("$(printf "%2d" "$idx") ) $(grep -m1 -i "^# MENU_NAME:" "${CORE_MAP[$idx]}" 2>/dev/null || basename "${CORE_MAP[$idx]}")"); done
    base=$((6+1))
    for i in "${!PLUGIN_LABELS[@]}"; do num=$((base+i)); alllist+=("$(printf "%2d" "$num") ) ${PLUGIN_LABELS[$i]}"); done
    sel=$(printf "%s\n" "${alllist[@]}" | fzf --prompt="Select script for info > ")
    [[ -z "$sel" ]] && continue
    selnum=$(echo "$sel" | awk -F')' '{print $1}' | tr -d '[:space:]')
    if (( selnum >=1 && selnum <=6 )); then file="${CORE_MAP[$selnum]}"; else idx=$((selnum - plugin_start)); file="${PLUGIN_FILES[$idx]}"; fi
    echo; echo "Script: $file"; grep -E "^# MENU_" "$file" 2>/dev/null || echo "(no MENU_ headers)"; read -rp "Press ENTER..."; continue
  fi

  if (( choice_num == HELP_IDX )); then
    # similar select
    alllist=()
    for idx in $(seq 1 6); do alllist+=("$(printf "%2d" "$idx") ) $(grep -m1 -i "^# MENU_NAME:" "${CORE_MAP[$idx]}" 2>/dev/null || basename "${CORE_MAP[$idx]}")"); done
    base=$((6+1))
    for i in "${!PLUGIN_LABELS[@]}"; do num=$((base+i)); alllist+=("$(printf "%2d" "$num") ) ${PLUGIN_LABELS[$i]}"); done
    sel=$(printf "%s\n" "${alllist[@]}" | fzf --prompt="Select script for help > ")
    [[ -z "$sel" ]] && continue
    selnum=$(echo "$sel" | awk -F')' '{print $1}' | tr -d '[:space:]')
    if (( selnum >=1 && selnum <=6 )); then file="${CORE_MAP[$selnum]}"; else idx=$((selnum - plugin_start)); file="${PLUGIN_FILES[$idx]}"; fi
    echo; sed -n '1,200p' "$file"; read -rp "Press ENTER..."; continue
  fi

  if (( choice_num == RELOAD_IDX )); then
    echo "Reloading menu..."
    continue
  fi

  if (( choice_num == EXIT_IDX )); then
    echo "Goodbye"; exit 0
  fi

  echo "Choice out of range"
done
