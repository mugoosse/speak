#!/bin/sh
# Build, sign, notarize, package and publish a release.
#
#   ./release.sh            build and package into dist/, no publishing
#   ./release.sh --publish  also create the GitHub release and upload
#
# Notarization runs only when a Developer ID certificate and stored notarytool
# credentials are both present. Without them the artifacts are still produced,
# just with a warning: users will meet Gatekeeper on first launch.
#
# One-time notarytool setup (needs the paid Apple Developer Program):
#   xcrun notarytool store-credentials speak-notary \
#       --apple-id you@example.com --team-id TEAMID \
#       --password <app-specific-password>
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
APP="$ROOT/Speak.app"
VERSION=$(tr -d ' \n' < "$ROOT/VERSION")
KEYCHAIN_PROFILE="${SPEAK_NOTARY_PROFILE:-speak-notary}"
PUBLISH=0
[ "$1" = "--publish" ] && PUBLISH=1

ZIP="$DIST/Speak-$VERSION.zip"
DMG="$DIST/Speak-$VERSION.dmg"

# --- build -----------------------------------------------------------------

"$ROOT/build.sh" >/dev/null
"$ROOT/make_app.sh"

rm -rf "$DIST"
mkdir -p "$DIST"

# --- notarize --------------------------------------------------------------
#
# Apple staples the ticket to the .app, so notarize before packaging and the
# ticket travels inside both the zip and the dmg.

HAS_DEVID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -c "Developer ID Application" || true)
HAS_CREDS=0
xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 \
    && HAS_CREDS=1

if [ "$HAS_DEVID" -gt 0 ] && [ "$HAS_CREDS" -eq 1 ]; then
    echo "notarizing…"
    # Submission always uses a zip, whatever we ship afterwards.
    SUBMIT="$DIST/submit.zip"
    ditto -c -k --keepParent "$APP" "$SUBMIT"
    xcrun notarytool submit "$SUBMIT" \
        --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$SUBMIT"
    echo "stapled"
else
    echo "warning: skipping notarization." >&2
    [ "$HAS_DEVID" -eq 0 ] && \
        echo "         no Developer ID Application certificate found." >&2
    [ "$HAS_CREDS" -eq 0 ] && \
        echo "         no notarytool profile '$KEYCHAIN_PROFILE' stored." >&2
    echo "         Users will have to bypass Gatekeeper on first launch." >&2
fi

# --- package ---------------------------------------------------------------

# ditto, not zip: it preserves the signature and resource forks that a plain
# zip mangles, which invalidates the code signature.
ditto -c -k --keepParent "$APP" "$ZIP"

# A DMG with an Applications symlink is the drag-to-install window people
# expect. hdiutil builds it from a staging folder.
STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Speak $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# The DMG is signed separately; the app inside already carries its own ticket.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [ -n "$SIGN_ID" ]; then
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG" 2>/dev/null || true
fi

echo
echo "artifacts:"
ls -lh "$DIST" | awk 'NR>1 {printf "  %-28s %s\n", $9, $5}'
echo
echo "sha256:"
shasum -a 256 "$ZIP" "$DMG" | sed 's|'"$DIST"'/|  |'

# --- verify ----------------------------------------------------------------

echo
printf "gatekeeper: "
if spctl -a -vvv -t exec "$APP" 2>&1 | grep -q "accepted"; then
    echo "accepted (installs cleanly)"
else
    echo "REJECTED (users must bypass Gatekeeper manually)"
fi

# --- publish ---------------------------------------------------------------

if [ "$PUBLISH" -eq 1 ]; then
    TAG="v$VERSION"
    echo
    echo "publishing $TAG…"
    git tag -a "$TAG" -m "Speak $VERSION" 2>/dev/null || echo "  tag exists, reusing"
    git push origin "$TAG" 2>/dev/null || true
    gh release create "$TAG" "$ZIP" "$DMG" \
        --title "Speak $VERSION" \
        --notes-file "$ROOT/RELEASE_NOTES.md" 2>/dev/null \
    || gh release upload "$TAG" "$ZIP" "$DMG" --clobber
    echo "released: $(gh repo view --json url -q .url)/releases/tag/$TAG"
fi
