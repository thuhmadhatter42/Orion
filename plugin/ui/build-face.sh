#!/bin/sh
# plugin/ui/build-face.sh: compiles the face (plan step 9) for ONE format, universal.
#   sh plugin/ui/build-face.sh <SwiftModuleName> <out dir> <version>
#     -> <out dir>/face.o       the SwiftUI face + the app's shared Swift, module <SwiftModuleName>
#     -> <out dir>/bkp_view.o   the face's C doorway (token table, read / actions)
#     -> <out dir>/face.ldflags the linker flags the Swift runtime needs (paths only; the objects name
#                               their own libraries)
# Each format gets its own module name (BeatKeyAU, BeatKeyVST3, ...), so two formats in one host never
# share a Swift or Objective-C class name (plan A6). Swift 5 mode, macOS 12.0, arm64 + x86_64.
# The Swift it compiles, one copy each (never a second key table: BeatKeyShared/KeyNames.swift is it):
#   app/Sources/BeatKeyShared/*.swift        key names, tempo text, tuning, Auto-Tune hand-off, SEND BPM contract, look,
#                                            chords (the MIDI variant's notes), the MIDI file writer (its drag-out .mid)
#   app/Sources/Orion/House/Glow.swift       the house glow module, as the app has it
#   app/Sources/Orion/Face/*.swift           THE face: the app window's own view tree (overnight plan 2026-11-20 §2),
#                                            fed plain values; Face/FaceHost.swift lists what this side provides
#   plugin/ui/*.swift                        the plug-in's side: the instance's reading, the sends, DOWNLOAD
set -e
[ $# -eq 3 ] || { echo "usage: build-face.sh <SwiftModuleName> <out dir> <version>" >&2; exit 2; }
MOD=$1; OUT=$2; VERSION=$3
HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$PLUGIN/.." && pwd)
refuse() { echo "plugin/ui/build-face.sh: REFUSED: $*" >&2; exit 1; }
mkdir -p "$OUT"

SDK=$(xcrun --sdk macosx --show-sdk-path) || refuse "no macOS SDK"
SWIFTC=$(xcrun --find swiftc) || refuse "no swiftc"
TOOLCHAIN_LIB=$(cd "$(dirname "$SWIFTC")/../lib/swift/macosx" && pwd) || refuse "no Swift toolchain lib folder"

SRCS="$ROOT/app/Sources/BeatKeyShared/*.swift $ROOT/app/Sources/Orion/House/Glow.swift $ROOT/app/Sources/Orion/Face/*.swift $HERE/*.swift"
for a in arm64 x86_64; do
  # shellcheck disable=SC2086
  "$SWIFTC" -parse-as-library -module-name "$MOD" -target "$a-apple-macos12.0" -sdk "$SDK" -swift-version 5 \
    -O -wmo -g -emit-object -o "$OUT/face-$a.o" \
    -import-objc-header "$HERE/FaceBridge.h" -I "$ROOT/core/include" -I "$PLUGIN/shared" \
    $SRCS || refuse "swiftc failed for $MOD ($a)"
done
lipo -create "$OUT/face-arm64.o" "$OUT/face-x86_64.o" -output "$OUT/face.o" || refuse "lipo failed"
rm -f "$OUT/face-arm64.o" "$OUT/face-x86_64.o"

clang -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -std=c11 -Wall -Wextra -Werror -O2 -g -fvisibility=hidden \
  -I"$ROOT/core/include" -I"$PLUGIN/shared" "-DBKP_VERSION=\"$VERSION\"" \
  -c "$PLUGIN/shared/bkp_view.c" -o "$OUT/bkp_view.o" || refuse "bkp_view.c failed"

# the OS's Swift runtime (/usr/lib/swift, in macOS 12) + the toolchain's static back-deploy shims
printf '%s\n' "-L$SDK/usr/lib/swift -L$TOOLCHAIN_LIB -framework SwiftUI -framework AppKit -framework Combine" > "$OUT/face.ldflags"
echo "face: $MOD -> $OUT/face.o + bkp_view.o"
