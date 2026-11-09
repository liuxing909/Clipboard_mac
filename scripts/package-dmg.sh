#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
bash scripts/build.sh

APP="$PROJECT_DIR/dist/剪贴匣.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
MINIMUM_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")
ARCHS=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/ClipboardDeck")
case "$ARCHS" in
    arm64) ARCH_TAG="arm64"; ARCH_LABEL="Apple Silicon（M 系列芯片）" ;;
    x86_64) ARCH_TAG="x86_64"; ARCH_LABEL="Intel" ;;
    "arm64 x86_64"|"x86_64 arm64") ARCH_TAG="universal"; ARCH_LABEL="Apple Silicon 与 Intel" ;;
    *) echo "Unsupported architecture: $ARCHS" >&2; exit 1 ;;
esac
if [[ ! "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
    echo "Invalid bundle version for package filename" >&2
    exit 1
fi

OUTPUT="$PROJECT_DIR/dist/ClipboardDeck-$VERSION-$ARCH_TAG.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/ClipboardDeck-dmg.XXXXXX")
cleanup() { rm -rf -- "$STAGING"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$STAGING/contents"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/ditto "$APP" "$STAGING/contents/剪贴匣.app"
ln -s /Applications "$STAGING/contents/Applications"
cp LICENSE "$STAGING/contents/LICENSE"
cat > "$STAGING/contents/安装说明.txt" <<EOF
剪贴匣 $VERSION

系统要求：macOS $MINIMUM_OS 或更高版本
处理器：$ARCH_LABEL
Intel Mac：macOS 10.15 或更高版本；Apple Silicon Mac：macOS 11 或更高版本。

安装方法
1. 将“剪贴匣”图标拖入旁边的 Applications（应用程序）文件夹。
2. 在“应用程序”中打开“剪贴匣”。应用图标显示在菜单栏，不显示在 Dock。
3. 安装并被系统收录后，按 Command + 空格，输入“剪贴匣”即可搜索打开。
4. 默认按 Control + Option + V 打开剪贴板历史。
5. 选中后自动粘贴需要在“隐私与安全性 → 辅助功能”中允许剪贴匣；未授权时可仅复制，再手动粘贴。

更新版本时，请先从旧版设置中退出，再将新版本拖入 Applications 替换。
安装包不包含你的历史记录，替换应用不会主动清空历史。

本包是本地测试构建，使用 ad-hoc 签名，尚未进行 Apple Developer ID 签名和公证。
正式对外发布前需要完成签名与公证，才能减少其他 Mac 从网络下载后的系统拦截。
EOF

/usr/bin/hdiutil create -volname "剪贴匣 $VERSION" -srcfolder "$STAGING/contents" \
    -fs HFS+ -format UDZO -nospotlight "$STAGING/package.dmg"
/usr/bin/hdiutil verify "$STAGING/package.dmg"
# Publish only a complete, verified image; staging is removed on success/failure.
mv -f "$STAGING/package.dmg" "$OUTPUT"
echo "Packaged: $OUTPUT"
/usr/bin/shasum -a 256 "$OUTPUT"
