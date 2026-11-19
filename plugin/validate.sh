#!/bin/sh
# plugin/validate.sh: the validator gate (plan step 8), on BOTH slices, Beat Key's own bundles ONLY.
#   sh plugin/validate.sh            install the built bundles into ~/Library/Audio/Plug-Ins, run the gate
#   sh plugin/validate.sh --remove   take them out of ~/Library/Audio/Plug-Ins again (to the Trash)
#   sh plugin/validate.sh --midi [--remove]   the same for Beat Key MIDI (plan step 15: aumf BtKM FLRc, its .vst3)
#
#   1. auval -v aufx BtKy FLRc, native (arm64) and under arch -x86_64
#   2. Steinberg's VST3 validator (plugin/tools/build-vst3-validator.sh) on the .vst3, arm64 and x86_64
#   3. pluginval --strictness-level 10, wide sample-rate and block-size sweep, on the .vst3 (with
#      --vst3validator) and on the installed .component, arm64 and x86_64
#   4. Every log is read: each sub-validator must PROVE it ran (A1.1).  A skipped step is a FAIL.
#
# Never scans: no `auval -a`, no host, no other plug-in is named or touched (J, 2026-11-19).
# pluginval runs with --skip-gui-tests on the MacBook Pro: J's screen gets no windows; the editor test
# belongs to step 9 (the face), on Sofia.  Logs: plugin/build.noindex/validate/.  Exit 0 = all green.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
fail() { echo "plugin/validate.sh: FAIL: $*" >&2; exit 1; }
OUT="$HERE/build.noindex"
NAME="Beat Key"; AU_CODE="aufx BtKy FLRc"
if [ "$1" = "--midi" ]; then NAME="Beat Key MIDI"; AU_CODE="aumf BtKM FLRc"; shift; fi
AU_SRC="$OUT/$NAME.component"
V3_SRC="$OUT/$NAME.vst3"
AU_DST="$HOME/Library/Audio/Plug-Ins/Components/$NAME.component"
V3_DST="$HOME/Library/Audio/Plug-Ins/VST3/$NAME.vst3"
PLUGINVAL=${PLUGINVAL:-/Applications/pluginval.app/Contents/MacOS/pluginval}
LOGS="$OUT/validate"
[ "$NAME" = "Beat Key" ] || LOGS="$OUT/validate-midi"

if [ "$1" = "--remove" ]; then
  for b in "$AU_DST" "$V3_DST"; do
    if [ -e "$b" ]; then
      /usr/bin/trash "$b" || fail "could not move $b to the Trash"
      echo "removed (Trash): $b"
    fi
  done
  exit 0
fi

[ -d "$AU_SRC" ] && [ -d "$V3_SRC" ] || fail "build first: sh plugin/build.sh"
[ -x "$PLUGINVAL" ] || fail "pluginval not found at $PLUGINVAL"
VALIDATOR=${VST3_VALIDATOR:-$OUT/vst3sdk-build/bin/Release/validator}
[ -x "$VALIDATOR" ] || VALIDATOR=$(sh "$HERE/tools/build-vst3-validator.sh") || fail "no VST3 validator"
for s in "/Library/Audio/Plug-Ins/Components/$NAME.component" "/Library/Audio/Plug-Ins/VST3/$NAME.vst3"; do
  [ -e "$s" ] && fail "$s exists system-wide and would shadow the build under test (A1.7); remove it first"
done
rm -rf "$LOGS"; mkdir -p "$LOGS"

echo "== install the test builds (user folder only)"
mkdir -p "$(dirname "$AU_DST")" "$(dirname "$V3_DST")"
rm -rf "$AU_DST" "$V3_DST"
ditto "$AU_SRC" "$AU_DST"
ditto "$V3_SRC" "$V3_DST"
codesign --verify --deep --strict "$AU_DST" && codesign --verify --deep --strict "$V3_DST" || fail "installed copies do not verify"
echo "$AU_DST"; echo "$V3_DST"

need() {   # $1 log, $2 grep -E pattern that proves the step ran, $3 what
  grep -Eq "$2" "$1" || fail "$3: no proof it ran in $1 (looked for: $2)"
}

echo "== 1. auval -v $AU_CODE ($NAME)"
for slice in arm64 x86_64; do
  log="$LOGS/auval-$slice.txt"
  ok=0
  for try in 1 2 3 4 5 6; do   # the component registrar needs a moment to see a newly installed AU
    # shellcheck disable=SC2086
    if arch -$slice auval -v $AU_CODE > "$log" 2>&1; then ok=1; break; fi
    grep -q "didn't find the component" "$log" || break
    sleep 10
  done
  [ $ok = 1 ] || { tail -20 "$log"; fail "auval ($slice)"; }
  need "$log" "AU VALIDATION SUCCEEDED" "auval ($slice)"
  need "$log" "TESTING OPEN TIMES" "auval ($slice) open"
  need "$log" "RENDER TESTS" "auval ($slice) render"
  echo "auval $slice: $(grep -c 'PASS' "$log") PASS lines, $(grep -c 'WARNING' "$log") warnings, AU VALIDATION SUCCEEDED"
done

echo "== 2. Steinberg VST3 validator"
for slice in arm64 x86_64; do
  log="$LOGS/vst3validator-$slice.txt"
  arch -$slice "$VALIDATOR" "$V3_DST" > "$log" 2>&1 || { tail -30 "$log"; fail "VST3 validator ($slice)"; }
  need "$log" "Result: [0-9]+ tests passed, 0 tests failed" "VST3 validator ($slice)"
  echo "validator $slice: $(grep -E 'Result:' "$log" | tail -1)"
done

echo "== 3. pluginval, strictness 10"
SR=44100,48000,88200,96000,176400,192000
BS=16,32,64,128,256,512,1024,2048
for slice in arm64 x86_64; do
  for kind in vst3 au; do
    if [ $kind = vst3 ]; then target=$V3_DST; extra="--vst3validator $VALIDATOR"; else target=$AU_DST; extra=""; fi
    log="$LOGS/pluginval-$kind-$slice.txt"
    # no trailing slash on the path (A1.2): it would find 0 plug-ins and fail falsely
    arch -$slice "$PLUGINVAL" --strictness-level 10 --skip-gui-tests --verbose --timeout-ms 120000 \
      --sample-rates $SR --block-sizes $BS $extra --validate "$target" > "$log" 2>&1 \
      || { tail -40 "$log"; fail "pluginval $kind ($slice)"; }
    need "$log" "SUCCESS" "pluginval $kind ($slice)"
    need "$log" "^Num plugins found: 1$" "pluginval $kind ($slice) found the plug-in"
    sweep=$(grep -c '^Testing with sample rate' "$log")
    [ "$sweep" -ge 96 ] || fail "pluginval $kind ($slice): only $sweep rate x block runs (want 6 x 8 in each processing test)"
    grep -q "FAILED" "$log" && fail "pluginval $kind ($slice): a FAILED line in $log"
    if [ $kind = vst3 ]; then
      need "$log" "vst3 validator exited with code: 0" "pluginval's VST3 validator step ($slice)"
      need "$log" "Result: [0-9]+ tests passed, 0 tests failed" "pluginval's VST3 validator output ($slice)"
    else
      need "$log" "AU VALIDATION SUCCEEDED" "pluginval's auval step ($slice)"
      need "$log" "VALIDATING AUDIO UNIT: '${AU_CODE%% *}'" "pluginval's auval step named $AU_CODE ($slice)"
    fi
    echo "pluginval $kind $slice: $(grep -c '^Starting tests in' "$log") test groups, $sweep rate x block runs, SUCCESS"
  done
done
echo "plugin/validate.sh: PASS $NAME (auval, VST3 validator, pluginval 10; arm64 and x86_64). Logs: $LOGS"
