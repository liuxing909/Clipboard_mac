#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/modules"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/modules"
SELECTED_TOOLS="$(xcode-select -p)"
TEST_FRAMEWORKS="$SELECTED_TOOLS/Library/Developer/Frameworks"
TEST_ARGS=(--disable-xctest --cache-path .build/cache)
if [ -d "$TEST_FRAMEWORKS/Testing.framework" ]; then
    TEST_ARGS+=(-Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS"
                -Xlinker -F -Xlinker "$TEST_FRAMEWORKS"
                -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS"
                -Xlinker -rpath -Xlinker "$SELECTED_TOOLS/Library/Developer/usr/lib"
                -Xswiftc -plugin-path -Xswiftc "$SELECTED_TOOLS/usr/lib/swift/host/plugins/testing")
fi
swift test "${TEST_ARGS[@]}" "$@"
