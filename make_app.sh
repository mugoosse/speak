#!/bin/sh
# Wrap the built binary in a real .app bundle.
#
# macOS attributes Accessibility/Microphone permissions to a bundle identity.
# A bare executable run from a terminal gets attributed to the terminal
# instead, so it never shows up in the Accessibility list as itself.
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILT="$ROOT/.xcbuild/Build/Products/Release"
APP="$ROOT/Speak.app"

[ -x "$BUILT/speak" ] || { echo "build first: ./build.sh" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILT/speak" "$APP/Contents/MacOS/Speak"

# SPM resource bundles (notably mlx-swift's compiled Metal kernels) are looked
# up next to the executable, so they have to travel with it.
for b in "$BUILT"/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "$APP/Contents/MacOS/"
    cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Speak</string>
    <key>CFBundleDisplayName</key><string>Speak</string>
    <key>CFBundleIdentifier</key><string>com.mgo.speak</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>Speak</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- menu bar only, no Dock icon -->
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Speak transcribes your dictation locally.</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

# A stable signing identity matters: TCC keys the permission to it, and an
# unsigned binary gets a new identity on every rebuild, silently dropping the
# Accessibility grant.
codesign --force --deep --sign - \
    --identifier com.mgo.speak "$APP" 2>&1 | grep -v "replacing existing signature" || true

codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
echo "built: $APP"
