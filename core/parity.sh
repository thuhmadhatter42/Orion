#!/bin/sh
# core/parity.sh: the parity gate (plan A5).  The core must reproduce the Python analyzer's frozen
# outputs (core/test/golden) on every bench and smoke clip.
#
#   sh core/parity.sh <pcm folder> [arm64|x86_64|both] [key] [tempo] [stream]
#
#   <pcm folder>   <work>/pcm as written by tools/parity/make_goldens.py (audio never lives in the
#                  repo; make it again with `make_goldens.py --check --work <work>`).
#   slice          which slice of the universal test binary to run (default: this Mac's own).
#                  x86_64 on Apple silicon runs under Rosetta; on an Intel Mac it is native.
#   key tempo stream   gate only these parts (default: all three).
#
# Builds the core (core/build.sh) and the test binary into core/build.noindex/, writes the core's
# outputs and parity-report.json into core/build.noindex/parity-<slice>/.  Exit 0 only on PARITY OK.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
refuse() { echo "core/parity.sh: REFUSED: $*" >&2; exit 2; }

PCM=$1
[ -n "$PCM" ] && [ -d "$PCM" ] || refuse "give the PCM folder (<work>/pcm from tools/parity/make_goldens.py) as the first argument"
shift
SLICE=$(uname -m)
ONLY=""
for arg in "$@"; do
  case "$arg" in
    arm64|x86_64|both) SLICE=$arg ;;
    key|tempo|stream) ONLY="$ONLY --only $arg" ;;
    *) refuse "unknown argument '$arg'" ;;
  esac
done
WEIGHTS="$HERE/../models/deeptemp-k16-3.bkw"
[ -f "$WEIGHTS" ] || refuse "no weights at $WEIGHTS (core/tools/make_weights.py makes it from the .npz)"
command -v python3 >/dev/null 2>&1 || refuse "python3 not found (parity.py needs any Python 3, standard library only)"

sh "$HERE/build.sh"
OUT="$HERE/build.noindex"
LSR="$HERE/vendor/libsamplerate-0.2.2"
echo "== parity_dump (universal test binary)"
clang++ -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -std=c++17 -Wall -Wextra -Werror -O2 -g -ffp-contract=off \
  -I"$HERE/include" -I"$LSR/include" "$HERE/test/parity_dump.cpp" "$OUT/libbeatkey.a" \
  -framework Accelerate -o "$OUT/parity_dump"

run_slice() {
  echo "== parity, $1 slice"
  python3 "$HERE/test/parity.py" --dump "$OUT/parity_dump" --weights "$WEIGHTS" --pcm "$PCM" \
    --out "$OUT/parity-$1" --arch "$1" $ONLY
}
if [ "$SLICE" = both ]; then
  run_slice arm64
  run_slice x86_64
else
  run_slice "$SLICE"
fi
