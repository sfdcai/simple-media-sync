#!/usr/bin/env bash
# MENU_SHOW: yes
# MENU_SECTION: plugin
# MENU_POSITION: 3
# MENU_NAME: Check source folder
# MENU_DESC: Create a single batch from SOURCE_DIR into BATCH_DIR (size or count)
# MENU_HELP: Builds a batch folder, deduplicates using DB (hybrid hash head+tail+size),
#           copies files into batch directory, and records entries into DB.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT_DIR/05_config.sh"

echo "🔧 Loading config from: $CONFIG"
source "$CONFIG"

echo ""
echo "📂 SOURCE_DIR = $SOURCE_DIR"
echo "📦 BATCH_SIZE_GB = $BATCH_SIZE_GB"
echo ""

echo "⏳ Counting files..."
total_files=$(find "$SOURCE_DIR" -type f | wc -l)

echo "💾 Calculating total size..."
total_bytes=$(find "$SOURCE_DIR" -type f -printf "%s\n" | awk '{sum+=$1} END{print sum}')

echo "📊 Size by extension:"
find "$SOURCE_DIR" -type f | sed -n 's/..*\.//p' | tr '[:upper:]' '[:lower:]' | sort | uniq -c | sort -nr

echo ""
echo "✅ Total files      : $total_files"
echo "✅ Total size (GB)  : $(awk "BEGIN {printf \"%.2f\", $total_bytes/1024/1024/1024}") GB"
echo "✅ 1 GB limit bytes : $((BATCH_SIZE_GB * 1024 * 1024 * 1024))"
echo ""

if [[ $total_bytes -lt $((BATCH_SIZE_GB * 1024 * 1024 * 1024)) ]]; then
    echo "⚠ WARNING: Total files are LESS than 1GB → batch will never reach 1GB!"
else
    echo "✅ Folder has more than 1GB, batching should work."
fi
