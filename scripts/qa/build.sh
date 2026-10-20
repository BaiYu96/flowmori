#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TASK_APP="$TASK_ROOT/.validation/Flowmori QA.app"
mkdir -p "$TASK_APP/Contents/MacOS"
bash "$TASK_ROOT/scripts/swift-command.sh" build
TASK_BIN="$(bash "$TASK_ROOT/scripts/swift-command.sh" build --show-bin-path)"
TASK_SOURCES=()
for TASK_SOURCE in "$TASK_ROOT"/Sources/Flowmori/*.swift; do
    if [[ "$(basename "$TASK_SOURCE")" != main.swift ]]; then TASK_SOURCES+=("$TASK_SOURCE"); fi
done
swiftc -swift-version 5 -module-cache-path "$TASK_ROOT/.build/module-cache" -I "$TASK_BIN/Modules" \
    -Xcc -fmodule-map-file="$TASK_ROOT/Sources/CSQLite/module.modulemap" \
    "$TASK_ROOT/scripts/qa/main.swift" "${TASK_SOURCES[@]}" "$TASK_BIN"/FlowmoriCore.build/*.swift.o \
    -lsqlite3 -framework Carbon -framework ScreenCaptureKit -framework ServiceManagement -framework ApplicationServices \
    -o "$TASK_APP/Contents/MacOS/FlowmoriQA"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.flowmori.MenuBarFixture2</string>
<key>CFBundleExecutable</key><string>FlowmoriQA</string>
<key>CFBundleName</key><string>Flowmori QA</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$TASK_APP"
# CLI probes must not run from an app bundle: LaunchServices can report their
# exits as fixture-app termination, disturbing the lifecycle recovery under test.
cp "$TASK_APP/Contents/MacOS/FlowmoriQA" "$TASK_ROOT/.validation/FlowmoriQAHelper"
echo "$TASK_APP"
