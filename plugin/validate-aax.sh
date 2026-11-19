#!/bin/sh
# plugin/validate-aax.sh: the AAX gate (plan step 13): Avid's AAX Validator (DigiShell + the aaxval dish) on
# Beat Key's own AAX bundle ONLY, pointed at plugin/build.noindex/Beat Key.aaxplugin by path.  Never installs,
# never scans a plug-in folder, never opens Pro Tools.
#   sh plugin/validate-aax.sh
#   sh plugin/validate-aax.sh --midi     the same on Beat Key MIDI.aaxplugin (plan step 15); log aaxval-midi.txt
#
# The validator is Avid's (developer-only licence), so it is never in this repo: $AAX_VALIDATOR_TGZ names the
# archive from the AAX developer tools (default: J's SDK folder).  It is unpacked into
# plugin/build.noindex/aaxval once.  arm64 only (Avid ships no x86_64 build of 2024.6), so it checks the arm64
# slice; the x86_64 slice is checked by Pro Tools on Sofia.
#
# One fix is applied to the unpacked copy: its system-info Ruby (DTT SysInfo.rb) crashes on a mounted volume
# that reports no "Container Free Space" (macOS 27; seen 2026-11-19), and every test that starts a separate host
# process (test.data_model, info.productids, info.support.general) then reports E_ABORTED without loading the
# plug-in.  The fix only makes that parsing tolerate the missing field.
#
# Judged (exit 0 only if all hold): every test that ran is E_COMPLETED_PASS, except
#   test.cycle_counts            AAX DSP (TI) only; Beat Key is Native only: aborts by design
#   test.page_table.load         the validator cannot load its page-table library here ("Failed to load page
#                                tables library", before the plug-in is touched); Beat Key ships no page table
# and the core tests must be among the passes: test.describe_validation, test.data_model, test.load_unload,
# test.parameters.  Log: plugin/build.noindex/validate/aaxval.txt.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/build.noindex"
fail() { echo "plugin/validate-aax.sh: FAIL: $*" >&2; exit 1; }
AX="$OUT/Beat Key.aaxplugin"; LOGNAME_=aaxval.txt
if [ "${1:-}" = "--midi" ]; then AX="$OUT/Beat Key MIDI.aaxplugin"; LOGNAME_=aaxval-midi.txt; fi
[ -d "$AX" ] || fail "no AAX at $AX (run plugin/build.sh)"
TGZ=${AAX_VALIDATOR_TGZ:-$HOME/dev/ProTools SDK/AAX/aax-validator-dsh-2024-6-0-138bab0d-mac-arm64.tar.gz}
NAME=$(basename "$TGZ" .tar.gz)
V="$OUT/aaxval/$NAME"
if [ ! -x "$V/CommandLineTools/dsh" ]; then
  [ -f "$TGZ" ] || fail "AAX Validator archive not found at $TGZ (set AAX_VALIDATOR_TGZ)"
  mkdir -p "$OUT/aaxval"
  tar xzf "$TGZ" -C "$OUT/aaxval" || fail "could not unpack $TGZ"
  xattr -dr com.apple.quarantine "$V" 2>/dev/null || true
fi
SI="$V/Frameworks/AAXValidatorResources/Tools/DTT/sources/classes/SysInfo.rb"
[ -f "$SI" ] || fail "validator layout changed: no $SI"
sed -i '' -e "s/disk\['Container Free Space'\] = disk\['Container Free Space'\]\[/disk['Container Free Space'] = disk['Container Free Space'].to_s[/" \
  -e "s/disk\['Total Size'\] = disk\['Total Size'\]\[/disk['Total Size'] = disk['Total Size'].to_s[/" \
  -e "s/disk\['Mount Point'\] += /disk['Mount Point'] = disk['Mount Point'].to_s + /" "$SI"

mkdir -p "$OUT/validate"
LOG="$OUT/validate/$LOGNAME_"
echo "== AAX Validator ($NAME) on $AX"
(cd "$V/CommandLineTools" && printf 'load_dish aaxval\nruntests "%s"\nexit\n' "$AX" | ./dsh) 2>&1 \
  | tr -d '\000' | LC_ALL=C tr -c '[:print:]\n\t' '?' > "$LOG" || fail "dsh did not run (log $LOG)"
python3 -I - "$LOG" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
rows = re.findall(r'\n\s*id: ((?:test|info)\.[\w.]+)\n(?:(?!\n\s*- bundle_path:).)*?result_status: (E_\w+)', text, re.S)
if not rows:
    sys.exit("no test results in the log")
excused = {"test.cycle_counts", "test.page_table.load"}
must = {"test.describe_validation", "test.data_model", "test.load_unload", "test.parameters"}
bad, passed = [], set()
for tid, st in rows:
    mark = "PASS" if st == "E_COMPLETED_PASS" else ("excused" if tid in excused else "FAIL")
    print(f"{tid:40s} {st:20s} {mark}")
    if st == "E_COMPLETED_PASS":
        passed.add(tid)
    elif tid not in excused:
        bad.append(tid)
missing = sorted(must - passed)
if bad or missing:
    sys.exit(f"failed: {bad}  required but not passed: {missing}")
print(f"AAX VALIDATOR OK: {len(passed)} passed, {len(rows) - len(passed)} excused")
PY
