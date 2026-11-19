#!/bin/sh
# core/build.sh: builds the Beat Key analysis core into core/build.noindex/ (plan step 3, A6).
#   sh core/build.sh            (any cwd; reads ../VERSION, never changes it)
#
#   build.noindex/obj/*.o        universal objects (arm64 + x86_64, macOS 12.0 minimum)
#   build.noindex/libbeatkey.a   the same objects as one static library: what the plug-in links
#
# Ours: C++17, -Wall -Wextra -Werror, hidden visibility, -ffp-contract=off (no fused multiply-adds:
# the same arithmetic on both slices and the same as numpy's, which the parity gate compares with).
# The x86_64 slice is plain x86_64 (no AVX flags): it must run on a 2013 Xeon; the heavy maths is
# in Accelerate, which picks its own code path.
# Vendored libsamplerate is compiled as shipped (-O2, its warnings are its own).
# Never signs, never installs, never writes outside core/build.noindex/.
# Every refusal prints its reason and exits non-zero.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

refuse() { echo "core/build.sh: REFUSED: $*" >&2; exit 1; }

[ -f ../VERSION ] || refuse "../VERSION not found (looked in $(cd .. && pwd))"
VERSION=$(tr -d ' \n' < ../VERSION)
case "$VERSION" in [0-9]*.[0-9]*.[0-9]*) ;; *) refuse "VERSION '$VERSION' is not major.minor.patch" ;; esac

OUT="$HERE/build.noindex"
OBJ="$OUT/obj"
ARCHS_FLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=12.0"
CXXF="$ARCHS_FLAGS -std=c++17 -Wall -Wextra -Werror -O2 -g -fvisibility=hidden -ffp-contract=off"
LSR="$HERE/vendor/libsamplerate-0.2.2"
[ -f "$LSR/src/src_sinc.c" ] || refuse "vendored libsamplerate not found at $LSR"
mkdir -p "$OBJ"

check_universal() {   # $1 = Mach-O file
  a=$(lipo -archs "$1" 2>&1) || { echo "$a" >&2; refuse "lipo failed on $1"; }
  [ "$a" = "x86_64 arm64" ] || refuse "$1 archs are '$a', want 'x86_64 arm64'"
}

echo "== core objects (version $VERSION)"
for f in log fft resample hpcp key mel tempocnn refine boundary live file worker api; do
  [ -f "src/$f.cpp" ] || refuse "src/$f.cpp is missing"
  clang++ $CXXF -I"$HERE/include" -I"$LSR/include" "-DBK_VERSION=\"$VERSION\"" -c "src/$f.cpp" -o "$OBJ/$f.o"
  check_universal "$OBJ/$f.o"
done

echo "== vendored libsamplerate 0.2.2 (medium sinc converter only)"
for f in samplerate src_sinc src_linear src_zoh; do
  clang $ARCHS_FLAGS -O2 -g -fvisibility=hidden -w -DHAVE_CONFIG_H -I"$LSR/beatkey-config" -I"$LSR/include" -I"$LSR/src" \
    -c "$LSR/src/$f.c" -o "$OBJ/lsr_$f.o"
  check_universal "$OBJ/lsr_$f.o"
done

rm -f "$OUT/libbeatkey.a"
libtool -static -o "$OUT/libbeatkey.a" "$OBJ"/*.o 2>&1 | grep -v 'has no symbols' || true
[ -f "$OUT/libbeatkey.a" ] || refuse "libtool left no $OUT/libbeatkey.a"
check_universal "$OUT/libbeatkey.a"
echo "lipo -archs: $(lipo -archs "$OUT/libbeatkey.a")  ($OUT/libbeatkey.a)"
echo "core/build.sh: done, version $VERSION"
