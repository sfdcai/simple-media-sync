#!/usr/bin/env bash
# MENU_SHOW: yes
# MENU_SECTION: plugin
# MENU_POSITION: 4
# MENU_NAME: Check batch folder
# MENU_DESC: Validate batch folder size, files, extension stats
# MENU_HELP: Counts files, calculates size, groups by extension, checks batch size limit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT_DIR/05_config.sh"

echo "🔧 Loading config from: $CONFIG"
source "$CONFIG"

echo ""
echo "📁 BATCH_DIR     = $BATCH_DIR"
echo "📦 BATCH_SIZE_GB = $BATCH_SIZE_GB"
echo ""

if [[ ! -d "$BATCH_DIR" ]]; then
  echo "❌ Batch folder does not exist!"
  exit 1
fi

echo "⏳ Counting files..."
total_files=$(find "$BATCH_DIR" -type f | wc -l)

echo "💾 Calculating total size..."
total_bytes=$(find "$BATCH_DIR" -type f -printf "%s\n" 2>/dev/null | awk '{sum+=$1} END{print sum}')

echo "📊 Size by extension:"
find "$BATCH_DIR" -type f 2>/dev/null | sed -n 's/..*\.//p' | tr '[:upper:]' '[:lower:]' | sort | uniq -c | sort -nr

echo ""
echo "✅ Total files       : $total_files"
echo "✅ Total size (GB)   : $(awk "BEGIN {printf \"%.2f\", ${total_bytes:-0}/1024/1024/1024}") GB"
echo "🎯 Batch target (GB): $BATCH_SIZE_GB GB"
echo ""

if [[ ${total_bytes:-0} -lt $((BATCH_SIZE_GB * 1024 * 1024 * 1024)) ]]; then
    echo "⚠ WARNING: Batch is NOT yet ${BATCH_SIZE_GB}GB!"
else
    echo "✅ Batch folder reached target size!"
fi
echo ""
