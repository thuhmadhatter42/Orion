#!/bin/bash
# Builds and signs the bundled tool runtime: app/build/runtime/{arm64,x86_64}/
#   bin/     ffmpeg ffprobe yt-dlp deno   (arm64 also gets bin-legacy/ = ffmpeg 7.1.1 for macOS 11)
#            deno = the JavaScript runtime yt-dlp needs for YouTube's JS challenges (EJS). Official
#            denoland release zips, vendor/macos-<arch>/deno.zip, sha256-pinned below. Both are
#            built for macOS 12.0 (LC_BUILD_VERSION minos), so bin-legacy/ (macOS 11) gets none.
# No Python: the analyzer is the core and the download is Swift inside the app (plug-in plan step 19).
# vendor/*/python.tar.gz and vendor/*/wheels stay in git for deps.sh (the command-line tool and the
# Python reference the goldens were frozen from); nothing here reads them.
# Usage: app/runtime.sh build | sign | all
set -euo pipefail
APP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$APP/.." && pwd)"
OUT="$APP/build/runtime"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: J Shriver (9WTFGV63S2)}"
ENTS="$APP/entitlements.plist"
ENTS_YTDLP="$APP/entitlements-ytdlp.plist"   # yt-dlp only: see that file
ENTS_DENO="$APP/entitlements-deno.plist"     # deno only: see that file
# Deno 2.9.8, https://github.com/denoland/deno/releases/tag/v2.9.8 (sha256 = the release's own digests)
DENO_VERSION=2.9.8
DENO_SHA256_arm64=9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e    # deno-aarch64-apple-darwin.zip
DENO_SHA256_x86_64=4b2f5edd2639b7470f034238b321d7002d8dfb4726d8558f52c17afac370eb2c   # deno-x86_64-apple-darwin.zip
ARCHES="arm64 x86_64"

build_arch() {
  local a="$1" v="$ROOT/vendor/macos-$1" d="$OUT/$1"
  echo "== build $a"
  rm -rf "$d"; mkdir -p "$d/bin"
  unzip -oq "$v/ffmpeg.zip" -d "$d/bin"; unzip -oq "$v/ffprobe.zip" -d "$d/bin"
  cp -f "$ROOT/vendor/yt-dlp" "$d/bin/yt-dlp"
  local want="DENO_SHA256_$a" got
  want="${!want}"
  got="$(shasum -a 256 "$v/deno.zip" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || { echo "deno $DENO_VERSION ($a): sha256 mismatch for $v/deno.zip"; exit 1; }
  unzip -oq "$v/deno.zip" deno -d "$d/bin"
  if [ "$a" = arm64 ]; then
    mkdir -p "$d/bin-legacy"
    unzip -oq "$ROOT/vendor/macos-arm64-legacy/ffmpeg.zip" -d "$d/bin-legacy"
    unzip -oq "$ROOT/vendor/macos-arm64-legacy/ffprobe.zip" -d "$d/bin-legacy"
  fi
  chmod +x "$d"/bin/* 2>/dev/null || true
  [ -d "$d/bin-legacy" ] && chmod +x "$d"/bin-legacy/*
  return 0
}

do_build() {
  mkdir -p "$OUT"
  local a
  rm -rf "$OUT/scripts"                      # an older runtime's Python scripts
  for a in $ARCHES; do build_arch "$a"; done
  echo "built: $OUT"
}

do_sign() {
  echo "== sign with: $IDENTITY"
  local list; list="$(mktemp)"
  find "$OUT" -type f -exec file {} + | grep -F 'Mach-O' | sed -e 's/ (for architecture [^)]*)//' -e 's/:[[:space:]].*//' | sort -u > "$list"
  # deepest first
  awk -F/ '{print NF "\t" $0}' "$list" | sort -rn | cut -f2- | while IFS= read -r f; do
    if [ "${SKIP_YTDLP:-0}" = 1 ] && [ "$(basename "$f")" = yt-dlp ]; then echo "  skip $f"; continue; fi
    chmod u+w "$f"
    ents="$ENTS"
    case "$(basename "$f")" in
      yt-dlp) ents="$ENTS_YTDLP" ;;
      deno) ents="$ENTS_DENO" ;;
    esac
    codesign --force --options runtime --timestamp --entitlements "$ents" --sign "$IDENTITY" "$f"
  done
  local bad=0 f
  while IFS= read -r f; do
    codesign --verify --strict "$f" 2>&1 || { echo "VERIFY FAIL $f"; bad=1; }
  done < "$list"
  echo "verified $(wc -l < "$list" | tr -d ' ') Mach-O files"
  rm -f "$list"
  return $bad
}

case "${1:-}" in
  build) do_build ;;
  sign) do_sign ;;
  all) do_build; do_sign ;;
  *) echo "usage: $0 build|sign|all"; exit 2 ;;
esac
