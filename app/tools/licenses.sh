#!/bin/sh
# licenses.sh <out.txt>: writes Beat Key's Licenses page from its two sources, never a hand copy:
#   THIRD-PARTY-LICENSES.md  (every bundled component, its licence, the source offer)
#   LICENSE                  (Beat Key's own licence, GNU AGPL v3)
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
} > "$OUT"
[ -s "$OUT" ] || { echo "licenses.sh: wrote nothing to $OUT" >&2; exit 1; }
