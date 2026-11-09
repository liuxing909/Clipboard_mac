#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/modules"
export SWIFT_MODULECACHE_PATH="$PROJECT_DIR/.build/modules"
MODE="${1:-universal}"
if [[ "$MODE" != "universal" && "$MODE" != "--native" ]]; then
    echo "Usage: bash scripts/build.sh [--native]" >&2
    exit 1
fi
LINK_FLAGS=(-Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
swift build -c release --cache-path .build/cache "${LINK_FLAGS[@]}"
NATIVE_BIN="$PROJECT_DIR/.build/release/ClipboardDeck"
APP="$PROJECT_DIR/dist/剪贴匣.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "$MODE" == "universal" ]]; then
    if [[ "$(uname -m)" == "arm64" ]]; then
        OTHER_ARCH="x86_64"; OTHER_BUILD="$PROJECT_DIR/.build/catalina"
    else
        OTHER_ARCH="arm64"; OTHER_BUILD="$PROJECT_DIR/.build/apple-silicon"
    fi
    swift build -c release --arch "$OTHER_ARCH" --scratch-path "$OTHER_BUILD" --cache-path .build/cache "${LINK_FLAGS[@]}"
    OTHER_BIN="$OTHER_BUILD/$OTHER_ARCH-apple-macosx/release/ClipboardDeck"
    xcrun lipo -create "$NATIVE_BIN" "$OTHER_BIN" -output "$APP/Contents/MacOS/ClipboardDeck"
else
    cp "$NATIVE_BIN" "$APP/Contents/MacOS/ClipboardDeck"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
mkdir -p "$APP/Contents/Frameworks"
TOOLS_DIR="$(dirname "$(xcrun --find swiftc)")"
# Catalina/Big Sur do not supply the concurrency runtime. Embed Apple's
# back-deployment library; /usr/lib/swift remains the first runtime search path.
rm -f "$APP/Contents/Frameworks/libswift_Concurrency.dylib" "$APP/Contents/Frameworks/libswift_Concurrency.dylib.original"
xcrun swift-stdlib-tool --copy --platform macosx \
    --source-libraries "$TOOLS_DIR/../lib/swift-5.5/macosx" \
    --scan-executable "$APP/Contents/MacOS/ClipboardDeck" \
    --destination "$APP/Contents/Frameworks" --sign -
rm -f "$APP/Contents/Frameworks/libswift_Concurrency.dylib.original"
if [[ ! -f "$APP/Contents/Frameworks/libswift_Concurrency.dylib" ]]; then
    echo "Missing Swift concurrency back-deployment runtime" >&2
    exit 1
fi
# Do not depend on the developer's toolchain being installed on the target Mac.
LOAD_COMMANDS="$(otool -l "$APP/Contents/MacOS/ClipboardDeck")"
SWIFT_LIB_DIR="$(cd "$TOOLS_DIR/../lib" && pwd)"
for COMPAT_VERSION in swift-5.5 swift-6.2; do
    SEARCH_PATH="$SWIFT_LIB_DIR/$COMPAT_VERSION/macosx"
    if [[ "$LOAD_COMMANDS" == *"path $SEARCH_PATH (offset"* ]]; then
        install_name_tool -delete_rpath "$SEARCH_PATH" "$APP/Contents/MacOS/ClipboardDeck"
    fi
done
codesign --force --sign - --identifier local.clipboarddeck.app "$APP"
echo "Built: $APP"
