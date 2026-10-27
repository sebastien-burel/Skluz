#!/usr/bin/env bash
#
# release.sh — build a signed, notarized, stapled DMG for direct distribution.
#
# Pipeline: archive (Release) -> export with Developer ID -> verify the
# signature -> notarize + staple the app -> build a DMG and an installer
# package -> notarize + staple both -> Gatekeeper check.
#
# Prerequisites (see NOTARIZATION.md §0):
#   - "Developer ID Application" and "Developer ID Installer" certificates
#     for the team below.
#   - A notarytool keychain profile, unless --skip-notarize is passed.
#
# Usage:
#   Tools/release.sh                    # full run
#   Tools/release.sh --skip-notarize    # build + sign only, no Apple round-trip
#   Tools/release.sh --from-export      # resume on the app already in build/release/
#   VERSION=1.0.1 BUILD=42 Tools/release.sh
#
# Artifacts land in build/release/ (git-ignored): Skluz-<version>.pkg, the
# recommended install (root-owned, as the system service requires), and
# Skluz-<version>.dmg for a manual drag-and-drop.

set -euo pipefail

TEAM_ID="82FW35VV68"
IDENTITY="Developer ID Application"
INSTALLER_IDENTITY="Developer ID Installer"
SCHEME="Skluz"
APP_NAME="Skluz"
NOTARY_PROFILE="${NOTARY_PROFILE:-skluz-notary}"

SKIP_NOTARIZE=0
FROM_EXPORT=0
[ "${1:-}" = "--skip-notarize" ] && SKIP_NOTARIZE=1
[ "${1:-}" = "--from-export" ] && FROM_EXPORT=1

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/build/release"
PROJECT="$ROOT/$SCHEME.xcodeproj"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# --- Preflight -------------------------------------------------------------
step "Preflight"
security find-identity -v -p codesigning | grep -q "$IDENTITY: .*($TEAM_ID)" \
  || fail "no '$IDENTITY' certificate for team $TEAM_ID in the keychain"
security find-identity -v | grep -q "$INSTALLER_IDENTITY: .*($TEAM_ID)" \
  || fail "no '$INSTALLER_IDENTITY' certificate for team $TEAM_ID in the keychain"
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "no notarytool profile '$NOTARY_PROFILE' (see NOTARIZATION.md, or pass --skip-notarize)"
fi

ARCHIVE="$OUT/$APP_NAME.xcarchive"
APP="$OUT/$APP_NAME.app"

if [ "$FROM_EXPORT" -eq 1 ]; then
  # Resume on an app exported earlier (e.g. after a failed notarization).
  # Version and build are read from the app itself: HEAD may have moved on.
  step "Reusing the exported app (--from-export)"
  [ -d "$APP" ] || fail "no exported app at $APP"
  VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
  BUILD="$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)"
  echo "version $VERSION (build $BUILD), team $TEAM_ID"
else
  # Marketing version comes from the project; the build number defaults to
  # the commit count so it strictly increases across releases.
  VERSION="${VERSION:-$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$PROJECT/project.pbxproj" | head -1)}"
  BUILD="${BUILD:-$(git -C "$ROOT" rev-list --count HEAD)}"
  [ -n "$VERSION" ] || fail "could not read MARKETING_VERSION from the project"
  echo "version $VERSION (build $BUILD), team $TEAM_ID"
  [ -z "$(git -C "$ROOT" status --porcelain -- Skluz Skluz.xcodeproj)" ] \
    || echo "  warning: uncommitted changes in the app sources are included in this build"

  rm -rf "$OUT"; mkdir -p "$OUT"

  # --- Archive -------------------------------------------------------------
  step "Archiving (Release)"
  xcodebuild archive \
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    | grep -E "error:|\*\* ARCHIVE" || true
  [ -d "$ARCHIVE" ] || fail "archive not produced"

  # --- Export --------------------------------------------------------------
  step "Exporting with Developer ID"
  cat > "$STAGE/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" -exportPath "$OUT" \
    -exportOptionsPlist "$STAGE/ExportOptions.plist" \
    -allowProvisioningUpdates \
    | grep -E "error:|\*\* EXPORT" || true
  [ -d "$APP" ] || fail "export did not produce $APP"
fi
DMG="$OUT/$APP_NAME-$VERSION.dmg"
PKG="$OUT/$APP_NAME-$VERSION.pkg"

# --- Verify the exported app ----------------------------------------------
# These checks catch what notarization would otherwise reject much later.
step "Verifying the exported app"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

# Capture once, then inspect: piping into `grep -q` under pipefail can turn a
# SIGPIPE'd producer into a spurious failure.
SIGINFO="$(codesign -d --verbose=2 "$APP" 2>&1)"
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - || true)"
STRAYS="$(find "$APP" \( -name '*.debug.dylib' -o -name '__preview.dylib' \))"

printf '%s\n' "$SIGINFO" | grep -E "Authority|TeamIdentifier|flags" | sed 's/^/  /'

case "$ENTS" in
  *get-task-allow*) fail "the exported app carries get-task-allow — notarization would reject it" ;;
esac
[ -z "$STRAYS" ] || fail "debug dylibs leaked into the export: $STRAYS"
case "$SIGINFO" in
  *"flags="*runtime*) ;;
  *) fail "hardened runtime is not enabled on the exported app" ;;
esac
case "$SIGINFO" in
  *"Authority=Developer ID Application"*) ;;
  *) fail "the export is not signed with a Developer ID Application certificate" ;;
esac
echo "  ok: Developer ID, hardened runtime, no debug artifacts"

# The root daemon ships inside the app (PLAN_SKLUZD.md phase 3): it must be
# there, next to its launchd plist, and signed like the app.
DAEMON="$APP/Contents/MacOS/skluzd"
[ -x "$DAEMON" ] || fail "skluzd is missing from $APP/Contents/MacOS"
[ -f "$APP/Contents/Library/LaunchDaemons/net.haruni.skluzd.plist" ] \
  || fail "the skluzd launchd plist is missing from the app"
DAEMON_SIGINFO="$(codesign -d --verbose=2 "$DAEMON" 2>&1)"
case "$DAEMON_SIGINFO" in
  *"Authority=Developer ID Application"*"flags="*runtime*|*"flags="*runtime*"Authority=Developer ID Application"*) ;;
  *) fail "skluzd is not signed with Developer ID and the hardened runtime" ;;
esac
echo "  ok: skluzd embedded and signed"

# The status CLI lives in Contents/Helpers (Contents/MacOS/skluz would
# overwrite the app's Contents/MacOS/Skluz on a case-insensitive volume).
CLI="$APP/Contents/Helpers/skluz"
[ -x "$CLI" ] || fail "the skluz CLI is missing from $APP/Contents/Helpers"
CLI_SIGINFO="$(codesign -d --verbose=2 "$CLI" 2>&1)"
case "$CLI_SIGINFO" in
  *"Identifier=net.haruni.skluz.cli"*"Authority=Developer ID Application"*) ;;
  *) fail "the skluz CLI is not signed with Developer ID as net.haruni.skluz.cli" ;;
esac
echo "  ok: skluz CLI embedded and signed"

# --- Notarize the app ------------------------------------------------------
# Two passes on purpose. Stapling the DMG alone leaves the app WITHOUT a ticket
# once dragged out, so Gatekeeper falls back to an online check — which fails
# for a user who is offline on first launch.
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  step "Notarizing the app (this waits on Apple)"
  ZIP="$OUT/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$ZIP"

  step "Stapling the app"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# --- DMG -------------------------------------------------------------------
# APFS + lzfse, with an /Applications symlink so users drag the app out of the
# image instead of launching it from the (translocated) mounted volume.
step "Building the DMG"
mkdir "$STAGE/dmg"
cp -R "$APP" "$STAGE/dmg/"
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -volname "$APP_NAME" -fs APFS -format ULFO \
  -srcfolder "$STAGE/dmg" -ov "$DMG" | sed 's/^/  /'
codesign --sign "$IDENTITY" --timestamp "$DMG"
echo "  $DMG"

# --- Installer package ----------------------------------------------------
# Installs /Applications/Skluz.app owned by root:wheel and writable only by
# root, as the system service requires (InstallationCheck), with no manual
# chown. Works from the Finder and over SSH:
#   sudo installer -pkg Skluz-<version>.pkg -target /
step "Building the installer package"
PKG_ROOT="$STAGE/pkg-root"
mkdir -p "$PKG_ROOT"
ditto "$APP" "$PKG_ROOT/$APP_NAME.app"
COMPONENTS="$STAGE/components.plist"
pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENTS" >/dev/null
# Never relocate: Installer would otherwise update any other copy with the
# same bundle ID it finds (an Xcode build, a copy in Downloads) instead of
# /Applications.
/usr/libexec/PlistBuddy -c "Delete :0:BundleIsRelocatable" "$COMPONENTS" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$COMPONENTS"
pkgbuild --root "$PKG_ROOT" --component-plist "$COMPONENTS" \
  --identifier "net.haruni.skluz.pkg" --version "$VERSION" \
  --install-location /Applications --ownership recommended \
  "$STAGE/$APP_NAME-component.pkg" | sed 's/^/  /'
# A distribution file gives the package its title, shown by Installer
# ("Package name is …" with the CLI) — none without it.
DISTRIBUTION="$STAGE/distribution.xml"
productbuild --synthesize --package "$STAGE/$APP_NAME-component.pkg" "$DISTRIBUTION" >/dev/null
sed -i '' "s|<installer-gui-script minSpecVersion=\"[0-9]*\">|&<title>$APP_NAME $VERSION</title>|" "$DISTRIBUTION"
grep -q "<title>$APP_NAME $VERSION</title>" "$DISTRIBUTION" || fail "could not set the package title"
productbuild --distribution "$DISTRIBUTION" --package-path "$STAGE" \
  --identifier "net.haruni.skluz.installer" --version "$VERSION" \
  --sign "$INSTALLER_IDENTITY: HARUNI ($TEAM_ID)" --timestamp \
  "$PKG" | sed 's/^/  /'
pkgutil --check-signature "$PKG" | grep -E "Status|Developer ID Installer" | sed 's/^/  /'
echo "  $PKG"

# --- Notarize the DMG ------------------------------------------------------
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  step "Skipping notarization (--skip-notarize)"
  echo "  The DMG and the package are signed but NOT notarized: Gatekeeper will warn on another Mac."
  exit 0
fi

step "Notarizing the DMG (this waits on Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

step "Stapling the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

step "Notarizing the installer package (this waits on Apple)"
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait

step "Stapling the installer package"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"

step "Final Gatekeeper check"
spctl -a -vvv -t install "$DMG" 2>&1 | sed 's/^/  /'
spctl -a -vvv -t install "$PKG" 2>&1 | sed 's/^/  /'
spctl -a -vvv -t execute "$APP" 2>&1 | sed 's/^/  /'

printf '\n\033[32mDone: %s\n      %s\033[0m\n' "$PKG" "$DMG"
echo "Next: validate on ANOTHER Mac, downloaded through a browser (or AirDrop)"
echo "so the quarantine bit is set."
