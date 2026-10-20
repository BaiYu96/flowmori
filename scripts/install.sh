#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_DEST="${1:-$HOME/Applications}"
if pgrep -x Flowmori >/dev/null || pgrep -x MacFlow >/dev/null; then
    echo "请先从菜单栏退出 Flowmori 或旧版 MacFlow，再更新应用。" >&2
    exit 1
fi
bash "$TASK_ROOT/scripts/build-app.sh" release
mkdir -p "$TASK_DEST"
ditto "$TASK_ROOT/dist/Flowmori.app" "$TASK_DEST/Flowmori.app"
codesign --verify --strict "$TASK_DEST/Flowmori.app"
open "$TASK_DEST/Flowmori.app"
