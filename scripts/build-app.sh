#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
TASK_CONFIG="${1:-release}"
if [[ "$TASK_CONFIG" != "release" && "$TASK_CONFIG" != "debug" ]]; then
    echo "Usage: scripts/build-app.sh [release|debug]" >&2
    exit 2
fi
bash scripts/swift-command.sh build -c "$TASK_CONFIG"
TASK_BIN_DIR="$(bash scripts/swift-command.sh build -c "$TASK_CONFIG" --show-bin-path)"
TASK_APP="$TASK_ROOT/dist/Flowmori.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BIN_DIR/Flowmori" "$TASK_APP/Contents/MacOS/Flowmori"
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
swift -module-cache-path "$TASK_ROOT/.build/module-cache" scripts/make-icon.swift "$TASK_ROOT/.build/AppIcon.iconset"
python3 scripts/pack-icon.py "$TASK_ROOT/.build/AppIcon.iconset" "$TASK_APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$TASK_APP/Contents/Resources/LICENSE"
codesign --force --sign - --identifier app.flowmori.Flowmori "$TASK_APP"
codesign --verify --strict "$TASK_APP"
plutil -lint "$TASK_APP/Contents/Info.plist"
echo "$TASK_APP"
