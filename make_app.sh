#!/bin/sh
# Wrap the built binary in a real .app bundle.
#
# macOS attributes Accessibility/Microphone permissions to a bundle identity.
# A bare executable run from a terminal gets attributed to the terminal
# instead, so it never shows up in the Accessibility list as itself.
#
# Env:
#   SPEAK_SIGN_ID   override the signing identity
#   SPEAK_BUILD     build number for CFBundleVersion (default: git commit count)
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILT="$ROOT/.xcbuild/Build/Products/Release"
APP="$ROOT/Speak.app"

[ -x "$BUILT/speak" ] || { echo "build first: ./build.sh" >&2; exit 1; }

# Marketing version lives in one place; the build number is derived from commit
# count so it always increases, which macOS requires.
VERSION=$(tr -d ' \n' < "$ROOT/VERSION")
BUILD="${SPEAK_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Speak</string>
    <key>CFBundleDisplayName</key><string>Speak</string>
    <key>CFBundleIdentifier</key><string>com.mgo.speak</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleExecutable</key><string>Speak</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>Speak</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- menu bar only, no Dock icon -->
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Speak transcribes your dictation on this Mac.</string>
</dict>
</plist>
PLIST

# Signing identity decides two things: whether other Macs will run this at all,
# and whether the Accessibility grant survives an update.
#
# Ad-hoc signing (`--sign -`) produces a designated requirement of
# `cdhash H"..."`, the hash of this exact build. TCC pins the grant to it, so
# every rebuild silently invalidates the permission: the toggle still looks on
# in System Settings, but the new binary is a different app as far as macOS is
# concerned, and the shortcut quietly stops working.
#
# Preference order:
#   Developer ID Application  distributable, notarizable
#   Apple Development         fine locally, rejected on other Macs
#   ad-hoc                    last resort
SIGN_ID="${SPEAK_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ {print $2; exit}')
fi

# The Hardened Runtime is required for notarization and harmless without it,
# so it is always on. It is why the entitlements file exists: without the
# audio-input entitlement the runtime blocks the microphone.
COMMON="--force --timestamp --options runtime \
        --entitlements $ROOT/Speak.entitlements --identifier com.mgo.speak"

if [ -n "$SIGN_ID" ]; then
    # Sign nested bundles before the outer one; --deep is deprecated and does
    # not apply entitlements correctly.
    find "$APP/Contents" -name "*.bundle" -maxdepth 2 -print0 2>/dev/null \
        | xargs -0 -I{} codesign $COMMON --sign "$SIGN_ID" {} 2>/dev/null || true
    codesign $COMMON --sign "$SIGN_ID" "$APP" 2>&1 \
        | grep -v "replacing existing signature" || true
else
    echo "warning: no signing certificate found, falling back to ad-hoc." >&2
    echo "         Accessibility must be re-granted after every rebuild," >&2
    echo "         and other Macs will refuse to run this build." >&2
    echo "         Fix: Xcode > Settings > Accounts, add an Apple ID." >&2
    codesign --force --deep --sign - --identifier com.mgo.speak "$APP" 2>&1 \
        | grep -v "replacing existing signature" || true
fi

echo "version:     $VERSION (build $BUILD)"
codesign -dv "$APP" 2>&1 | grep -E "Authority=" | head -1 || true
echo "requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^# designated => //p')"
echo "built: $APP"
