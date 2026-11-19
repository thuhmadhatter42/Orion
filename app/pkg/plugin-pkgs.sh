#!/bin/bash
# app/pkg/plugin-pkgs.sh: the plug-in half of the Beat Key installer (plan step 16, §Q4: ONE download).
# app/build.sh calls it; every subcommand also runs by hand on scratch bundles (the gate does).
#
#   plugin-pkgs.sh build <outdir>
#       Packs each plug-in bundle into its own component package (plain payload, system-wide, no
#       relocation) and the three into Beat-Key-Plug-ins.pkg, the small installer the app carries to
#       update the plug-ins (Beat Key menu > Update Plug-ins...). Writes <outdir>/components/*.pkg
#       and <outdir>/Beat-Key-Plug-ins.pkg. Refuses (reason on stderr, exit 1) when a bundle is
#       missing, unsigned, not universal, or when the AAX is not signed.
#   plugin-pkgs.sh distribution <template.xml> <out.xml> <version> <outdir>
#       Fills @VERSION@ and drops the AAX choice when the build skipped AAX (BEATKEY_SKIP_AAX=1).
#   plugin-pkgs.sh verify <pkg>
#       Expands a .pkg (pkgutil --expand-full) and re-verifies every bundle inside with
#       codesign --verify --deep --strict; checks each component installs where its format belongs.
#
# Environment (all optional):
#   BEATKEY_VERSION        default: ../../VERSION
#   BEATKEY_AU / _VST3 / _AAX   bundle paths, default plugin/build.noindex/Beat Key.{component,vst3,aaxplugin}
#   BEATKEY_SKIP_AAX=1     build WITHOUT the AAX (says so loudly; the installer then has no AAX choice)
#   BEATKEY_AAX_MARKER     plugin/build.noindex/AAX-NOT-SIGNED: the file plugin/build.sh leaves when the AAX
#                          signing step did not run (A6). While it exists, this script refuses to package.
#   BEATKEY_AAX_VERIFY     ~/.config/beat-key/aax-verify.sh (outside the repo, beside the signing script): run as
#                          `sh <it> <bundle>`; non-zero refuses. The repo never holds how the AAX is signed.
#   PKG_SIGN_IDENTITY      Developer ID Installer: J Shriver (9WTFGV63S2); "-" leaves the packages unsigned
#                          (scratch runs only; app/build.sh never passes "-")
#   BEATKEY_PKG_LOG        a file that gets every line this script prints (the build's log)
# Never writes outside <outdir>; never installs; never opens a plug-in host.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PLUGIN_OUT="$ROOT/plugin/build.noindex"
AU="${BEATKEY_AU:-$PLUGIN_OUT/Beat Key.component}"
VST3="${BEATKEY_VST3:-$PLUGIN_OUT/Beat Key.vst3}"
AAX="${BEATKEY_AAX:-$PLUGIN_OUT/Beat Key.aaxplugin}"
MARKER="${BEATKEY_AAX_MARKER:-$PLUGIN_OUT/AAX-NOT-SIGNED}"
AAX_VERIFY="${BEATKEY_AAX_VERIFY:-$HOME/.config/beat-key/aax-verify.sh}"
PKG_IDENTITY="${PKG_SIGN_IDENTITY:-Developer ID Installer: J Shriver (9WTFGV63S2)}"
SKIP_AAX="${BEATKEY_SKIP_AAX:-0}"

# where each format belongs (system-wide, like every plug-in; J 2026-09-10, Zeropoint's ruling)
DEST_AU="/Library/Audio/Plug-Ins/Components"
DEST_VST3="/Library/Audio/Plug-Ins/VST3"
DEST_AAX="/Library/Application Support/Avid/Audio/Plug-Ins"
ID_PREFIX="com.jshriver.orion.plugin"          # + .au / .vst3 / .aax, then .pkg

say()    { echo "plugin-pkgs: $*"; [ -z "${BEATKEY_PKG_LOG:-}" ] || echo "plugin-pkgs: $*" >> "$BEATKEY_PKG_LOG"; }
refuse() { echo "plugin-pkgs: REFUSED: $*" >&2; [ -z "${BEATKEY_PKG_LOG:-}" ] || echo "plugin-pkgs: REFUSED: $*" >> "$BEATKEY_PKG_LOG"; exit 1; }

version() {
  local v="${BEATKEY_VERSION:-}"
  [ -n "$v" ] || { [ -f "$ROOT/VERSION" ] || refuse "no VERSION at $ROOT/VERSION"; v="$(tr -d '[:space:]' < "$ROOT/VERSION")"; }
  case "$v" in [0-9]*.[0-9]*.[0-9]*) echo "$v" ;; *) refuse "version '$v' is not major.minor.patch" ;; esac
}

# check_bundle <bundle> <label>: it exists, is signed and seals, is universal in every Mach-O it runs.
check_bundle() {
  local b="$1" label="$2" out exe a
  [ -d "$b" ] || refuse "$label bundle not found: $b (build it: sh plugin/build.sh)"
  out="$(codesign --verify --deep --strict --verbose=2 "$b" 2>&1)" || { echo "$out" >&2; refuse "$label bundle is not signed or its seal is broken: $b"; }
  exe="$b/Contents/MacOS/$(plutil -extract CFBundleExecutable raw -o - "$b/Contents/Info.plist" 2>/dev/null || true)"
  [ -f "$exe" ] || refuse "$label bundle has no executable at $exe"
  a="$(lipo -archs "$exe" 2>&1)" || { echo "$a" >&2; refuse "lipo failed on $exe"; }
  case "$a" in *arm64*x86_64*|*x86_64*arm64*) ;; *) refuse "$label executable is '$a', not universal (arm64 + x86_64)" ;; esac
  say "$label ok: $(basename "$b") $(plutil -extract CFBundleShortVersionString raw -o - "$b/Contents/Info.plist" 2>/dev/null) ($a), signature seals"
}

# check_aax: the AAX is built, sealed and signed. How it is signed stays outside the repo (A6, L6).
check_aax() {
  [ ! -e "$MARKER" ] || refuse "AAX not signed: $MARKER exists (plugin/build.sh left it because the AAX signing step did not run). Sign the AAX (see the plan's A6), or build with BEATKEY_SKIP_AAX=1 to ship without AAX"
  check_bundle "$AAX" AAX
  if [ -f "$AAX_VERIFY" ]; then
    sh "$AAX_VERIFY" "$AAX" >/dev/null 2>&1 || refuse "the AAX verify step ($AAX_VERIFY) failed on $AAX: the AAX is not signed"
    say "AAX ok: verify step passed"
  else
    say "NOTE: no AAX verify script at $AAX_VERIFY; the AAX's signing marker is absent and its seal verifies, but no separate signature check ran"
  fi
}

# component <name> <bundle> <dest> <id-suffix> <outdir>: one component package, plain payload.
component() {
  local name="$1" bundle="$2" dest="$3" suffix="$4" out="$5" ver stage base
  ver="$(version)"; base="$(basename "$bundle")"
  stage="$out/stage-$suffix"
  rm -rf "$stage"; mkdir -p "$stage/root" "$stage/scripts"
  ditto --norsrc --noextattr --noqtn "$bundle" "$stage/root/$base"        # ditto, never cp -R (AAX bundles, A1)
  codesign --verify --deep --strict "$stage/root/$base" 2>/dev/null || refuse "the copy of $base no longer verifies (the seal broke while staging)"
  sed -e "s|@FORMAT@|$name|g" -e "s|@BUNDLE@|$base|g" -e "s|@DEST@|$dest|g" "$HERE/plugin-postinstall" > "$stage/scripts/postinstall"
  chmod 755 "$stage/scripts/postinstall"
  # the analysis names the bundle; then it is made non-relocatable. Without that, Installer "upgrades" a copy it finds
  # elsewhere (a user-folder test install, a build folder) instead of laying ours down where the host looks.
  pkgbuild --analyze --root "$stage/root" "$stage/component.plist" >/dev/null || refuse "pkgbuild --analyze failed on $base"
  /usr/libexec/PlistBuddy -c "Print :0:RootRelativeBundlePath" "$stage/component.plist" | grep -qxF "$base" \
    || refuse "pkgbuild --analyze did not name $base as the component"
  for k in BundleIsRelocatable BundleIsVersionChecked BundleHasStrictIdentifier; do
    /usr/libexec/PlistBuddy -c "Set :0:$k false" "$stage/component.plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :0:$k bool false" "$stage/component.plist"
  done
  /usr/libexec/PlistBuddy -c "Set :0:BundleOverwriteAction upgrade" "$stage/component.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :0:BundleOverwriteAction string upgrade" "$stage/component.plist"
  mkdir -p "$out/components"
  pkgbuild --root "$stage/root" --component-plist "$stage/component.plist" --scripts "$stage/scripts" \
    --identifier "$ID_PREFIX.$suffix.pkg" --version "$ver" --install-location "$dest" --ownership recommended \
    "$out/components/Beat-Key-$name.pkg" >/dev/null
  say "component: Beat-Key-$name.pkg -> $dest/$base ($ID_PREFIX.$suffix.pkg $ver)"
  rm -rf "$stage"
}

sign_args() { [ "$PKG_IDENTITY" = "-" ] || printf '%s\n' --sign "$PKG_IDENTITY" --timestamp; }

cmd_build() {
  local out="${1:?usage: plugin-pkgs.sh build <outdir>}" ver pk
  ver="$(version)"
  [ "$PKG_IDENTITY" = "-" ] || security find-identity -v | grep -qF "\"$PKG_IDENTITY\"" || refuse "no '$PKG_IDENTITY' installer identity in the keychain"
  rm -rf "$out"; mkdir -p "$out"
  say "plug-ins for Beat Key $ver"
  check_bundle "$AU" AU
  check_bundle "$VST3" VST3
  if [ "$SKIP_AAX" = 1 ]; then
    say "WARNING: BEATKEY_SKIP_AAX=1: this installer has NO AAX (Pro Tools gets nothing from it)"
    : > "$out/skip-aax"
  else
    check_aax
  fi
  component AU   "$AU"   "$DEST_AU"   au   "$out"
  component VST3 "$VST3" "$DEST_VST3" vst3 "$out"
  [ "$SKIP_AAX" = 1 ] || component AAX "$AAX" "$DEST_AAX" aax "$out"
  # the small product the app carries: just the plug-ins, no "Beat Key is open" check (the app is what runs it)
  pk="$out/Beat-Key-Plug-ins.pkg"
  cmd_distribution "$HERE/plugins-distribution.xml" "$out/plugins-distribution.xml" "$ver" "$out"
  # shellcheck disable=SC2046
  productbuild --distribution "$out/plugins-distribution.xml" --package-path "$out/components" $(sign_args) "$pk" >/dev/null
  [ "$PKG_IDENTITY" = "-" ] || pkgutil --check-signature "$pk" >/dev/null || refuse "$pk is not signed"
  say "product: $(basename "$pk") ($(du -h "$pk" | cut -f1))"
}

cmd_distribution() {
  local in="${1:?template}" out="${2:?out}" ver="${3:?version}" dir="${4:?outdir}"
  [ -f "$in" ] || refuse "no distribution template $in"
  if [ -f "$dir/skip-aax" ]; then
    sed -e "s/@VERSION@/$ver/g" -e '/BEGIN AAX/,/END AAX/d' "$in" > "$out"
  else
    sed -e "s/@VERSION@/$ver/g" "$in" > "$out"
  fi
  xmllint --noout "$out" || refuse "$out is not valid XML"
  grep -q '@[A-Z]*@' "$out" && refuse "$out still has a @PLACEHOLDER@"
  return 0
}

# verify <pkg>: expand it and check what is inside, as it would land.
cmd_verify() {
  local pkg="${1:?usage: plugin-pkgs.sh verify <pkg>}" d n=0 b loc info want
  [ -f "$pkg" ] || refuse "no package at $pkg"
  d="$(mktemp -d "${TMPDIR:-/var/tmp}/beatkey-pkgverify.XXXXXX")"
  rm -rf "$d"   # pkgutil wants to make the folder itself
  pkgutil --expand-full "$pkg" "$d" >/dev/null || refuse "pkgutil could not expand $pkg"
  while IFS= read -r b; do
    n=$((n + 1))
    out="$(codesign --verify --deep --strict --verbose=2 "$b" 2>&1)" || { echo "$out" >&2; rm -rf "$d"; refuse "inside $(basename "$pkg"): $(basename "$b") does not verify"; }
    case "$b" in
      *.component) want="$DEST_AU" ;; *.vst3) want="$DEST_VST3" ;; *.aaxplugin) want="$DEST_AAX" ;; *.app) want="/Applications" ;; *) want="" ;;
    esac
    info="$(dirname "$b")"; info="${info%/Payload}"; [ -f "$info/PackageInfo" ] || info="${info%/*}"
    loc="$(sed -n 's/.*install-location="\([^"]*\)".*/\1/p' "$info/PackageInfo" 2>/dev/null | head -1)"
    [ "$loc" = "$want" ] || { rm -rf "$d"; refuse "inside $(basename "$pkg"): $(basename "$b") installs to '$loc', want '$want'"; }
    say "verified inside $(basename "$pkg"): $(basename "$b") -> $loc"
  done < <(find "$d" -maxdepth 6 \( -name '*.component' -o -name '*.vst3' -o -name '*.aaxplugin' -o -name '*.app' \) -type d -not -path '*/Contents/*')
  rm -rf "$d"
  [ "$n" -gt 0 ] || refuse "no bundle found inside $pkg"
  say "verify ok: $n bundle(s) in $(basename "$pkg")"
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  distribution) shift; cmd_distribution "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  *) sed -n '2,29p' "$0"; exit 2 ;;
esac
