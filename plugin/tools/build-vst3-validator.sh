#!/bin/sh
# plugin/tools/build-vst3-validator.sh: builds Steinberg's VST3 validator (MIT, from the full VST3 SDK) for the
# plug-in's validator gate (plan step 8.3).  Universal, so the x86_64 slice of our VST3 is validated under
# `arch -x86_64` and the arm64 slice natively.
#   sh plugin/tools/build-vst3-validator.sh      -> plugin/build.noindex/vst3sdk-build/bin/Release/validator
# The SDK is cloned at the tag that matches the vendored pluginterfaces (3.8.1 build 84), with submodules,
# into plugin/build.noindex/vst3sdk (gitignored).  Needs git and cmake.  Reuses both folders when present.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
refuse() { echo "build-vst3-validator.sh: REFUSED: $*" >&2; exit 1; }
TAG=v3.8.1_build_84
COMMIT=3cdf9ca5d1f5b1b21e0a86832aa4abe55607bd96
SRC="$HERE/build.noindex/vst3sdk"
BLD="$HERE/build.noindex/vst3sdk-build"
command -v cmake >/dev/null || refuse "cmake not found (brew install cmake)"
command -v git >/dev/null || refuse "git not found"
mkdir -p "$HERE/build.noindex"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$TAG" --recurse-submodules --shallow-submodules \
    https://github.com/steinbergmedia/vst3sdk.git "$SRC" >&2 || refuse "could not clone the VST3 SDK at $TAG"
fi
HEAD=$(git -C "$SRC" rev-parse HEAD)
[ "$HEAD" = "$COMMIT" ] || refuse "$SRC is at $HEAD, want $COMMIT ($TAG)"
cmake -S "$SRC" -B "$BLD" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release "-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DSMTG_ENABLE_VSTGUI_SUPPORT=OFF -DSMTG_ENABLE_VST3_PLUGIN_EXAMPLES=OFF \
  -DSMTG_ENABLE_VST3_HOSTING_EXAMPLES=ON -DSMTG_RUN_VST_VALIDATOR=OFF >/dev/null || refuse "cmake configure failed"
cmake --build "$BLD" --target validator -j 8 >/dev/null || refuse "the validator did not build"
V="$BLD/bin/Release/validator"
[ "$(lipo -archs "$V")" = "x86_64 arm64" ] || refuse "$V is not universal"
echo "$V"
