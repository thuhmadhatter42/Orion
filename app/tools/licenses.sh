#!/bin/sh
# licenses.sh <out.txt>: writes Beat Key's Licenses page from its sources, never a hand copy:
#   THIRD-PARTY-LICENSES.md  (every bundled component, its licence, the source offer)
#   LICENSE                  (Beat Key's own licence, GNU AGPL v3)
#   the licence files of the code vendored into the native core and the plug-ins (plan step 17): every
#   plugin/vendor/*/LICENSE*, plugin/vendor/*/COPYING*, core/vendor/*/LICENSE*, core/vendor/*/COPYING*, in that
#   order, verbatim. A new vendored SDK (the AAX SDK, GPLv3) shows up here by being vendored: no edit to this file.
# app/build.sh runs it into Contents/Resources/Licenses.txt; HelpPagesTests runs it too.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:?usage: licenses.sh <out.txt>}
for f in THIRD-PARTY-LICENSES.md LICENSE; do
  [ -s "$ROOT/$f" ] || { echo "licenses.sh: missing or empty $ROOT/$f" >&2; exit 1; }
done
{
  echo "BEAT KEY: LICENSES"
  echo "=================="
  echo
  echo "Part 1: Beat Key's own licence (GNU Affero General Public License v3.0; the repository file LICENSE)."
  echo "Part 2: the licences of everything Beat Key ships (THIRD-PARTY-LICENSES.md), with the source offer."
  echo "Part 3: the licence texts of the code built into the Beat Key plug-ins (Audio Unit, VST3, AAX), as their authors wrote them."
  echo
  echo
  echo "PART 1: BEAT KEY, GNU AFFERO GENERAL PUBLIC LICENSE v3.0"
  echo "---------------------------------------------------------"
  echo
  cat "$ROOT/LICENSE"
  echo
  echo
  echo "PART 2: THIRD-PARTY LICENSES"
  echo "----------------------------"
  echo
  cat "$ROOT/THIRD-PARTY-LICENSES.md"
  echo
  echo
  echo "PART 3: LICENCE TEXTS OF THE CODE BUILT INTO THE PLUG-INS"
  echo "---------------------------------------------------------"
  echo
  echo "The Beat Key plug-ins (Audio Unit, VST3, AAX) are Beat Key and carry its licence (Part 1). Each piece of other"
  echo "people's code compiled into them is listed in Part 2 with its licence. Their licence texts follow, verbatim, from"
  echo "the copies in the source (plugin/vendor, core/vendor). Source: https://github.com/thuhmadhatter42/Orion"
  n=0
  for f in "$ROOT"/plugin/vendor/*/LICENSE* "$ROOT"/plugin/vendor/*/COPYING* "$ROOT"/core/vendor/*/LICENSE* "$ROOT"/core/vendor/*/COPYING*; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    echo
    echo "$(basename "$(dirname "$f")")  (${f#"$ROOT"/})"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo
    cat "$f"
  done
  [ "$n" -gt 0 ] || { echo "licenses.sh: no vendored licence files found under plugin/vendor or core/vendor" >&2; exit 1; }
} > "$OUT"
[ -s "$OUT" ] || { echo "licenses.sh: wrote nothing to $OUT" >&2; exit 1; }
