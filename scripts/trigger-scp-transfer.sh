#!/usr/bin/env bash
# MENU_SHOW: yes
# MENU_SECTION: main
# MENU_POSITION: 5
# MENU_NAME: Transfer via SCP
# MENU_DESC: Copy batch contents to Android device over SCP
# MENU_HELP: Uses SCP to mirror the batch directory onto a remote SSH/SCP endpoint (e.g. Android SSH server).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/05_config.sh" || { echo "❌ Failed to load config"; exit 1; }

LOG="$LOG_DIR/scp_transfer.log"
mkdir -p "$LOG_DIR"
log() { echo "$(date --iso-8601=seconds) - $*" | tee -a "$LOG"; }

if [[ "${TRANSFER_METHOD:-}" != "scp" ]]; then
  log "TRANSFER_METHOD is set to '$TRANSFER_METHOD'; SCP transfer is disabled."
  exit 0
fi

: "${SCP_USER:?SCP_USER not set in config}"
: "${SCP_HOST:?SCP_HOST not set in config}"
: "${SCP_REMOTE_PATH:?SCP_REMOTE_PATH not set in config}"
SCP_PORT="${SCP_PORT:-22}"
SCP_IDENTITY_FILE="${SCP_IDENTITY_FILE:-}"

if [[ ! -d "$BATCH_DIR" ]]; then
  log "Batch directory missing: $BATCH_DIR"
  exit 1
fi

if ! command -v scp >/dev/null 2>&1; then
  log "scp command not available"
  exit 1
fi

remote_target="${SCP_USER}@${SCP_HOST}"
ssh_opts=(-p "$SCP_PORT")
scp_opts=(-P "$SCP_PORT" -r)
if [[ -n "$SCP_IDENTITY_FILE" ]]; then
  ssh_opts+=(-i "$SCP_IDENTITY_FILE")
  scp_opts+=(-i "$SCP_IDENTITY_FILE")
fi

log "Ensuring remote directory exists: $SCP_REMOTE_PATH"
if [[ "$DRY_RUN" == "false" ]]; then
  ssh "${ssh_opts[@]}" "$remote_target" "mkdir -p \"$SCP_REMOTE_PATH\"" || {
    log "Failed to create remote directory $SCP_REMOTE_PATH"
    exit 1
  }
else
  log "DRY_RUN: would run ssh ${ssh_opts[*]} $remote_target mkdir -p \"$SCP_REMOTE_PATH\""
fi

shopt -s nullglob
batch_items=("$BATCH_DIR"/*)
shopt -u nullglob

if (( ${#batch_items[@]} == 0 )); then
  log "No items to transfer in $BATCH_DIR"
  exit 0
fi

log "Starting SCP transfer of ${#batch_items[@]} item(s) to $remote_target:$SCP_REMOTE_PATH"
if [[ "$DRY_RUN" == "false" ]]; then
  if scp "${scp_opts[@]}" "${batch_items[@]}" "$remote_target:$SCP_REMOTE_PATH"; then
    log "✅ SCP transfer complete"
  else
    log "❌ SCP transfer failed"
    exit 1
  fi
else
  log "DRY_RUN: would execute scp ${scp_opts[*]} [${batch_items[*]}] $remote_target:$SCP_REMOTE_PATH"
fi
