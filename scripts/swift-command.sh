#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/.build/module-cache"
TASK_SUBCOMMAND="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi
if [ "$TASK_SUBCOMMAND" = "test" ]; then
    TASK_TEST_FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
    TASK_TEST_LIBS="$(xcode-select -p)/Library/Developer/usr/lib"
    set -- --disable-xctest -Xswiftc -F -Xswiftc "$TASK_TEST_FRAMEWORKS" -Xlinker -F -Xlinker "$TASK_TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TASK_TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TASK_TEST_LIBS" "$@"
fi
exec swift "$TASK_SUBCOMMAND" --disable-sandbox --cache-path "$TASK_ROOT/.build/swiftpm-cache" --config-path "$TASK_ROOT/.build/swiftpm-config" --security-path "$TASK_ROOT/.build/swiftpm-security" "$@"
