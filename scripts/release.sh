#!/usr/bin/env bash
# release.sh — Build, sign, notarize, and package a distributable .dmg
#
# Usage:
#   ./scripts/release.sh                    # ad-hoc signed build (no notarization, for local testing)
#   DEVELOPMENT_TEAM=ABCDE12345 \
#   NOTARY_PROFILE=AC_PASSWORD \
#     ./scripts/release.sh                  # full pipeline: Developer ID + notarize + staple + dmg
#
# Prerequisites for distribution mode:
#   1. Apple Developer Program membership ($99/year)
#   2. "Developer ID Application" certificate installed in your login keychain
#   3. One-time notarytool credential setup:
#        xcrun notarytool store-credentials AC_PASSWORD \
#          --apple-id "you@example.com" \
#          --team-id  "ABCDE12345" \
#          --password "app-specific-password"
#      (generate the app-specific password at appleid.apple.com)
#
# Output:
#   release/NotesMap-<version>.dmg

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | awk -F'"' '{print $2}')"
APP_NAME="NotesMap"
SCHEME="NotesMap"
PROJECT="NotesMap.xcodeproj"

BUILD_DIR="$ROOT/release/build"
ARCHIVE_PATH="$BUILD_DIR/NotesMap.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_PATH="$ROOT/release/NotesMap-${VERSION}.dmg"

mkdir -p "$BUILD_DIR" "$EXPORT_PATH"
rm -rf "$BUILD_DIR" "$EXPORT_PATH"
mkdir -p "$BUILD_DIR" "$EXPORT_PATH"

# ----------------------------------------------------------------------------
# 0. Regenerate Xcode project (xcodegen) so any project.yml changes are picked up
# ----------------------------------------------------------------------------
if command -v xcodegen >/dev/null 2>&1; then
  echo "▶ xcodegen generate"
  xcodegen generate --quiet
else
  echo "⚠ xcodegen not found — using existing NotesMap.xcodeproj"
fi

# ----------------------------------------------------------------------------
# 1. Decide signing mode
# ----------------------------------------------------------------------------
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  MODE="developer-id"
  echo "▶ Mode: developer-id (TEAM=$DEVELOPMENT_TEAM)"
  SIGN_ARGS=(
    "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
    'CODE_SIGN_STYLE=Manual'
    'CODE_SIGN_IDENTITY=Developer ID Application'
  )
else
  MODE="adhoc"
  echo "▶ Mode: ad-hoc (no Developer ID — local testing only, will not notarize)"
  SIGN_ARGS=(
    'CODE_SIGN_IDENTITY=-'
    'CODE_SIGN_STYLE=Automatic'
  )
fi

# ----------------------------------------------------------------------------
# 2. Archive
# ----------------------------------------------------------------------------
echo "▶ Archiving Release configuration"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  "${SIGN_ARGS[@]}" \
  archive

# ----------------------------------------------------------------------------
# 3. Export
# ----------------------------------------------------------------------------
EXPORT_OPTIONS_TMP="$BUILD_DIR/ExportOptions.resolved.plist"

if [[ "$MODE" == "developer-id" ]]; then
  # Substitute ${DEVELOPMENT_TEAM} placeholder in the template
  sed "s/\${DEVELOPMENT_TEAM}/$DEVELOPMENT_TEAM/g" \
    "$ROOT/scripts/ExportOptions.plist" > "$EXPORT_OPTIONS_TMP"

  echo "▶ Exporting with Developer ID"
  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_TMP"
else
  # Ad-hoc: just copy the .app out of the archive — no export step needed
  echo "▶ Copying ad-hoc-signed .app from archive"
  cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_PATH/"
fi

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || { echo "❌ Expected app at $APP_PATH not found"; exit 1; }

# ----------------------------------------------------------------------------
# 4. Notarize + staple (only in developer-id mode)
# ----------------------------------------------------------------------------
if [[ "$MODE" == "developer-id" ]]; then
  if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "⚠ NOTARY_PROFILE not set — skipping notarization."
    echo "  To notarize: NOTARY_PROFILE=AC_PASSWORD ./scripts/release.sh"
  else
    NOTARY_ZIP="$BUILD_DIR/NotesMap-notary.zip"
    echo "▶ Zipping for notarization"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"

    echo "▶ Submitting to notary service (this can take 1–10 minutes)"
    xcrun notarytool submit "$NOTARY_ZIP" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait

    echo "▶ Stapling the ticket"
    xcrun stapler staple "$APP_PATH"
    echo "✓ Notarization complete"
  fi
fi

# ----------------------------------------------------------------------------
# 5. Build the DMG
# ----------------------------------------------------------------------------
echo "▶ Building $DMG_PATH"
DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# Sign the DMG itself in developer-id mode (so Gatekeeper accepts it without quarantine prompt)
if [[ "$MODE" == "developer-id" ]]; then
  echo "▶ Signing the DMG"
  codesign \
    --sign "Developer ID Application" \
    --options runtime \
    --timestamp \
    "$DMG_PATH"

  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "▶ Notarizing the DMG"
    xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait
    xcrun stapler staple "$DMG_PATH"
  fi
fi

# ----------------------------------------------------------------------------
# 6. Sparkle EdDSA signature (for auto-update appcast.xml)
# ----------------------------------------------------------------------------
SPARKLE_SIGN="$ROOT/tools/sparkle/bin/sign_update"
APPCAST_LINE_FILE="${DMG_PATH%.dmg}.appcast-line.txt"
if [[ -x "$SPARKLE_SIGN" ]]; then
    echo "▶ Signing DMG for Sparkle (EdDSA, private key from Keychain)"
    SIG_LINE=$("$SPARKLE_SIGN" "$DMG_PATH")
    echo "  $SIG_LINE"
    echo "$SIG_LINE" > "$APPCAST_LINE_FILE"
    echo "  → saved to $(basename "$APPCAST_LINE_FILE") for copy-paste into appcast.xml"
else
    echo "⚠ Sparkle tools not installed — skipping update signing."
    echo "  Run: ./scripts/setup-sparkle-tools.sh"
fi

# ----------------------------------------------------------------------------
# 7. Verification
# ----------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  ✓ Done"
echo "═══════════════════════════════════════════════════════════════"
echo "  Mode:    $MODE"
echo "  Version: $VERSION"
echo "  App:     $APP_PATH"
echo "  DMG:     $DMG_PATH"
echo "  Size:    $(du -h "$DMG_PATH" | awk '{print $1}')"
if [[ -f "$APPCAST_LINE_FILE" ]]; then
    echo "  Sparkle: $(cat "$APPCAST_LINE_FILE")"
fi
echo ""
echo "  Verify signature:"
echo "    codesign -dvvv \"$APP_PATH\""
echo "    spctl -a -vvv -t install \"$DMG_PATH\""
echo ""
