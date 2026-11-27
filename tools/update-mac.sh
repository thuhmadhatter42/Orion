#!/bin/bash
# Put the Beat Key just built (app/build/Beat Key.app + plugin/build.noindex plug-ins) on another Mac,
# no installer, no sudo: each copy already on that Mac is moved to its user's Trash and replaced.
#   tools/update-mac.sh <ssh target> [<ssh target> ...]     e.g. jshriver@js-mac-pro j@studio-d
# Per Mac: skips it if Pro Tools / Logic / Live is running; quits Beat Key first and reopens it only if
# it was running; temp files only in "~/Downloads/beatkey temp/" (emptied at the end, J 2026-11-20 SOP).
# Plug-ins are replaced where a copy already is; a Mac with none gets them in /Library when writable.
# Log per Mac: app/build/update-<version>/<target>.log. Judge by its "== done <version>" line.
set -u
cd "$(dirname "$0")/.."
APP="app/build/Beat Key.app"; PLUG=plugin/build.noindex
V=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString) || { echo "no built app"; exit 1; }
[ "$V" = "$(tr -d '[:space:]' < VERSION)" ] || { echo "built app is $V, VERSION says $(cat VERSION)"; exit 1; }
OUT=app/build/update-$V; mkdir -p "$OUT"
ZIP=$OUT/beatkey-$V.zip
if [ ! -f "$ZIP" ]; then
  S=$(mktemp -d); ditto "$APP" "$S/Beat Key.app"
  for b in "Beat Key.component" "Beat Key MIDI.component" "Beat Key.vst3" "Beat Key MIDI.vst3" "Beat Key.aaxplugin" "Beat Key MIDI.aaxplugin"; do
    ditto "$PLUG/$b" "$S/$b"; done
  (cd "$S" && ditto -c -k --sequesterRsrc . "$OLDPWD/$ZIP"); rm -rf "$S"
fi
cat > "$OUT/remote.sh" <<'R'
#!/bin/bash
V=$1; T="$HOME/Downloads/beatkey temp"; Z="$T/beatkey-$V.zip"; N="$T/new-$V"; now=$(date +%H%M%S)
echo "== $(date) $(scutil --get ComputerName) $(whoami) macOS $(sw_vers -productVersion) $(uname -m)"
if pgrep -xq "Pro Tools" || pgrep -xq "Logic Pro X" || pgrep -xq "Logic Pro" || pgrep -xq "Live"; then
  echo "SKIP: a DAW is running"; exit 3; fi
running=0; pgrep -f "Beat Key.app/Contents/MacOS/Orion" >/dev/null && running=1
[ $running = 1 ] && { osascript -e 'tell application "Beat Key" to quit' >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "Beat Key.app/Contents/MacOS/Orion" >/dev/null || break; sleep 1; done
  pgrep -f "Beat Key.app/Contents/MacOS/Orion" >/dev/null && { echo "FAIL: Beat Key would not quit"; exit 4; }; }
rm -rf "$N"; mkdir -p "$N"; ditto -x -k "$Z" "$N" || { echo "FAIL: unzip"; exit 5; }
ver() { defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?"; }
swap() { # $1 new bundle, $2 installed path
  local old; old=$(ver "$2")
  [ "$old" = "$V" ] && { echo "already $V: $2"; return; }
  [ -O "$2" ] || { echo "SKIP (owned by $(stat -f %Su "$2"); the pkg installer replaces it): $2"; return; }
  mv "$2" "$HOME/.Trash/$(basename "$2" | sed 's/\.[^.]*$//')-$old-$now.${2##*.}" && echo "trashed $2"
  ditto "$1" "$2" && echo "$2 $old -> $(ver "$2")" || echo "ERROR copying to $2"; }
if [ -d "/Applications/Beat Key.app" ]; then swap "$N/Beat Key.app" "/Applications/Beat Key.app"
else ditto "$N/Beat Key.app" "/Applications/Beat Key.app" && echo "new /Applications/Beat Key.app $(ver "/Applications/Beat Key.app")"; fi
for b in "Beat Key.component" "Beat Key MIDI.component" "Beat Key.vst3" "Beat Key MIDI.vst3" "Beat Key.aaxplugin" "Beat Key MIDI.aaxplugin"; do
  case "$b" in *.component) dirs=("/Library/Audio/Plug-Ins/Components" "$HOME/Library/Audio/Plug-Ins/Components");;
    *.vst3) dirs=("/Library/Audio/Plug-Ins/VST3" "$HOME/Library/Audio/Plug-Ins/VST3");;
    *.aaxplugin) dirs=("/Library/Application Support/Avid/Audio/Plug-Ins");; esac
  found=0
  for d in "${dirs[@]}"; do [ -d "$d/$b" ] && { found=1; swap "$N/$b" "$d/$b"; }; done
  if [ $found = 0 ]; then d=${dirs[0]}
    if [ -w "$d" ]; then ditto "$N/$b" "$d/$b" && echo "new $d/$b $(ver "$d/$b")"; else echo "not installed (no copy here, $d not writable): $b"; fi; fi
done
rm -rf "$N" "$Z"; rmdir "$T" 2>/dev/null
[ $running = 1 ] && open -a "/Applications/Beat Key.app" && echo "reopened Beat Key"
echo "app now $(ver "/Applications/Beat Key.app")"
echo "== done $V"
R
for H in "$@"; do
  L="$OUT/${H//[@\/]/_}.log"
  { ssh -o ConnectTimeout=10 "$H" 'mkdir -p "$HOME/Downloads/beatkey temp"' &&
    ssh "$H" "cat > \"\$HOME/Downloads/beatkey temp/beatkey-$V.zip\"" < "$ZIP" &&
    ssh "$H" 'cat > "$HOME/Downloads/beatkey temp/remote.sh"' < "$OUT/remote.sh" &&
    ~/.claude/scripts/ssh-rc "$H" "bash \"\$HOME/Downloads/beatkey temp/remote.sh\" $V; rm -f \"\$HOME/Downloads/beatkey temp/remote.sh\"; rmdir \"\$HOME/Downloads/beatkey temp\" 2>/dev/null; true"
  } > "$L" 2>&1
  echo "--- $H"; cat "$L"
done
