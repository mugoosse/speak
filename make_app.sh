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

# Icon, if it has been generated.
if [ -f "$ROOT/Assets/Speak.icns" ]; then
    cp "$ROOT/Assets/Speak.icns" "$APP/Contents/Resources/Speak.icns"
fi

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
    <key>CFBundleIconFile</key><string>Speak</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- menu bar only, no Dock icon -->
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Speak transcribes your dictation locally.</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

# Signing identity decides whether your Accessibility grant survives a rebuild.
#
# Ad-hoc signing (`--sign -`) produces a designated requirement of
# `cdhash H"..."`, which is the hash of *this exact build*. TCC pins the grant
# to that, so every rebuild silently invalidates it: the toggle still looks on
# in System Settings, but the new binary is a different app as far as TCC is
# concerned, and the hotkey quietly stops working.
#
# Signing with a real certificate gives a requirement based on the identifier
# and the signing identity instead, which is stable across rebuilds. Any
# certificate works, including a free Apple Development one from Xcode.
SIGN_ID="${SPEAK_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
fi

if [ -n "$SIGN_ID" ]; then
    codesign --force --deep --sign "$SIGN_ID" \
        --identifier com.mgo.speak "$APP" 2>&1 \
        | grep -v "replacing existing signature" || true
else
    echo "warning: no signing certificate found, falling back to ad-hoc." >&2
    echo "         Accessibility must be re-granted after every rebuild." >&2
    echo "         Fix: open Xcode > Settings > Accounts and add an Apple ID," >&2
    echo "         which installs a free Apple Development certificate." >&2
    codesign --force --deep --sign - \
        --identifier com.mgo.speak "$APP" 2>&1 \
        | grep -v "replacing existing signature" || true
fi

codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature" | head -3 || true
echo "requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^# designated => //p')"
echo "built: $APP"
