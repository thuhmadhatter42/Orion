#!/bin/sh
# plugin/smoke.sh: checks the built bundles without a host (plan step 8; A1 lesson 3).  Run by
# plugin/build.sh after signing; also runnable alone.  Never loads a bundle, never installs.
#   structure (Info.plist identity, moduleinfo.json, weights byte-identical to models/), both slices,
#   macOS 12.0 minimum on both, the exports list exactly, Developer ID + hardened runtime + timestamp.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
fail() { echo "plugin/smoke.sh: FAIL: $*" >&2; exit 1; }
VER=$(tr -d ' \n' < "$ROOT/VERSION")
OLDIFS=$IFS; IFS=.; set -- $VER; IFS=$OLDIFS
AUVER=$(( ($1 << 16) | ($2 << 8) | $3 ))

check_bundle() {   # $1 bundle, $2 bundle id, $3 expected exports (sorted, space separated)
  B=$1; BIN="$B/Contents/MacOS/Beat Key"; P="$B/Contents/Info.plist"
  echo "-- $(basename "$B")"
  [ -f "$BIN" ] || fail "$B: no executable"
  [ -f "$B/Contents/PkgInfo" ] || fail "$B: no PkgInfo"
  plutil -lint "$P" >/dev/null || fail "$P is not a valid plist"
  pl() { /usr/libexec/PlistBuddy -c "Print $1" "$P" 2>/dev/null || fail "$P has no $1"; }
  [ "$(pl :CFBundleExecutable)" = "Beat Key" ] || fail "$B: CFBundleExecutable"
  [ "$(pl :CFBundlePackageType)" = "BNDL" ] || fail "$B: CFBundlePackageType"
  [ "$(pl :CFBundleIdentifier)" = "$2" ] || fail "$B: CFBundleIdentifier is not $2"
  [ "$(pl :CFBundleShortVersionString)" = "$VER" ] || fail "$B: version differs from VERSION $VER"
  cmp -s "$B/Contents/Resources/deeptemp-k16-3.bkw" "$ROOT/models/deeptemp-k16-3.bkw" || fail "$B: weights missing or not models/deeptemp-k16-3.bkw"
  A=$(lipo -archs "$BIN") || fail "lipo failed on $BIN"
  [ "$A" = "x86_64 arm64" ] || fail "$B: archs are '$A'"
  for a in arm64 x86_64; do
    M=$(vtool -arch $a -show-build "$BIN" 2>&1 | awk '/minos/ {print $2}')
    [ "$M" = "12.0" ] || fail "$B: $a slice min macOS is '$M', want 12.0"
    S=$(nm -arch $a -gU "$BIN" | awk '{print $3}' | LC_ALL=C sort | tr '\n' ' ')
    [ "$S" = "$3 " ] || fail "$B: $a exports '$S', want '$3'"
  done
  codesign --verify --deep --strict "$B" 2>/dev/null || fail "$B: codesign --verify --deep --strict failed"
  CD=$(codesign -dv --verbose=2 "$B" 2>&1)
  printf '%s\n' "$CD" | grep -q '^Authority=Developer ID Application' || fail "$B: not signed with Developer ID Application"
  printf '%s\n' "$CD" | grep -q 'flags=.*runtime' || fail "$B: no hardened runtime"
  printf '%s\n' "$CD" | grep -q '^Timestamp=' || fail "$B: no secure timestamp"
  echo "ok: $2 $VER, x86_64 arm64, minos 12.0, exports $3, Developer ID + runtime + timestamp, weights"
}

AU="$HERE/build.noindex/Beat Key.component"
check_bundle "$AU" com.jshriver.orion.plugin.au "_BeatKeyAUFactory"
P="$AU/Contents/Info.plist"
for kv in type:aufx subtype:BtKy manufacturer:FLRc factoryFunction:BeatKeyAUFactory version:$AUVER; do
  v=$(/usr/libexec/PlistBuddy -c "Print :AudioComponents:0:${kv%%:*}" "$P" 2>/dev/null)
  [ "$v" = "${kv#*:}" ] || fail "AU AudioComponents ${kv%%:*} is '$v', want '${kv#*:}'"
done
echo "ok: AudioComponents aufx BtKy FLRc, BeatKeyAUFactory, version $AUVER"

V3="$HERE/build.noindex/Beat Key.vst3"
check_bundle "$V3" com.jshriver.orion.plugin.vst3 "_GetPluginFactory _bundleEntry _bundleExit"
python3 -I - "$V3/Contents/Resources/moduleinfo.json" "$VER" <<'PY' || fail "moduleinfo.json is wrong"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["Name"] == "Beat Key" and m["Version"] == sys.argv[2], (m["Name"], m["Version"])
c = m["Classes"]
assert len(c) == 1 and c[0]["CID"] == "42744B79416E6C7A56535433464C5263", c
assert c[0]["Category"] == "Audio Module Class" and c[0]["Version"] == sys.argv[2]
PY
echo "ok: moduleinfo.json (Beat Key, one Audio Module Class)"
echo "plugin/smoke.sh: OK"
