#!/bin/sh
# plugin/build.sh: builds, signs and checks the Beat Key plug-in bundles (plan step 8, A6).
#   sh plugin/build.sh            (any cwd; reads ../VERSION, never changes it)
#
#   plugin/build.noindex/Beat Key.component   AU    (aufx BtKy FLRc)
#   plugin/build.noindex/Beat Key.vst3        VST3  (class 42744B79416E6C7A56535433464C5263)
#
# Each bundle links its own copy of the core (core/build.noindex/libbeatkey.a) and the instance layer,
# and carries the weights (models/deeptemp-k16-3.bkw, CC BY-NC-SA, a data file, never compiled in) in
# Contents/Resources.  Universal arm64 + x86_64, macOS 12.0 minimum, -Wall -Wextra -Werror on our code.
# Signs with Developer ID (hardened runtime + timestamp), verifies, then runs plugin/smoke.sh.
# Never notarizes, never installs (plugin/validate.sh installs for the validator gate), never writes
# outside plugin/build.noindex and core/build.noindex.  Every refusal prints a reason and exits non-zero.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
cd "$HERE"

refuse() { echo "plugin/build.sh: REFUSED: $*" >&2; exit 1; }

[ -f "$ROOT/VERSION" ] || refuse "VERSION not found at $ROOT/VERSION"
VERSION=$(tr -d ' \n' < "$ROOT/VERSION")
case "$VERSION" in [0-9]*.[0-9]*.[0-9]*) ;; *) refuse "VERSION '$VERSION' is not major.minor.patch" ;; esac
OLDIFS=$IFS; IFS=.; set -- $VERSION; IFS=$OLDIFS
[ "$1" -le 255 ] && [ "$2" -le 255 ] && [ "$3" -le 255 ] || refuse "VERSION $VERSION does not fit the AU version integer (each part 0-255); raise the middle number (J decides when)"
AUVERSION=$(( ($1 << 16) | ($2 << 8) | $3 ))

SIGN_ID="Developer ID Application: J Shriver (9WTFGV63S2)"
OUT="$HERE/build.noindex"
OBJ="$OUT/obj"
WEIGHTS="$ROOT/models/deeptemp-k16-3.bkw"
CORELIB="$ROOT/core/build.noindex/libbeatkey.a"
ARCHS_FLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=12.0"
CF="$ARCHS_FLAGS -Wall -Wextra -Werror -O2 -g -fvisibility=hidden"
INC="-I$ROOT/core/include -I$HERE/shared"
DEFS="-DBKP_VERSION=\"$VERSION\""
[ -f "$WEIGHTS" ] || refuse "no weights at $WEIGHTS"
rm -rf "$OBJ"
mkdir -p "$OBJ/au" "$OBJ/vst3"

check_universal() {   # $1 = Mach-O file
  a=$(lipo -archs "$1" 2>&1) || { echo "$a" >&2; refuse "lipo failed on $1"; }
  [ "$a" = "x86_64 arm64" ] || refuse "$1 archs are '$a', want 'x86_64 arm64'"
  echo "lipo -archs: $a  ($(basename "$1"))"
}
sign_bundle() {       # $1 = bundle
  security find-identity -v -p codesigning | grep -q "$SIGN_ID" || refuse "signing identity '$SIGN_ID' is not in the keychain"
  out=$(codesign --force --options runtime --timestamp -s "$SIGN_ID" "$1" 2>&1) || { echo "$out" >&2; refuse "codesign failed on $1"; }
  out=$(codesign --verify --deep --strict --verbose=2 "$1" 2>&1) || { echo "$out" >&2; refuse "codesign --verify --deep --strict failed on $1"; }
  echo "signed + verified: $(basename "$1")"
}
bundle_skeleton() {   # $1 = bundle, $2 = Info.plist.in
  rm -rf "$1"
  mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
  sed -e "s/@VERSION@/$VERSION/g" -e "s/@AUVERSION@/$AUVERSION/g" "$2" > "$1/Contents/Info.plist"
  plutil -lint "$1/Contents/Info.plist" >/dev/null || refuse "$2 does not make a valid plist"
  printf 'BNDL????' > "$1/Contents/PkgInfo"
  cp "$WEIGHTS" "$1/Contents/Resources/deeptemp-k16-3.bkw"
}

echo "== the core"
sh "$ROOT/core/build.sh" >/dev/null || refuse "core/build.sh failed (run it alone to see why)"
check_universal "$CORELIB"

echo "== the instance layer + one face class per format"
clang++ -std=c++17 $CF $INC $DEFS -c shared/bkp.cpp -o "$OBJ/bkp.o"
clang -fobjc-arc $CF $INC -DBKP_VIEW_CLASS=BeatKeyAUFace -c shared/bkp_view.m -o "$OBJ/au/bkp_view.o"
clang -fobjc-arc $CF $INC -DBKP_VIEW_CLASS=BeatKeyVST3Face -c shared/bkp_view.m -o "$OBJ/vst3/bkp_view.o"

# ---- AU ----
echo "== AU: Beat Key.component"
SDK="$HERE/vendor/AudioUnitSDK-1.4.0"
[ -d "$SDK/src/AudioUnitSDK" ] || refuse "AudioUnitSDK not found at $SDK"
for f in "$SDK"/src/AudioUnitSDK/*.cpp; do
  n=$(basename "$f" .cpp)
  # vendored Apple code is compiled as shipped; its warnings are Apple's, ours stay -Werror
  clang++ -std=c++23 $ARCHS_FLAGS -O2 -g -fvisibility=hidden -w -I"$SDK/include" -c "$f" -o "$OBJ/au/sdk_$n.o"
done
clang++ -std=c++23 $CF $INC $DEFS -isystem "$SDK/include" -c au/beatkey_au.cpp -o "$OBJ/au/beatkey_au.o"
clang -fobjc-arc $CF $INC -c au/beatkey_au_view.m -o "$OBJ/au/beatkey_au_view.o"
AU="$OUT/Beat Key.component"
bundle_skeleton "$AU" au/Info.plist.in
clang++ -bundle $ARCHS_FLAGS -o "$AU/Contents/MacOS/Beat Key" "$OBJ"/au/*.o "$OBJ/bkp.o" "$CORELIB" \
  -framework Accelerate -framework AudioToolbox -framework AudioUnit -framework CoreAudio \
  -framework CoreFoundation -framework AppKit -framework Foundation \
  -Wl,-exported_symbols_list,"$HERE/au/exports.txt" || refuse "could not link the AU"
check_universal "$AU/Contents/MacOS/Beat Key"
sign_bundle "$AU"

# ---- VST3 ----
echo "== VST3: Beat Key.vst3"
PI="$HERE/vendor/vst3-pluginterfaces-3.8.1"
[ -d "$PI/pluginterfaces/base" ] || refuse "VST3 pluginterfaces not found at $PI"
for n in coreiids funknown; do
  clang++ -std=c++17 $ARCHS_FLAGS -O2 -g -fvisibility=hidden -w -I"$PI" -c "$PI/pluginterfaces/base/$n.cpp" -o "$OBJ/vst3/pi_$n.o"
done
clang++ -std=c++17 $CF $INC $DEFS -isystem "$PI" -c vst3/beatkey_vst3.cpp -o "$OBJ/vst3/beatkey_vst3.o"
clang++ -std=c++17 -fobjc-arc -x objective-c++ $CF $INC -isystem "$PI" -c vst3/beatkey_vst3_view.mm -o "$OBJ/vst3/beatkey_vst3_view.o"
V3="$OUT/Beat Key.vst3"
bundle_skeleton "$V3" vst3/Info.plist.in
sed -e "s/@VERSION@/$VERSION/g" vst3/moduleinfo.json.in > "$V3/Contents/Resources/moduleinfo.json"
python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$V3/Contents/Resources/moduleinfo.json" \
  || refuse "VST3 moduleinfo.json is not valid JSON"
clang++ -bundle $ARCHS_FLAGS -o "$V3/Contents/MacOS/Beat Key" "$OBJ"/vst3/*.o "$OBJ/bkp.o" "$CORELIB" \
  -framework Accelerate -framework CoreFoundation -framework AppKit -framework Foundation \
  -Wl,-exported_symbols_list,"$HERE/vst3/exports.txt" || refuse "could not link the VST3"
check_universal "$V3/Contents/MacOS/Beat Key"
sign_bundle "$V3"

echo "== smoke (no host)"
sh "$HERE/smoke.sh" || refuse "smoke failed (see above)"
echo "plugin/build.sh: done, version $VERSION, output in $OUT"
