#!/bin/sh
# core/test.sh: the core's gate (plan steps 3 and 6).  Needs no audio files and no Python.
#   sh core/test.sh [ring|log|bringup|file|live ...]      (default: every test)
#
#  1. core/build.sh: universal objects (arm64 + x86_64, macOS 12.0 minimum, -Wall -Wextra -Werror).
#  2. The public header compiles as plain C and as C++.
#  3. The weights file is what the .npz gives now (when a Python with numpy is at hand; said aloud
#     when it is not).
#  4. core_test, linked against the tripwire dylib, on BOTH slices: arm64, then x86_64
#     (`arch -x86_64`: Rosetta on Apple silicon, native on an Intel Mac).  A slice this Mac cannot
#     run is a FAIL, never a skip.
# The parity gate is separate (core/parity.sh: it needs the bench audio's PCM).
# Scratch: core/build.noindex/test.XXXXXX, removed on every way out.  Logs go there, never to
# ~/Library/Logs.  Nothing is installed, signed or launched.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
fail() { echo "core/test.sh: FAIL: $*" >&2; exit 1; }

sh "$HERE/build.sh"
OUT="$HERE/build.noindex"
LSR="$HERE/vendor/libsamplerate-0.2.2"
WEIGHTS="$HERE/../models/deeptemp-k16-3.bkw"
[ -f "$WEIGHTS" ] || fail "no weights at $WEIGHTS (core/tools/make_weights.py makes it from the .npz)"
TMP=$(mktemp -d "$OUT/test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM
ARCHS="-arch arm64 -arch x86_64 -mmacosx-version-min=12.0"

echo "== the public header compiles as C and as C++"
printf '#include "beatkey.h"\nint main(void) { return bk_ready(); }\n' > "$TMP/hdr.c"
clang -std=c99 -Wall -Wextra -Werror -pedantic -I"$HERE/include" -fsyntax-only "$TMP/hdr.c"
clang++ -x c++ -std=c++17 -Wall -Wextra -Werror -I"$HERE/include" -fsyntax-only "$TMP/hdr.c"

echo "== the weights file matches the .npz"
PYNP=""
for py in "$HERE/../bin/python/bin/python3" python3; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c 'import numpy' >/dev/null 2>&1; then PYNP=$py; break; fi
done
if [ -n "$PYNP" ]; then
  "$PYNP" "$HERE/tools/make_weights.py" --check "$HERE/../models/deeptemp-k16-3.npz" "$WEIGHTS" || fail "the .bkw is stale"
else
  echo "NOT CHECKED: no Python with numpy here (the bundled one is bin/python after deps.sh). The .bkw was not compared with the .npz."
fi

echo "== build core_test (universal) + tripwire"
clang $ARCHS -Wall -Wextra -Werror -O1 -g -dynamiclib "$HERE/test/tripwire.c" -o "$TMP/libtripwire.dylib" \
  -install_name "@rpath/libtripwire.dylib"
clang++ $ARCHS -std=c++17 -Wall -Wextra -Werror -O2 -g -ffp-contract=off -I"$HERE/include" -I"$LSR/include" \
  "$HERE/test/core_test.cpp" "$OUT/libbeatkey.a" -L"$TMP" -ltripwire -Wl,-rpath,"$TMP" \
  -framework Accelerate -o "$TMP/core_test"
a=$(lipo -archs "$TMP/core_test")
[ "$a" = "x86_64 arm64" ] || fail "core_test archs are '$a', want 'x86_64 arm64'"

for slice in arm64 x86_64; do
  echo "== run: $slice slice"
  mkdir -p "$TMP/$slice"
  if ! arch -$slice /usr/bin/true 2>/dev/null; then
    fail "this Mac cannot run the $slice slice (on Apple silicon the Intel slice needs Rosetta)"
  fi
  arch -$slice "$TMP/core_test" "$WEIGHTS" "$TMP/$slice" "$@" || fail "core_test failed on the $slice slice"
done
echo "core/test.sh: PASS (both slices)"
