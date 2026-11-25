#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_NAME="Overlay"
APP_NAME="NotchPulse"
VERSION="${VERSION:-1.1.0}"
BUILD_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
RELEASE_ZIP="$BUILD_DIR/$APP_NAME-$VERSION-macOS-Universal.zip"

echo "Building $APP_NAME v$VERSION (release universal arm64 + x86_64, macOS 12.0+)..."
cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"

# Build arm64 and x86_64 into separate scratch paths and combine with lipo (avoids Xcode 16 XCBuild universal bug)
swift build -c release --arch arm64 --disable-sandbox --scratch-path "$ROOT_DIR/.build/arm64"
ARM64_DIR="$(swift build -c release --arch arm64 --disable-sandbox --scratch-path "$ROOT_DIR/.build/arm64" --show-bin-path | tail -n 1)"
ARM64_BIN="$ARM64_DIR/$BIN_NAME"

swift build -c release --arch x86_64 --disable-sandbox --scratch-path "$ROOT_DIR/.build/x86_64"
X86_DIR="$(swift build -c release --arch x86_64 --disable-sandbox --scratch-path "$ROOT_DIR/.build/x86_64" --show-bin-path | tail -n 1)"
X86_BIN="$X86_DIR/$BIN_NAME"

if [ ! -f "$ARM64_BIN" ] || [ ! -f "$X86_BIN" ]; then
    echo "Error: One or both architecture binaries missing ($ARM64_BIN, $X86_BIN)"
    exit 1
fi

echo "Packaging $APP_BUNDLE..."
rm -rf "$APP_BUNDLE" "$RELEASE_ZIP"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

lipo -create -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$ARM64_BIN" "$X86_BIN"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.amin.NotchPulse</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>NotchPulse accesses your microphone to apply real-time voice effects and display live input levels.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>NotchPulse uses System Audio Recording to control volume levels independently for each app.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotchPulse uses Apple Events to display and control Now Playing media from Spotify, Music, and web browsers.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"NotchPulse Dev"'; then
        SIGN_IDENTITY="NotchPulse Dev"
    fi
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "Signing $APP_BUNDLE with identity: $SIGN_IDENTITY (preserves macOS permissions across updates)..."
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "Signing $APP_BUNDLE (ad-hoc)..."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "Creating release archive $RELEASE_ZIP..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$RELEASE_ZIP"

echo "Done!"
echo "  App bundle:      $APP_BUNDLE"
echo "  Release archive: $RELEASE_ZIP"
