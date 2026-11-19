# plugin/build-midi.sh: Beat Key MIDI, the MIDI variant (plan step 15).  SOURCED by plugin/build.sh after the
# plain AU and VST3, never run alone: it uses that script's variables (OUT, OBJ, CF, INC, DEFS, SDK, PI,
# CORELIB, ARCHS_FLAGS, VERSION), its helpers (bundle_skeleton, check_universal, sign_bundle, refuse) and
# its objects (the AU SDK objects, the VST3 interface objects, the instance layer's bkp.o).
#
#   plugin/build.noindex/Beat Key MIDI.component   AU    (aumf BtKM FLRc, factory BeatKeyMIDIAUFactory)
#   plugin/build.noindex/Beat Key MIDI.vst3        VST3  (class 42744B794D49444956535433464C5263)
#
# The same shim sources as Beat Key, compiled with -DBKP_MIDI=1 (an event output / a MIDI output callback,
# the notes from bkp_midi_process).  Each has its own Swift module (BeatKeyAUMIDI, BeatKeyVST3MIDI) and
# Objective-C class names, so all four bundles can sit in one host (A6).  Signed and verified like the others.
[ -n "$OBJ" ] && [ -n "$SDK" ] && [ -n "$PI" ] || { echo "plugin/build-midi.sh: REFUSED: source it from plugin/build.sh" >&2; exit 1; }

echo "== the MIDI variant's faces (BeatKeyAUMIDI, BeatKeyVST3MIDI)"
mkdir -p "$OBJ/au-midi" "$OBJ/vst3-midi"
sh ui/build-face.sh BeatKeyAUMIDI "$OBJ/au-midi" "$VERSION" || refuse "the AU MIDI face did not build"
sh ui/build-face.sh BeatKeyVST3MIDI "$OBJ/vst3-midi" "$VERSION" || refuse "the VST3 MIDI face did not build"

echo "== AU: Beat Key MIDI.component"
clang++ -std=c++23 $CF $INC $DEFS -DBKP_MIDI=1 -isystem "$SDK/include" -c au/beatkey_au.cpp -o "$OBJ/au-midi/beatkey_au.o"
clang -fobjc-arc $CF $INC -DBKP_MIDI=1 -c au/beatkey_au_view.m -o "$OBJ/au-midi/beatkey_au_view.o"
AUM="$OUT/Beat Key MIDI.component"
bundle_skeleton "$AUM" au/Info-MIDI.plist.in
clang++ -bundle $ARCHS_FLAGS -o "$AUM/Contents/MacOS/Beat Key" "$OBJ"/au-midi/*.o "$OBJ"/au/sdk_*.o "$OBJ/bkp.o" "$CORELIB" \
  -framework Accelerate -framework AudioToolbox -framework AudioUnit -framework CoreAudio -framework CoreMIDI \
  -framework CoreFoundation -framework AppKit -framework Foundation $(cat "$OBJ/au-midi/face.ldflags") \
  -Wl,-exported_symbols_list,"$HERE/au/exports-MIDI.txt" || refuse "could not link the AU MIDI"
check_universal "$AUM/Contents/MacOS/Beat Key"
sign_bundle "$AUM"

echo "== VST3: Beat Key MIDI.vst3"
clang++ -std=c++17 $CF $INC $DEFS -DBKP_MIDI=1 -isystem "$PI" -c vst3/beatkey_vst3.cpp -o "$OBJ/vst3-midi/beatkey_vst3.o"
clang++ -std=c++17 -fobjc-arc -x objective-c++ $CF $INC -DBKP_MIDI=1 -isystem "$PI" -c vst3/beatkey_vst3_view.mm -o "$OBJ/vst3-midi/beatkey_vst3_view.o"
V3M="$OUT/Beat Key MIDI.vst3"
bundle_skeleton "$V3M" vst3/Info-MIDI.plist.in
sed -e "s/@VERSION@/$VERSION/g" vst3/moduleinfo-MIDI.json.in > "$V3M/Contents/Resources/moduleinfo.json"
python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$V3M/Contents/Resources/moduleinfo.json" \
  || refuse "VST3 MIDI moduleinfo.json is not valid JSON"
clang++ -bundle $ARCHS_FLAGS -o "$V3M/Contents/MacOS/Beat Key" "$OBJ"/vst3-midi/*.o "$OBJ"/vst3/pi_*.o "$OBJ/bkp.o" "$CORELIB" \
  -framework Accelerate -framework CoreFoundation -framework AppKit -framework Foundation $(cat "$OBJ/vst3-midi/face.ldflags") \
  -Wl,-exported_symbols_list,"$HERE/vst3/exports.txt" || refuse "could not link the VST3 MIDI"
check_universal "$V3M/Contents/MacOS/Beat Key"
sign_bundle "$V3M"
