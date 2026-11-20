#!/bin/bash
# J runs this once: lets Claude's multi-Mac test scripts (mm-*.sh) drive Studio D for the Beat Key Pro Tools test.
# Adds two allow rules to ~/.claude/settings.json (backup kept next to it). Nothing else changes.
set -euo pipefail
p=~/.claude/settings.json
cp "$p" "$p.bak-$(date +%Y%m%d-%H%M%S)"
python3 - "$p" <<'X'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
a=d.setdefault('permissions',{}).setdefault('allow',[])
for r in ["Bash(~/.claude/skills/multi-mac-testing/scripts/mm-*:*)","Bash(/Users/jshriver/.claude/skills/multi-mac-testing/scripts/mm-*:*)"]:
    if r not in a: a.append(r)
json.dump(d,open(p,'w'),indent=2)
print("added:", [r for r in a if 'multi-mac-testing' in r])
X
