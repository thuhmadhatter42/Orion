#!/bin/sh
# core/soak.sh: plan step 6's soak.  Four analyzers fed real music in real time for N minutes.
#
#   sh core/soak.sh <pcm folder> [minutes, default 10] [arm64|x86_64]
#
#   <pcm folder>   <work>/pcm from tools/parity/make_goldens.py; the four largest 44.1 kHz files
#                  there (whole bench tracks) are the music.
# Passes when no analyzer missed a hop (no dropped audio, as many readings as the
# same audio gives when fed directly) and the heap in use did not grow.  See test/soak.cpp.
# It takes as long as it says: this is wall-clock real time.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
refuse() { echo "core/soak.sh: REFUSED: $*" >&2; exit 2; }
PCM=$1
[ -n "$PCM" ] && [ -d "$PCM" ] || refuse "give the PCM folder (<work>/pcm from tools/parity/make_goldens.py) as the first argument"
MIN=${2:-10}
SLICE=${3:-$(uname -m)}
WEIGHTS="$HERE/../models/deeptemp-k16-3.bkw"
[ -f "$WEIGHTS" ] || refuse "no weights at $WEIGHTS"
# whole bench tracks are 120 s of 44.1 kHz mono float32 = 21168000 bytes
FILES=$(find "$PCM" -name '*.f32' -size +20000k -size -22000k | sort | head -4)
[ "$(echo "$FILES" | grep -c .)" = 4 ] || refuse "fewer than four whole bench tracks in $PCM"

sh "$HERE/build.sh"
OUT="$HERE/build.noindex"
LSR="$HERE/vendor/libsamplerate-0.2.2"
clang++ -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -std=c++17 -Wall -Wextra -Werror -O2 -g -ffp-contract=off \
  -I"$HERE/include" -I"$LSR/include" "$HERE/test/soak.cpp" "$OUT/libbeatkey.a" -framework Accelerate -o "$OUT/soak"
mkdir -p "$OUT/soak-$SLICE"
echo "== soak, $SLICE slice, $MIN minutes, four analyzers (44.1 / 48 / 96 / 48 kHz)"
# shellcheck disable=SC2086
arch -"$SLICE" "$OUT/soak" "$WEIGHTS" "$MIN" "$OUT/soak-$SLICE" $FILES
