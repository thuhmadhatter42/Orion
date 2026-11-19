#!/bin/bash
# app/pkg/test.sh: the installer's dry run (plan step 16). Builds the plug-in packages and the two installers
# from the REAL signed plug-in bundles in plugin/build.noindex (run `sh plugin/build.sh` first), UNSIGNED packages
# (PKG_SIGN_IDENTITY=-), in a scratch folder; installs nothing, notarizes nothing, opens no host.
# Checks: pkgbuild --analyze names each bundle; the component packages carry the right id, version and install
# location; the product expands and every bundle inside re-verifies; the AAX is refused while its marker exists,
# when missing, and when its seal is broken; BEATKEY_SKIP_AAX drops the AAX choice from both installers.
#   sh app/pkg/test.sh        exit 0 = all passed
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
S="$HERE/plugin-pkgs.sh"
OUTB="$ROOT/plugin/build.noindex"
W="$(mktemp -d "${TMPDIR:-/var/tmp}/beatkey-pkgtest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
FAILS=0; N=0
ok()   { N=$((N + 1)); echo "ok:   $*"; }
bad()  { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "FAIL: $*"; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
refuses() { local what="$1" want="$2"; shift 2; local out; out="$("$@" 2>&1)"; local rc=$?
  if [ $rc -ne 0 ] && grep -qF "$want" <<<"$out"; then ok "$what (refused: $want)"; else bad "$what (rc $rc, wanted '$want'; got: $(head -c 300 <<<"$out"))"; fi; }

[ -d "$OUTB/Beat Key.component" ] && [ -d "$OUTB/Beat Key.vst3" ] || { echo "no plug-in bundles in $OUTB: run sh plugin/build.sh first"; exit 2; }
export PKG_SIGN_IDENTITY=-
VER="$(tr -d '[:space:]' < "$ROOT/VERSION")"
export BEATKEY_VERSION="$VER"

# a stand-in AAX: the signed VST3 under the AAX name (the seal does not depend on the folder's extension). The real
# AAX is the AAX step's; this only proves the packaging path.
ditto "$OUTB/Beat Key.vst3" "$W/aax/Beat Key.aaxplugin"
ditto "$OUTB/Beat Key MIDI.vst3" "$W/aax/Beat Key MIDI.aaxplugin"
export BEATKEY_AAX="$W/aax/Beat Key.aaxplugin" BEATKEY_AAX_MIDI="$W/aax/Beat Key MIDI.aaxplugin" BEATKEY_AAX_MARKER="$W/AAX-NOT-PACE-SIGNED" BEATKEY_AAX_VERIFY="$W/none.sh"

echo "== full build: AU + VST3 + AAX, and the same three of Beat Key MIDI"
OUT="$W/out"
"$S" build "$OUT" >"$W/build.log" 2>&1 && ok "build exits 0" || { bad "build exits 0"; cat "$W/build.log"; }
for f in AU VST3 AAX AU-MIDI VST3-MIDI AAX-MIDI; do check "Beat-Key-$f.pkg exists" test -f "$OUT/components/Beat-Key-$f.pkg"; done
check "Beat-Key-Plug-ins.pkg exists" test -f "$OUT/Beat-Key-Plug-ins.pkg"
for pair in "AU:au:/Library/Audio/Plug-Ins/Components:Beat Key.component" "VST3:vst3:/Library/Audio/Plug-Ins/VST3:Beat Key.vst3" \
            "AAX:aax:/Library/Application Support/Avid/Audio/Plug-Ins:Beat Key.aaxplugin" \
            "AU-MIDI:midi.au:/Library/Audio/Plug-Ins/Components:Beat Key MIDI.component" "VST3-MIDI:midi.vst3:/Library/Audio/Plug-Ins/VST3:Beat Key MIDI.vst3" \
            "AAX-MIDI:midi.aax:/Library/Application Support/Avid/Audio/Plug-Ins:Beat Key MIDI.aaxplugin"; do
  IFS=: read -r F sfx DEST BUNDLE <<<"$pair"
  P="$OUT/components/Beat-Key-$F.pkg"
  X="$W/x-$F"; pkgutil --expand "$P" "$X" >/dev/null 2>&1
  pi="$X/PackageInfo"
  check "$F package id com.jshriver.orion.plugin.$sfx.pkg" grep -q "identifier=\"com.jshriver.orion.plugin.$sfx.pkg\"" "$pi"
  check "$F package version $VER" grep -q "version=\"$VER\"" "$pi"
  check "$F installs to $DEST" grep -qF "install-location=\"$DEST\"" "$pi"
  check "$F is not relocatable" grep -q 'relocatable="false"' "$pi"
  check "$F has a postinstall" test -f "$X/Scripts/postinstall"
  grep -q '@[A-Z]*@' "$X/Scripts/postinstall" 2>/dev/null && bad "$F postinstall still has a placeholder" || ok "$F postinstall is filled in"
  grep -qF "BUNDLE=\"$BUNDLE\"" "$X/Scripts/postinstall" && ok "$F postinstall names $BUNDLE" || bad "$F postinstall names $BUNDLE"
  bash -n "$X/Scripts/postinstall" && ok "$F postinstall parses" || bad "$F postinstall parses"
  lsbom -s "$X/Bom" 2>/dev/null | grep -q "^\./$BUNDLE\$" && ok "$F payload is $BUNDLE" || bad "$F payload is $BUNDLE"
  owner="$(lsbom "$X/Bom" 2>/dev/null | awk -F'\t' -v b="./$BUNDLE" '$1==b {print $3}')"
  [ "$owner" = "0/0" ] && ok "$F payload owned root:wheel ($owner)" || bad "$F payload owner is '$owner', want 0/0"
done
check "verify: product pkg, every bundle re-verified" "$S" verify "$OUT/Beat-Key-Plug-ins.pkg"
"$S" verify "$OUT/Beat-Key-Plug-ins.pkg" 2>&1 | grep -c 'verified inside' | grep -qx 6 && ok "verify saw 6 bundles in the product" || bad "verify saw 6 bundles in the product"

echo "== the main installer's description"
"$S" distribution "$HERE/distribution.xml" "$W/dist.xml" "$VER" "$OUT" && ok "distribution filled" || bad "distribution filled"
check "distribution has the AAX choice" grep -q 'com.jshriver.orion.plugin.aax"' "$W/dist.xml"
for c in midi.au midi.vst3 midi.aax; do check "distribution has the Beat Key MIDI $c choice" grep -q "com.jshriver.orion.plugin.$c\"" "$W/dist.xml"; done
mkdir -p "$W/main-pkgs"; cp "$OUT/components/"*.pkg "$W/main-pkgs/"
# a stand-in for the app component (the real one is the app build's): the same id as app/build.sh uses
mkdir -p "$W/app-root/Beat Key.app/Contents"; printf 'x' > "$W/app-root/Beat Key.app/Contents/x"
pkgbuild --root "$W/app-root" --identifier com.jshriver.orion.pkg --version "$VER" --install-location /Applications "$W/main-pkgs/Beat-Key-component.pkg" >/dev/null 2>&1
check "productbuild builds the main installer from distribution.xml" productbuild --distribution "$W/dist.xml" --package-path "$W/main-pkgs" "$W/Beat-Key-test.pkg"
pkgutil --expand "$W/Beat-Key-test.pkg" "$W/main-x" >/dev/null 2>&1
check "main installer Distribution lists the AAX choice" grep -q 'plugin.aax' "$W/main-x/Distribution"
check "main installer carries all seven components" test "$(ls -d "$W/main-x/"*.pkg | wc -l | tr -d ' ')" = 7

echo "== refusals"
: > "$W/AAX-NOT-PACE-SIGNED"
refuses "AAX marker present" "AAX not signed" "$S" build "$W/out2"
rm -f "$W/AAX-NOT-PACE-SIGNED"
refuses "AAX missing" "bundle not found" env BEATKEY_AAX="$W/nope/Beat Key.aaxplugin" "$S" build "$W/out3"
ditto "$OUTB/Beat Key.vst3" "$W/broken/Beat Key.aaxplugin"; printf 'tamper' >> "$W/broken/Beat Key.aaxplugin/Contents/Resources/deeptemp-k16-3.bkw"
refuses "AAX with a broken seal" "not signed or its seal is broken" env BEATKEY_AAX="$W/broken/Beat Key.aaxplugin" "$S" build "$W/out4"
printf 'exit 1\n' > "$W/verify-fail.sh"
refuses "AAX verify script says no" "AAX is not signed" env BEATKEY_AAX_VERIFY="$W/verify-fail.sh" "$S" build "$W/out5"
refuses "AAX MIDI missing" "bundle not found" env BEATKEY_AAX_MIDI="$W/nope/Beat Key MIDI.aaxplugin" "$S" build "$W/out8"
refuses "AU MIDI missing" "bundle not found" env BEATKEY_AU_MIDI="$W/nope/Beat Key MIDI.component" "$S" build "$W/out9"
ditto "$OUTB/Beat Key.component" "$W/unsigned/Beat Key.component"; codesign --remove-signature "$W/unsigned/Beat Key.component" 2>/dev/null
refuses "an unsigned AU" "not signed or its seal is broken" env BEATKEY_AU="$W/unsigned/Beat Key.component" "$S" build "$W/out6"
refuses "a version that is not N.N.N" "not major.minor.patch" env BEATKEY_VERSION=abc "$S" build "$W/out7"

echo "== without AAX"
BEATKEY_SKIP_AAX=1 "$S" build "$W/noaax" >"$W/noaax.log" 2>&1 && ok "BEATKEY_SKIP_AAX=1 builds" || { bad "BEATKEY_SKIP_AAX=1 builds"; cat "$W/noaax.log"; }
grep -q 'NO AAX' "$W/noaax.log" && ok "it says so loudly" || bad "it says so loudly"
check "no AAX component" test ! -f "$W/noaax/components/Beat-Key-AAX.pkg"
check "no AAX MIDI component" test ! -f "$W/noaax/components/Beat-Key-AAX-MIDI.pkg"
check "the MIDI AU and VST3 still packed" test -f "$W/noaax/components/Beat-Key-AU-MIDI.pkg" -a -f "$W/noaax/components/Beat-Key-VST3-MIDI.pkg"
check "product has no AAX MIDI choice" test "$(grep -c 'midi.aax' "$W/noaax/plugins-distribution.xml")" = 0
check "product has no AAX choice" test "$(grep -c 'plugin.aax' "$W/noaax/plugins-distribution.xml")" = 0
"$S" distribution "$HERE/distribution.xml" "$W/dist-noaax.xml" "$VER" "$W/noaax" && ok "main distribution without AAX is valid XML" || bad "main distribution without AAX"
check "main distribution has no AAX choice left" test "$(grep -c 'plugin.aax' "$W/dist-noaax.xml")" = 0
check "main distribution has no AAX MIDI choice left" test "$(grep -c 'midi.aax' "$W/dist-noaax.xml")" = 0
check "verify: the AAX-less product" "$S" verify "$W/noaax/Beat-Key-Plug-ins.pkg"

echo
if [ "$FAILS" -eq 0 ]; then echo "app/pkg/test.sh: $N checks, 0 failed"; exit 0; else echo "app/pkg/test.sh: $N checks, $FAILS FAILED"; exit 1; fi
