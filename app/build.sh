#!/bin/bash
# Builds "Beat Key.app" and the signed, notarized, stapled .pkg installer: the one installer, the download for
# people AND the Sparkle update (appcast.xml's enclosure is this pkg, served bare). No DMG.
# Public name Beat Key; the executable (Orion), bundle ID and code stay Orion.
#   app/build.sh                  -> app/build/Beat Key.app, Beat-Key-<VERSION>.pkg (notarized), appcast.xml
#   app/build.sh --no-notarize    same, stops after signing the pkg (no appcast.xml)
# Signing is inside-out and never --deep: runtime.sh signs every Mach-O of the tool runtime
# (yt-dlp and deno with their own entitlements), then the app itself is signed. --deep is for verify only.
# Nothing is written into the bundle after it is signed.
set -euo pipefail
APP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$APP/.." && pwd)"
B="$APP/build"
VER="$(tr -d '[:space:]' < "$ROOT/VERSION")"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: J Shriver (9WTFGV63S2)}"
PROFILE="${NOTARY_PROFILE:-artemis-notary}"
NOTARIZE=1
[ "${1:-}" = --no-notarize ] && NOTARIZE=0
APP_NAME="Beat Key"                     # = Brand.name (FaceplateTests checks it)
OUTAPP="$B/$APP_NAME.app"
PKG="$B/Beat-Key-$VER.pkg"
PKG_IDENTITY="${PKG_SIGN_IDENTITY:-Developer ID Installer: J Shriver (9WTFGV63S2)}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"   # com.jshriver.orion
# Spotlight finds the app by name for "beat" and "key"; this Finder comment + keywords carry
# "bpm" and "download". They are xattrs on the bundle folder: not sealed by the signature, and
# the installer (pkgbuild --root, ditto) keeps them.
FINDER_COMMENT="YouTube downloader, BPM and key finder: download a beat as MP3, get its BPM, tempo and key."
KEYWORDS="bpm download youtube mp3 key tempo beat music"

security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" \
  || { echo "no '$IDENTITY' signing identity in the keychain"; exit 1; }
# Installer certificates are not "codesigning" identities: list them all
security find-identity -v | grep -qF "\"$PKG_IDENTITY\"" \
  || { echo "no '$PKG_IDENTITY' installer identity in the keychain"; exit 1; }
for f in "$APP/pkg/distribution.xml" "$APP/pkg/postinstall" "$APP/pkg/plugin-pkgs.sh" "$APP/pkg/plugin-postinstall"; do
  [ -f "$f" ] || { echo "missing $f"; exit 1; }
done
for f in "$APP/icon/Orion.icns" "$APP/icon/Assets.xcassets/AppIcon.appiconset/Contents.json"; do
  [ -f "$f" ] || { echo "missing $f (icon: app/icon/Orion.icns from source-golden-key.png)"; exit 1; }
done
echo "== $APP_NAME $VER"

echo "== analysis core (core/build.sh: libbeatkey.a, what the app links)"
sh "$ROOT/core/build.sh"
[ -f "$ROOT/models/deeptemp-k16-3.bkw" ] || { echo "no core weights at models/deeptemp-k16-3.bkw"; exit 1; }

echo "== swift build (universal)"
(cd "$APP" && swift build -c release --arch arm64 --arch x86_64)
PROD="$(cd "$APP" && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
[ -x "$PROD/Orion" ] || { echo "no binary at $PROD/Orion"; exit 1; }
ARCHS="$(lipo -archs "$PROD/Orion")"
case "$ARCHS" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "binary is not universal: $ARCHS"; exit 1 ;; esac

echo "== runtime"
# The tools (ffmpeg, ffprobe, yt-dlp, deno; no Python since plug-in plan step 19) are rebuilt when what they are made from
# changes, not merely when its folder is missing: the stamp is a hash of vendor/ and runtime.sh.
RUNTIME_HASH="$(cd "$ROOT" && git ls-files -z vendor app/runtime.sh | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
[ -n "$RUNTIME_HASH" ] || { echo "could not hash the runtime inputs"; exit 1; }
if [ ! -d "$B/runtime/arm64" ] || [ ! -d "$B/runtime/x86_64" ] || [ -d "$B/runtime/scripts" ] \
   || [ "$(cat "$B/runtime/.inputs" 2>/dev/null)" != "$RUNTIME_HASH" ]; then
  "$APP/runtime.sh" build
  printf '%s\n' "$RUNTIME_HASH" > "$B/runtime/.inputs"
fi
[ ! -e "$B/runtime/arm64/python" ] && [ ! -e "$B/runtime/x86_64/python" ] || { echo "a Python is left in the runtime"; exit 1; }
"$APP/runtime.sh" sign

echo "== plug-ins (AU, VST3, AAX: built and signed by plugin/build.sh, packed by app/pkg/plugin-pkgs.sh)"
# They are choices inside this one installer (distribution.xml ticks each on an update only when it is already installed).
# BEATKEY_PLUGINS_PREBUILT=1 skips plugin/build.sh and packs what is already in plugin/build.noindex.
export PKG_SIGN_IDENTITY="$PKG_IDENTITY" BEATKEY_VERSION="$VER" BEATKEY_PKG_LOG="$B/plugin-pkgs.log"
mkdir -p "$B"; : > "$BEATKEY_PKG_LOG"
[ "${BEATKEY_PLUGINS_PREBUILT:-0}" = 1 ] || sh "$ROOT/plugin/build.sh"
"$APP/pkg/plugin-pkgs.sh" build "$B/plugin-pkgs" || { echo "the plug-in packages were refused (reason above, log $BEATKEY_PKG_LOG)"; exit 1; }

echo "== assemble $OUTAPP"
rm -rf "$OUTAPP"
mkdir -p "$OUTAPP/Contents/MacOS" "$OUTAPP/Contents/Resources"
cp "$PROD/Orion" "$OUTAPP/Contents/MacOS/Orion"
cp "$APP/Info.plist" "$OUTAPP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VER" "$OUTAPP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VER" "$OUTAPP/Contents/Info.plist"
plutil -replace NSHumanReadableCopyright -string "© $(date +%Y) J Shriver" "$OUTAPP/Contents/Info.plist"
plutil -lint "$OUTAPP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$OUTAPP/Contents/PkgInfo"
cp "$APP/icon/Orion.icns" "$OUTAPP/Contents/Resources/Orion.icns"   # macOS < 26 (CFBundleIconFile)
# macOS 26+ draws its own squircle and puts a grey box behind icons that lack an AppIcon in Assets.car,
# so the full-bleed art is compiled with actool (before signing) and named by CFBundleIconName.
ACT="$(mktemp -d)"
xcrun actool "$APP/icon/Assets.xcassets" --compile "$OUTAPP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 12.0 --app-icon AppIcon --output-partial-info-plist "$ACT/partial.plist" \
  --errors --warnings >/dev/null
rm -rf "$ACT"
[ -f "$OUTAPP/Contents/Resources/Assets.car" ] || { echo "actool produced no Assets.car"; exit 1; }
plutil -replace CFBundleIconName -string AppIcon "$OUTAPP/Contents/Info.plist"
# House kit, help-menu: the Help menu's pages. Manual and What's New are app/pages/*.html; Licenses.txt is
# GENERATED from THIRD-PARTY-LICENSES.md + LICENSE (app/tools/licenses.sh: one source, never a hand copy).
# Help > Manual, Help > What's New and App menu > Licenses open these from Contents/Resources.
for f in Manual.html WhatsNew.html; do
  [ -s "$APP/pages/$f" ] || { echo "missing $APP/pages/$f"; exit 1; }
  cp "$APP/pages/$f" "$OUTAPP/Contents/Resources/$f"
done
sh "$APP/tools/licenses.sh" "$OUTAPP/Contents/Resources/Licenses.txt" \
  || { echo "could not generate Licenses.txt (THIRD-PARTY-LICENSES.md + LICENSE)"; exit 1; }
# House kit, Uninstall: App menu > Uninstall Beat Key… runs this script on this manifest (app/uninstall/)
for f in uninstall.sh uninstall.manifest; do
  [ -f "$APP/uninstall/$f" ] || { echo "missing $APP/uninstall/$f"; exit 1; }
  cp "$APP/uninstall/$f" "$OUTAPP/Contents/Resources/$f"
done
# the bundled script reads its own manifest (a dry run on an empty fixture home: nothing is moved)
FIX="$(mktemp -d)"; mkdir -p "$FIX/home" "$FIX/root"
sh "$OUTAPP/Contents/Resources/uninstall.sh" --dry-run --home "$FIX/home" --root "$FIX/root" >/dev/null \
  || { echo "the bundled uninstall.sh refused its uninstall.manifest"; exit 1; }
sh "$OUTAPP/Contents/Resources/uninstall.sh" --needs-admin --home "$FIX/home" --root "$FIX/root" >/dev/null \
  || { echo "the bundled uninstall.sh could not answer --needs-admin"; exit 1; }
rm -rf "$FIX"
[ -d "$PROD/Orion_Orion.bundle" ] || { echo "no Orion_Orion.bundle in $PROD"; exit 1; }
ditto "$PROD/Orion_Orion.bundle" "$OUTAPP/Contents/Resources/Orion_Orion.bundle"
ditto "$B/runtime" "$OUTAPP/Contents/Resources/runtime"
# the core's tempo weights: a separate CC BY-NC-SA data file beside the binary, never inside it
cp "$ROOT/models/deeptemp-k16-3.bkw" "$OUTAPP/Contents/Resources/deeptemp-k16-3.bkw"
find "$OUTAPP" -name .DS_Store -delete
xattr -cr "$OUTAPP"

# ---- BEGIN sparkle: embed + sign Sparkle.framework (app updates; app/RELEASING.md) ----
# Inside-out per sparkle-project.org/documentation/sandboxing (#code-signing): Autoupdate and
# Updater.app, then the framework, each with the Developer ID, hardened runtime and a timestamp,
# all before the app is signed. Beat Key is not sandboxed, so the XPC services are removed
# (same page, "Removing XPC Services"), and the headers/modules are build-time only. The binary
# finds the framework via @executable_path/../Frameworks (Package.swift linkerSettings).
echo "== sparkle"
SPK="$OUTAPP/Contents/Frameworks/Sparkle.framework"
[ -d "$PROD/Sparkle.framework" ] || { echo "no Sparkle.framework in $PROD"; exit 1; }
mkdir -p "$OUTAPP/Contents/Frameworks"
ditto "$PROD/Sparkle.framework" "$SPK"                      # ditto keeps the Versions symlinks
rm -rf "$SPK/Versions/B/XPCServices" "$SPK/XPCServices" "$SPK/Headers" "$SPK/PrivateHeaders" \
       "$SPK/Modules" "$SPK/Versions/B/Headers" "$SPK/Versions/B/PrivateHeaders" "$SPK/Versions/B/Modules"
xattr -cr "$SPK"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPK/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPK/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPK"
codesign --verify --deep --strict "$SPK"
# capture first: grep -q exits early, otool gets SIGPIPE, and pipefail fails the check
RPATHS="$(otool -l "$OUTAPP/Contents/MacOS/Orion")"
grep -q '@executable_path/../Frameworks' <<<"$RPATHS" \
  || { echo "Orion has no @executable_path/../Frameworks rpath"; exit 1; }
# ---- END sparkle ----

echo "== sign app"
codesign --force --options runtime --timestamp --entitlements "$APP/entitlements-app.plist" \
  --sign "$IDENTITY" "$OUTAPP"
codesign --verify --deep --strict --verbose=2 "$OUTAPP"
# Listen needs the microphone entitlement on the app (hardened runtime)
codesign -d --entitlements - "$OUTAPP" 2>/dev/null | grep -q com.apple.security.device.audio-input \
  || { echo "Beat Key has no audio-input entitlement (Listen would be refused)"; exit 1; }
# and the Apple Events one (new-song titles from Spotify / YouTube tabs)
codesign -d --entitlements - "$OUTAPP" 2>/dev/null | grep -q com.apple.security.automation.apple-events \
  || { echo "Beat Key has no apple-events entitlement (song titles would be refused)"; exit 1; }
/usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" "$OUTAPP/Contents/Info.plist" >/dev/null \
  || { echo "Info.plist lacks NSAppleEventsUsageDescription"; exit 1; }
# the yt-dlp entitlements survived (the app sign must not have re-signed nested code)
for a in arm64 x86_64; do
  ents="$(codesign -d --entitlements - "$OUTAPP/Contents/Resources/runtime/$a/bin/yt-dlp" 2>/dev/null)"
  for k in disable-library-validation allow-unsigned-executable-memory; do
    grep -q "$k" <<<"$ents" || { echo "yt-dlp ($a) lost its $k entitlement"; exit 1; }
  done
  ents="$(codesign -d --entitlements - "$OUTAPP/Contents/Resources/runtime/$a/bin/deno" 2>/dev/null)"
  for k in allow-jit allow-unsigned-executable-memory; do
    grep -q "$k" <<<"$ents" || { echo "deno ($a) lost its $k entitlement"; exit 1; }
  done
done

echo "== spotlight metadata"
bplist_hex() {  # $1 = an XML plist body (<string>/<array>); prints it as binary-plist hex
  local f; f="$(mktemp)"
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0">%s</plist>' "$1" > "$f"
  plutil -convert binary1 "$f"; xxd -p "$f" | tr -d '\n'; rm -f "$f"
}
kw=""; for w in $KEYWORDS; do kw="$kw<string>$w</string>"; done
xattr -wx com.apple.metadata:kMDItemFinderComment "$(bplist_hex "<string>$FINDER_COMMENT</string>")" "$OUTAPP"
xattr -wx com.apple.metadata:kMDItemKeywords "$(bplist_hex "<array>$kw</array>")" "$OUTAPP"
codesign --verify --deep --strict "$OUTAPP" || { echo "metadata xattrs broke the signature"; exit 1; }

echo "== pkg"
# Installs to /Applications/Beat Key.app and nowhere else: BundleIsRelocatable=false, or Installer
# "upgrades" a copy it finds elsewhere (app/build/Beat Key.app, a DMG volume) instead.
# distribution.xml's installation-check stops the installer while Beat Key is running (Sparkle quits it first);
# postinstall opens Beat Key for the logged-in user, except when Sparkle is installing (Sparkle relaunches) (log lines "Beat Key postinstall:" in /var/log/install.log and
# in ~/Library/Logs/Beat Key/install.log; the plug-in packages log the same way).
PK="$B/pkg-stage"
rm -rf "$PK" "$PKG"
mkdir -p "$PK/root" "$PK/scripts" "$PK/pkgs"
ditto "$OUTAPP" "$PK/root/$APP_NAME.app"
cp "$APP/pkg/postinstall" "$PK/scripts/postinstall"; chmod 755 "$PK/scripts/postinstall"
cat > "$PK/component.plist" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
  <key>RootRelativeBundlePath</key><string>$APP_NAME.app</string>
  <key>BundleIsRelocatable</key><false/>
  <key>BundleIsVersionChecked</key><false/>
  <key>BundleHasStrictIdentifier</key><false/>
  <key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
XML
plutil -lint "$PK/component.plist" >/dev/null
pkgbuild --root "$PK/root" --component-plist "$PK/component.plist" --scripts "$PK/scripts" \
  --identifier "$BUNDLE_ID.pkg" --version "$VER" --install-location /Applications \
  "$PK/pkgs/Beat-Key-component.pkg"
# The plug-ins are choices in this same installer: one component package each (AU, VST3, AAX), built before the app.
cp "$B/plugin-pkgs/components/"*.pkg "$PK/pkgs/"
"$APP/pkg/plugin-pkgs.sh" distribution "$APP/pkg/distribution.xml" "$PK/distribution.xml" "$VER" "$B/plugin-pkgs"
productbuild --distribution "$PK/distribution.xml" --package-path "$PK/pkgs" --sign "$PKG_IDENTITY" --timestamp "$PKG"
pkgutil --check-signature "$PKG"
"$APP/pkg/plugin-pkgs.sh" verify "$PKG"      # expand it, re-verify every bundle inside, check where each installs
rm -rf "$PK"
echo "pkg: $PKG ($(du -h "$PKG" | cut -f1))"

[ "$NOTARIZE" = 1 ] || { echo "== skipped notarization (--no-notarize)"; exit 0; }

notarize_and_staple() {   # $1 = the pkg: notarize with $PROFILE, then staple
  local F="$1" OUTJ ID STATUS
  echo "== notarize $(basename "$F") (profile $PROFILE)"
  OUTJ="$B/notary-$(basename "$F").json"
  xcrun notarytool submit "$F" --keychain-profile "$PROFILE" --wait --output-format json | tee "$OUTJ"
  ID="$(/usr/bin/plutil -extract id raw -o - "$OUTJ" 2>/dev/null || true)"
  STATUS="$(/usr/bin/plutil -extract status raw -o - "$OUTJ" 2>/dev/null || true)"
  echo "submission $ID: $STATUS"
  if [ "$STATUS" != Accepted ]; then
    [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
    echo "notarization of $(basename "$F") not Accepted: $STATUS"; exit 1
  fi
  xcrun stapler staple "$F"
  xcrun stapler validate "$F"
}
notarize_and_staple "$PKG"
spctl -a -vv -t install "$PKG"
"$APP/pkg/plugin-pkgs.sh" verify "$PKG"      # the stapled package, expanded again: every bundle still verifies

# ---- BEGIN sparkle: appcast.xml for this pkg (attach both to the GitHub release) ----
# One <item>: the stapled pkg, EdDSA-signed by sign_update with the exported signing file (no
# Keychain prompt). Versions = VERSION (CFBundleVersion = CFBundleShortVersionString). The
# enclosure is the release asset URL (a bare flat .pkg; Sparkle runs `installer -pkg` on it: SUGuidedPackageInstaller); APPCAST_DOWNLOAD_PREFIX overrides it for a local test feed.
ED_FILE="${SPARKLE_ED_FILE:-$HOME/.config/beat-key/sparkle_ed25519_private}"
SPARKLE_BIN="$APP/.build/artifacts/sparkle/Sparkle/bin"
DL_PREFIX="${APPCAST_DOWNLOAD_PREFIX:-https://github.com/thuhmadhatter42/Orion/releases/download/Beat-Key-$VER/}"
APPCAST="$B/appcast.xml"
echo "== appcast ($APPCAST)"
[ -f "$ED_FILE" ] || { echo "no Sparkle EdDSA signing file (app/RELEASING.md)"; exit 1; }
[ -x "$SPARKLE_BIN/sign_update" ] || { echo "no sign_update in $SPARKLE_BIN (swift package resolve)"; exit 1; }
ENC="$("$SPARKLE_BIN/sign_update" --ed-key-file "$ED_FILE" "$PKG")"   # sparkle:edSignature="…" length="…"
case "$ENC" in *'sparkle:edSignature="'*'length="'*) ;; *) echo "sign_update gave no signature"; exit 1 ;; esac
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <link>https://github.com/thuhmadhatter42/Orion/releases</link>
    <item>
      <title>$APP_NAME $VER</title>
      <link>https://github.com/thuhmadhatter42/Orion/releases/tag/Beat-Key-$VER</link>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$VER</sparkle:version>
      <sparkle:shortVersionString>$VER</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0.0</sparkle:minimumSystemVersion>
      <enclosure url="${DL_PREFIX}Beat-Key-$VER.pkg" sparkle:installationType="package" $ENC type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$APPCAST"
"$SPARKLE_BIN/sign_update" --verify --ed-key-file "$ED_FILE" "$PKG" \
  "$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$ENC")"
echo "appcast: $APPCAST"
# ---- END sparkle ----
echo "done: $PKG"
