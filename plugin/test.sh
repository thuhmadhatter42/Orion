#!/bin/sh
# plugin/test.sh: the plug-in's gate without a host (plan steps 7 and 8).
#   sh plugin/test.sh [passthru|tripwire|live|state|marker ...]     (default: everything)
#
#  1. core/build.sh (the core's universal library) and the instance layer, universal.
#  2. bkp_test (plugin/test/bkp_test.cpp) linked against the core's tripwire dylib, run on BOTH
#     slices: arm64, then x86_64 (`arch -x86_64`: Rosetta here, native on an Intel Mac).  A slice this
#     Mac cannot run is a FAIL, never a skip.
#  3. vst3_harness (plugin/test/vst3_harness.cpp): the VST3 shim's own objects driven directly, no host, on
#     both slices: factory, Bypass parameter, the real process() under the tripwire, state and its refusals.
#     The AU shim has no direct harness (the SDK needs an AudioComponent); auval drives it in plugin/validate.sh.
#     Built twice: Beat Key, and Beat Key MIDI (BKP_MIDI=1, plan step 15: the event bus and the notes).
#  4. face_test (plugin/test/face_test.swift), both slices: the SwiftUI face and both buttons without a host
#     (shared code, a real reading through the token, SEND AUTO-TUNE to a temp path, SEND BPM against a fake
#     app, the MIDI variant's chords / lines / drag-out .mid); offscreen renders in plugin/build.noindex/face-shots
#     (no window on screen).
# The validator gate (auval, pluginval, Steinberg's validator) is plugin/validate.sh; it needs the
# built bundles installed in ~/Library/Audio/Plug-Ins.
# Scratch: plugin/build.noindex/test.XXXXXX, removed on every way out.  Logs go there, never to
# ~/Library/Logs.  Nothing is installed, signed or launched.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
fail() { echo "plugin/test.sh: FAIL: $*" >&2; exit 1; }

sh "$ROOT/core/build.sh"
VERSION=$(tr -d ' \n' < "$ROOT/VERSION")
OUT="$HERE/build.noindex"
mkdir -p "$OUT"
WEIGHTS="$ROOT/models/deeptemp-k16-3.bkw"
[ -f "$WEIGHTS" ] || fail "no weights at $WEIGHTS"
TMP=$(mktemp -d "$OUT/test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM
ARCHS="-arch arm64 -arch x86_64 -mmacosx-version-min=12.0"
CXXF="$ARCHS -std=c++17 -Wall -Wextra -Werror -O2 -g"

echo "== the instance layer's header compiles as C"
printf '#include "bkp.h"\nint main(void) { return bkp_bypass(0); }\n' > "$TMP/hdr.c"
clang -std=c99 -Wall -Wextra -Werror -pedantic -I"$ROOT/core/include" -I"$HERE/shared" -fsyntax-only "$TMP/hdr.c"

echo "== build bkp_test (universal) + the core's tripwire"
clang $ARCHS -Wall -Wextra -Werror -O1 -g -dynamiclib "$ROOT/core/test/tripwire.c" -o "$TMP/libtripwire.dylib" \
  -install_name "@rpath/libtripwire.dylib"
clang++ $CXXF -I"$ROOT/core/include" "-DBKP_VERSION=\"$VERSION\"" \
  "$HERE/shared/bkp.cpp" "$HERE/test/bkp_test.cpp" "$ROOT/core/build.noindex/libbeatkey.a" \
  -L"$TMP" -ltripwire -Wl,-rpath,"$TMP" -framework Accelerate -framework CoreFoundation -o "$TMP/bkp_test"
a=$(lipo -archs "$TMP/bkp_test")
[ "$a" = "x86_64 arm64" ] || fail "bkp_test archs are '$a', want 'x86_64 arm64'"

for slice in arm64 x86_64; do
  echo "== run bkp_test: $slice slice"
  arch -$slice /usr/bin/true 2>/dev/null || fail "this Mac cannot run the $slice slice (the Intel slice needs Rosetta)"
  mkdir -p "$TMP/$slice/logs"
  BEATKEY_LOG_DIR="$TMP/$slice/logs" arch -$slice "$TMP/bkp_test" "$WEIGHTS" "$TMP/$slice" "$@" \
    || fail "bkp_test failed on the $slice slice"
done

if [ $# -eq 0 ]; then
  echo "== the VST3 shim, driven directly (no host, no bundle)"
  PI="$HERE/vendor/vst3-pluginterfaces-3.8.1"
  clang++ $CXXF -w -I"$PI" -c "$PI/pluginterfaces/base/coreiids.cpp" -o "$TMP/pi_coreiids.o"
  clang++ $CXXF -w -I"$PI" -c "$PI/pluginterfaces/base/funknown.cpp" -o "$TMP/pi_funknown.o"
  sh "$HERE/ui/build-face.sh" BeatKeyHarness "$TMP/face-harness" "$VERSION" || fail "the face did not build for the harness"
  clang++ -std=c++17 -fobjc-arc -x objective-c++ $ARCHS -Wall -Wextra -Werror -O2 -I"$ROOT/core/include" -isystem "$PI" \
    -c "$HERE/vst3/beatkey_vst3_view.mm" -o "$TMP/beatkey_vst3_view.o"
  clang++ $CXXF -I"$ROOT/core/include" -isystem "$PI" "-DBKP_VERSION=\"$VERSION\"" \
    "$HERE/vst3/beatkey_vst3.cpp" "$HERE/test/vst3_harness.cpp" "$HERE/shared/bkp.cpp" \
    "$TMP/pi_coreiids.o" "$TMP/pi_funknown.o" "$TMP/face-harness/face.o" "$TMP/face-harness/bkp_view.o" "$TMP/beatkey_vst3_view.o" \
    "$ROOT/core/build.noindex/libbeatkey.a" \
    -L"$TMP" -ltripwire -Wl,-rpath,"$TMP" -framework Accelerate -framework CoreFoundation -framework AppKit -framework Foundation \
    $(cat "$TMP/face-harness/face.ldflags") \
    -o "$TMP/vst3_harness"
  for slice in arm64 x86_64; do
    echo "== run vst3_harness: $slice slice"
    mkdir -p "$TMP/v3-$slice/logs"
    BEATKEY_LOG_DIR="$TMP/v3-$slice/logs" arch -$slice "$TMP/vst3_harness" "$WEIGHTS" || fail "vst3_harness failed on the $slice slice"
  done

  echo "== the VST3 shim as Beat Key MIDI (BKP_MIDI=1, plan step 15): event bus + notes, driven directly"
  clang++ $CXXF -I"$ROOT/core/include" -isystem "$PI" "-DBKP_VERSION=\"$VERSION\"" -DBKP_MIDI=1 \
    "$HERE/vst3/beatkey_vst3.cpp" "$HERE/test/vst3_harness.cpp" "$HERE/shared/bkp.cpp" \
    "$TMP/pi_coreiids.o" "$TMP/pi_funknown.o" "$TMP/face-harness/face.o" "$TMP/face-harness/bkp_view.o" "$TMP/beatkey_vst3_view.o" \
    "$ROOT/core/build.noindex/libbeatkey.a" \
    -L"$TMP" -ltripwire -Wl,-rpath,"$TMP" -framework Accelerate -framework CoreFoundation -framework AppKit -framework Foundation \
    $(cat "$TMP/face-harness/face.ldflags") \
    -o "$TMP/vst3_harness_midi"
  for slice in arm64 x86_64; do
    echo "== run vst3_harness (MIDI): $slice slice"
    mkdir -p "$TMP/v3m-$slice/logs"
    BEATKEY_LOG_DIR="$TMP/v3m-$slice/logs" arch -$slice "$TMP/vst3_harness_midi" "$WEIGHTS" || fail "vst3_harness (MIDI) failed on the $slice slice"
  done

  echo "== the face (plugin/test/face_test.swift): shared code, a real reading through the token, both sends, offscreen renders"
  SDK=$(xcrun --sdk macosx --show-sdk-path)
  sh "$HERE/ui/build-face.sh" BeatKeyFaceTest "$TMP/face-test" "$VERSION" >/dev/null || fail "the face did not build for face_test"
  rm -f "$TMP/face-test/face.o"   # face_test compiles the face's sources itself, with the test, as one module
  for a in arm64 x86_64; do
    xcrun swiftc -parse-as-library -module-name BeatKeyFaceTest -target "$a-apple-macos12.0" -sdk "$SDK" -swift-version 5 \
      -O -wmo -emit-object -o "$TMP/face-test/ft-$a.o" -import-objc-header "$HERE/ui/FaceBridge.h" \
      -I "$ROOT/core/include" -I "$HERE/shared" \
      "$ROOT"/app/Sources/BeatKeyShared/*.swift "$ROOT/app/Sources/Orion/House/Glow.swift" "$HERE"/ui/*.swift "$HERE/test/face_test.swift" \
      || fail "face_test.swift did not compile ($a)"
  done
  lipo -create "$TMP/face-test/ft-arm64.o" "$TMP/face-test/ft-x86_64.o" -output "$TMP/face-test/ft.o"
  clang++ $CXXF -I"$ROOT/core/include" "-DBKP_VERSION=\"$VERSION\"" -c "$HERE/shared/bkp.cpp" -o "$TMP/face-test/bkp.o"
  clang++ $ARCHS "$TMP/face-test/ft.o" "$TMP/face-test/bkp_view.o" "$TMP/face-test/bkp.o" "$ROOT/core/build.noindex/libbeatkey.a" \
    -framework Accelerate -framework CoreFoundation -framework AppKit -framework Foundation $(cat "$TMP/face-test/face.ldflags") \
    -o "$TMP/face_test" || fail "face_test did not link"
  # BKP_FACE_TEST_OUT=<file>: keep a copy of the binary (to run it on another Mac, e.g. Sofia's macOS 12)
  [ -n "$BKP_FACE_TEST_OUT" ] && cp "$TMP/face_test" "$BKP_FACE_TEST_OUT"
  SHOTS=${BKP_FACE_SHOTS:-$OUT/face-shots}
  for slice in arm64 x86_64; do
    echo "== run face_test: $slice slice (PNGs in $SHOTS/$slice)"
    mkdir -p "$TMP/ft-$slice/logs" "$SHOTS/$slice"
    BEATKEY_LOG_DIR="$TMP/ft-$slice/logs" arch -$slice "$TMP/face_test" "$WEIGHTS" "$SHOTS/$slice" || fail "face_test failed on the $slice slice"
  done
fi
echo "plugin/test.sh: PASS (both slices)"
