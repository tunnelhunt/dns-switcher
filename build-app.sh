#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

UNIVERSAL=false
BUILD_DMG=false

for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=true ;;
        --dmg) BUILD_DMG=true ;;
    esac
done

APP_NAME="DNSSwitcher.app"
CONTENTS_DIR="$APP_NAME/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_NAME"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [[ "$UNIVERSAL" == true ]]; then
    echo "🔨 Сборка DNSSwitcher (Universal Binary: arm64 + x86_64)..."
    swift build -c release --triple arm64-apple-macosx13.0
    swift build -c release --triple x86_64-apple-macosx13.0
    lipo -create \
        .build/arm64-apple-macosx/release/DNSSwitcher \
        .build/x86_64-apple-macosx/release/DNSSwitcher \
        -output "$MACOS_DIR/DNSSwitcher"
else
    echo "🔨 Сборка DNSSwitcher (Release)..."
    swift build -c release
    cp ".build/release/DNSSwitcher" "$MACOS_DIR/DNSSwitcher"
fi

chmod +x "$MACOS_DIR/DNSSwitcher"

echo "🎨 Генерация иконки AppIcon.icns..."
swift scripts/generate-icon.swift "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleExecutable</key>
    <string>DNSSwitcher</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>ru.tunnelhunt</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AI DNS Switcher</string>
    <key>CFBundleDisplayName</key>
    <string>AI DNS Switcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.7.2</string>
    <key>CFBundleVersion</key>
    <string>10</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_NAME" 2>/dev/null || true

echo "✅ Готово: $(pwd)/$APP_NAME"

if [[ "$BUILD_DMG" == true ]]; then
    swift scripts/create-dmg.swift "$APP_NAME" "DNSSwitcher.dmg" "AI DNS Switcher"
fi
