# Folder move checklist: ~/dev/beat_dl -> ~/dev/beatkey (MBP + Sofia), vault 10-dev/beat_dl -> 10-dev/beatkey

Recon only, nothing changed. Recon run 2026-11-19 ~02:20 Pacific. Studio D/E/F not touched or listed.
Owner key: THIS = beat_dl/beatkey project (repo + vault folder). Others need a handoff (named).

## A. Facts that shape the order (all verified this turn)

1. Three LOCKED worktrees under `~/dev/beat_dl/.claude/worktrees/`: `agent-aadaf41124b37be8f` (plug-in core, branch e751a34, live: PID 98631 `tools/parity/make_goldens.py`, PID 20279 `core/build`, PID 18151 `sh core/soak.sh`, all cwd in that worktree), `agent-ad348521c4ae4ac9c` (this recon agent, 8ced747), `agent-af30763709fafa381` (accc84e). Their `.git` files and main's `.git/worktrees/*/gitdir` hold ABSOLUTE old paths, so a plain mv breaks all three until `git worktree repair`.
2. Live Claude session in `~/dev/beat_dl`: PID 13337 (the main beat_dl session). Other sessions (thekitchen, jlipper, jotes) do not touch it. A live session whose cwd is renamed keeps writing transcripts under the OLD `~/.claude/projects/-Users-jshriver-dev-beat-dl/` and recreates it. End it before the mv.
3. Vault name collision: `10-dev/beatkey` (old friends-page notes, 6 files + `.remember`) already exists; its memory dir `~/.claude/projects/-Users-jshriver-goat-arc-obsidian-vault-goat-mind-10-dev-beatkey` (1.7 MB) also exists. Both must be trashed before the renames.
4. Vault is a Syncthing folder (`.stfolder`) shared with Sofia; Sofia has its own copies of `10-dev/beat_dl` and `10-dev/beatkey`. Vault rename on MBP propagates by itself (Syncthing). No second vault rename on Sofia.
5. Sofia: `~/dev/beat_dl` exists (739 MB, main at 4226a8e from 2026-10-06, origin already `https://github.com/thuhmadhatter42/Orion.git`, 1 untracked `MOVED-2026-11-14.md`, no worktrees). `~/dev/beatkey`, `~/beatkey`, `~/beat_dl` do NOT exist, so no collision (an old `beatkey` sits in Sofia's `~/.Trash`, irrelevant). No beat_dl process, no cron entry, no launchd plist (checked `~/Library/LaunchAgents` + `/Library/LaunchDaemons`), no Sofia `~/.claude/projects` memory dir for it.
6. MBP launchd: no plist in `~/Library/LaunchAgents` names beat_dl. crontab: nothing. `~/.zshrc` aliases (J-ALIASES block, lines 77-100): no beat/beat_dl alias. `~/.claude/scripts`, `~/.claude/hooks`, `~/.claude/commands`, `~/.claude/skills` (live SKILL.md files): no path ref (only name mentions, see C.9). `~/.claude-newaccount` projects dir: NO beat dir at all, nothing to rename for account #2.
7. `app/build.sh` and `tools/publish.sh`, `run.sh`, `run.command`: NO old-path text. They use `dirname "$0"/..`/`BASH_SOURCE`, and publish.sh REPO is already `thuhmadhatter42/Orion` (line 20); its Sofia targets are `~/dev/fourletterrecords/...` (lines 21, 22, 70, 71, 72), not beat_dl. So the move does not break build or publish.
8. Installed `/Applications/Beat Key.app`: only compile-time debug paths (`app/.build/out/...`, `app/Sources/Orion/...`) in the binary; runtime reads no repo path. Nothing to fix there.
9. Same volume (`/dev/disk3s1`, 17 GB free): `mv` is a rename, instant, no copy, 10 GB tree.

## B. Move order (MBP, then memory, then vault, then Sofia)

Each step: do, then run the verify line. Stop on any fail.

### Step 0. Gate: nothing running in the tree
- Do: wait for the plug-in core agent (worktree aadaf...) to finish and report; let make_goldens/soak finish or have the main session stop them. Main session conducts, so confirm no other agent is mid-run.
- Verify (expect empty): `pgrep -fl 'dev/beat_dl'` and `lsof +D /Users/jshriver/dev/beat_dl 2>/dev/null | awk 'NR>1{print $1,$2}' | sort -u`

### Step 1. Trash the old retired vault folder first (J's pick) and its memory dir
- Do (MBP): `/usr/bin/trash ~/goat-arc/obsidian-vault/goat-mind/10-dev/beatkey ~/.claude/projects/-Users-jshriver-goat-arc-obsidian-vault-goat-mind-10-dev-beatkey`
  (PICKUP note: this trash was permission-denied earlier; J may have to run it with `!`.) Optional: copy `move-log.md` + PICKUP.md of that folder somewhere J wants first; they are the only unique content.
- Wait until Sofia's copy disappears (Syncthing): `~/.claude/scripts/ssh-rc js-mac-pro 'ls -d ~/goat-arc/obsidian-vault/goat-mind/10-dev/beatkey 2>&1'` (expect "No such file").
- Verify: `ls -d ~/goat-arc/obsidian-vault/goat-mind/10-dev/beatkey ~/.claude/projects/*10-dev-beatkey 2>&1` -> both "No such file".

### Step 2. Finish or remove the three worktrees, then prune
- Do (from `~/dev/beat_dl`, main session, not an isolated agent): confirm each branch is merged or deliberately dropped (`git branch --no-merged main`). Then for each: `git worktree unlock <path>; git worktree remove <path>` (use `--force` only if untracked build output `core/build.noindex`, `app/.build` is all that is left). Delete merged branches `worktree-agent-*`. Then `git worktree prune`.
- This agent's own worktree (`agent-ad348521c4ae4ac9c`) is removed by the main session after this report.
- Fallback if a worktree must survive the move: skip remove, and after Step 3 run `git -C ~/dev/beatkey worktree repair ~/dev/beatkey/.claude/worktrees/*` (repairs both gitdir pointers).
- Verify: `git -C ~/dev/beat_dl worktree list` shows only `main`; `ls ~/dev/beat_dl/.claude/worktrees` empty; `git -C ~/dev/beat_dl status -sb` clean and `git stash list` empty.

### Step 3. End the session in the folder, then mv on the MBP
- Do: end the Claude session PID 13337 (cwd ~/dev/beat_dl). Save state first (PICKUP.md CURRENT STATE rewrite names the NEW path). Then `mv ~/dev/beat_dl ~/dev/beatkey`.
- Verify: `ls -d ~/dev/beat_dl 2>&1` (No such file); `git -C ~/dev/beatkey status -sb` (## main...origin/main, clean); `git -C ~/dev/beatkey remote -v` shows Orion; `git -C ~/dev/beatkey worktree list` shows only `/Users/jshriver/dev/beatkey`.

### Step 4. Rebuild caches that hold absolute paths (MBP, new location)
- Do: `/usr/bin/trash ~/dev/beatkey/app/.build` (SwiftPM `workspace-state.json` + PCH/module cache hold `/Users/jshriver/dev/beat_dl/...`; a moved `.build` can fail with "module cache path differs"). Rebuilds on the next `swift build`/`app/build.sh` (re-fetches Sparkle artifact: network). `core/build.noindex` (if it came with a merge) likewise. `__pycache__` is harmless.
- Fix `bin/python/bin/f2py` line 1 shebang `#!/Users/jshriver/dev/beat_dl/bin/python/bin/python3` -> `#!/Users/jshriver/dev/beatkey/bin/python/bin/python3` (gitignored, only f2py has it; unused by the app). Optional but harmless: `sed -i '' '1s#dev/beat_dl#dev/beatkey#' ~/dev/beatkey/bin/python/bin/f2py`.
- Verify: `grep -rIl '/dev/beat_dl' ~/dev/beatkey/bin ~/dev/beatkey/app/.build 2>/dev/null` (expect empty); `~/dev/beatkey/bin/python/bin/python3 -c 'print(1)'`.

### Step 5. Repo path edits (THIS) - see section C.1, commit on main
- Commit message e.g. "Folder moved beat_dl -> beatkey: repoint tests, tools, docs". No VERSION bump (no ship).
- Verify (the gate): `cd ~/dev/beatkey && git grep -n 'dev/beat_dl\|~/beat_dl' -- ':!archive' ':!handoff' ':!docs/research/symphony-review-2026-11-10' ':!PROGRESS-TRACKER.html' ':!tracker.json' ':!*.sqlite3'` -> only PICKUP.md/docs history lines left that are labelled historical. Then run the tests that carry the path: `cd ~/dev/beatkey && python3 -m unittest tests.test_bpm_extras` (or the project's usual runner) and `cd ~/dev/beatkey/app && swift test --filter 'ListenLogTests|LiveTests'` (these XCTSkip rather than fail when no python is found, so also check the output says they RAN, not skipped).

### Step 6. Claude trust/settings key and memory dir (MBP, account #1)
- Do 6a: `~/.claude.json` has `projects["/Users/jshriver/dev/beat_dl"]` (allowedTools, hasTrustDialogAccepted, mcp lists). Copy it to key `/Users/jshriver/dev/beatkey` (keep old key; or delete it after). Edit with python/json, never by hand while a claude process is writing the file (do it with no claude running in either account, or accept a trust prompt on first launch instead; that is the harmless fallback). Account #2 `~/.claude-newaccount/.claude.json` has no such key.
- Do 6b (memory follows): with NO claude process whose cwd is the old or new folder:
  `mv ~/.claude/projects/-Users-jshriver-dev-beat-dl ~/.claude/projects/-Users-jshriver-dev-beatkey`
  (864 MB, 21 entries: 10 session .jsonl + session dirs + `memory/` with MEMORY.md and 17 other files; same volume, instant). Memory files themselves contain no folder paths (grep checked), nothing to edit inside.
  `~/.claude-newaccount/projects/-Users-jshriver-dev-beat-dl` does not exist: nothing to move. No `...-dev-beat-dl--claude-worktrees-*` dirs exist.
- Verify: `ls ~/.claude/projects | grep -i 'beat'` shows `-Users-jshriver-dev-beatkey` and the vault one only; `ls ~/.claude/projects/-Users-jshriver-dev-beatkey/memory/MEMORY.md`; start `cd ~/dev/beatkey && claude` and confirm the startup memory index lists the entries (18 files in memory/); `claude --resume <old sid>` from the new cwd finds old sessions.
- Cleanup after: the scratchpad `/private/tmp/claude-501/-Users-jshriver-dev-beat-dl/...` is tmp; it will not be found by the new session and that is fine.

### Step 7. Vault rename (MBP; Syncthing carries it to Sofia)
- Do 7a: `mv ~/goat-arc/obsidian-vault/goat-mind/10-dev/beat_dl ~/goat-arc/obsidian-vault/goat-mind/10-dev/beatkey` (agent folder incl. its `.remember/`).
- Do 7b: `mv ~/.claude/projects/-Users-jshriver-goat-arc-obsidian-vault-goat-mind-10-dev-beat-dl ~/.claude/projects/-Users-jshriver-goat-arc-obsidian-vault-goat-mind-10-dev-beatkey` (2.1 MB; works only because Step 1 trashed the old one). No such dir on Account #2 or Sofia.
- Do 7c: vault note edits, section C.4.
- Verify: `ls ~/goat-arc/obsidian-vault/goat-mind/10-dev/beatkey` shows CLAUDE.md, PICKUP.md, HOUSE-KIT-RETROFIT.md, HANDOFF-disk-space-2026-11-18.md, .remember; `ls -d ~/goat-arc/obsidian-vault/goat-mind/10-dev/beat_dl 2>&1` (No such file); Sofia after sync: `~/.claude/scripts/ssh-rc js-mac-pro 'ls ~/goat-arc/obsidian-vault/goat-mind/10-dev/beatkey; ls -d ~/goat-arc/obsidian-vault/goat-mind/10-dev/beat_dl 2>&1'`. If Syncthing leaves a `.sync-conflict` or old folder on Sofia, check `.stversions`, do not delete by hand without J.

### Step 8. Other owners on the MBP (handoffs), section C.5-C.7
- Loops registry (needed BEFORE the first session in the new cwd writes projstate, else "projstate: ... belongs to no project in registry-seed.json; pass key").

### Step 9. Sofia mv (only after Steps 3-5 are done, so Sofia can `git pull` the path fixes)
- Do: `~/.claude/scripts/ssh-rc js-mac-pro 'mv ~/dev/beat_dl ~/dev/beatkey && ls -d ~/dev/beatkey ~/dev/beat_dl 2>&1'`. Then, optional and only if J wants Sofia current: `~/.claude/scripts/ssh-rc js-mac-pro 'git -C ~/dev/beatkey pull --ff-only'`. NEVER a restart (rule 10-13); none needed.
- Pre-check (expect empty, run via ssh-rc): `ps aux | grep -i beat_dl | grep -v grep; crontab -l | grep beat; grep -l 'beat_dl' ~/Library/LaunchAgents/* 2>/dev/null`. Already empty at recon. Also confirm the PT harvest is still paused (STOP+BLOCKED, per memory): if the harvest resumes later it must be started from `~/dev/beatkey`.
- Verify: `ssh-rc js-mac-pro 'git -C ~/dev/beatkey status -sb; ls -d ~/dev/beat_dl 2>&1'` (clean/ahead-behind only; old path "No such file"). Exit-code rule: judge by output.
- Sofia FLR-side checks after the mv (owner FLR, section C.6): `ssh-rc js-mac-pro 'grep -rn "dev/beat_dl" ~/dev/fourletterrecords --include=*.py --include=*.sh --include=*.html --include=*.plist 2>/dev/null'` (expect empty).

### Step 10. Final sweep + sync
- MBP: `grep -rIn 'dev/beat_dl' ~/.claude/CLAUDE.md ~/.claude/scripts ~/.claude/hooks ~/.claude/commands ~/.claude/PROJECTS.md ~/.claude/settings.json ~/dev/house-kit/CLAUDE.md ~/goat-arc/obsidian-vault/goat-mind/10-dev/*.md ~/goat-arc/obsidian-vault/goat-mind/10-dev/beatkey/*.md` -> empty.
- If any `~/.claude/*` file was edited (C.3 PROJECTS.md): run `~/.claude/scripts/sync-claude-setup.sh` (propagates to Sofia + account #2).
- Update this repo's PICKUP.md CURRENT STATE (rename done at <time>; new path; J-run publish line = `! bash ~/dev/beatkey/tools/publish.sh`).
- Launch commands going forward: `cd ~/dev/beatkey && claude` (code) and `cd ~/goat-arc/obsidian-vault/goat-mind/10-dev/beatkey && claude` (vault agent).

## C. Every place that names the old path

### C.1 In the repo (owner THIS). Live code and tests first.

| # | file:line | current | new |
|---|---|---|---|
| 1 | app/Tests/OrionTests/ListenLogTests.swift:212 | `URL(fileURLWithPath: "/Users/jshriver/dev/beat_dl/bin/python/bin/python3")]` | same with `/dev/beatkey/` (better: `NSHomeDirectory()+"/dev/beatkey/bin/python/bin/python3"`) |
| 2 | app/Tests/OrionTests/ListenLogTests.swift:267 | same | same |
| 3 | app/Tests/OrionTests/LiveTests.swift:392 | same (in worktree aadaf: line 397) | same |
| 4 | tests/test_bpm_extras.py:311 | `Path("/Users/jshriver/dev/beat_dl/bin/ffmpeg")` | `Path("/Users/jshriver/dev/beatkey/bin/ffmpeg")` |
| 5 | tools/verify-labels/server.py:23 | `DATA = "/Users/jshriver/dev/beat_dl/docs/research/pt-ground-truth"` | `os.path.join(os.path.dirname(HERE.rstrip("/")), "docs/research/pt-ground-truth")` i.e. derive from HERE (`HERE/../..`); or literal `/dev/beatkey/` |
| 6 | tools/train-tempocnn/leakage_check.py:66 | `default="/Users/jshriver/dev/beat_dl"` | `default=HERE.parents[1]` (HERE already defined; `common.ROOT` is the same) or literal `/dev/beatkey` |
| 7 | app/RELEASING.md:46 | `` `! bash ~/dev/beat_dl/tools/publish.sh` `` | `` `! bash ~/dev/beatkey/tools/publish.sh` `` |
| 8 | README.md:1 | `# beat_dl` | `# beatkey` (J decides wording, e.g. `# Beat Key (beatkey)`; product name is Beat Key) |
| 9 | install.command:6 | `echo "  beat_dl installer"` | `echo "  beatkey installer"` (cosmetic, user-visible text) |
| 10 | deps.sh:104 | `echo "❌ beat_dl needs macOS $MIN_MACOS or newer; ..."` | `beatkey needs macOS ...` (cosmetic; tests may grep this text, grep tests/ first) |
| 11 | tools/build-old-mac/essentia.sh:30,177,180,181 and ffmpeg-arm64.sh:5,9 | `beat_dl-oldbuild`, `beat_dl-ffbuild`, "beat_dl legacy build" | NOT paths to the folder (tmp dirs / package metadata). Leave, or rename the cache dir names; not needed for the move |
| 12 | tools/pt-harvest/{bpmctx.py:2,14, harvest.py:74, hlib.py:212,228}, tools/train-tempocnn/{common.py:17, key_eval.py:2} | the word "beat_dl" in comments/strings; `hlib._BEATDL` regex | name only, not the path. Leave |
| 13 | app/build.sh, tools/publish.sh, run.sh, run.command | NO old path (relative `dirname`); publish.sh:20 REPO already Orion | none |

Live docs in the repo (owner THIS; sed-able, `s#~/dev/beat_dl#~/dev/beatkey#g`):
- PICKUP.md:14 ("local folder move ~/dev/beat_dl -> ~/dev/beatkey LAST"), :15 and :24 (`! bash ~/dev/beat_dl/tools/publish.sh`, the J-run publish command: MUST become `~/dev/beatkey/tools/publish.sh` or J runs a dead path), :18. Older blocks :41 :48 :117 :149 :156 :192 :203 :227 :252 :277 are history; either leave or sed (they say "J runs `! bash ~/dev/beat_dl/tools/publish.sh`"; a stale copy-paste there is a trap, so sed them too and keep one note "(was beat_dl until 2026-11-19)").
- docs/plans/finish-2026-11-19.md:8 (`git -C ~/dev/beat_dl status`), :38 (publish alert text `! bash ~/dev/beat_dl/tools/publish.sh`).
- docs/plans/plugin-2026-11-19.md:162 (`goat-mind/10-dev/beat_dl` -> `10-dev/beatkey`; also lives in the worktree aadaf copy until merged).
- docs/research/bpm-detection-research.md:169 (`cd ~/dev/beat_dl/docs/research/bpm-bench`), key-detection-research.md:272 (`cd ~/dev/beat_dl/docs/research/key-bench`), plugin-recon-2026-11-19.md:3.
- tracker.json:2 and PROGRESS-TRACKER.html:2,24 title "beat_dl — the whole job" (-> "beatkey — the whole job"; tracker.json is mirrored by Loops, see C.5).
- Leave as history (do not edit): handoff/*, archive/*, docs/research/symphony-review-2026-11-10/*, docs/research/detune-bench-*/before|after.txt, docs/superpowers/*, sqlite3 files, `.remember/*`. Many handoffs say "Reply to ~/dev/beat_dl/handoff/FROM-FLR-SITE-*.md": new replies go to `~/dev/beatkey/handoff/`.
- GitHub slug `thuhmadhatter42/beat_dl` still in: archive/friends-page/{index.html:33,serve.py:22} (retired page, leave), handoff/TO-FLR-SITE-2026-10-28-* (history), tracker.json:161, PICKUP.md:304,306 (history). GitHub redirects the old slug (PICKUP says redirect is tested before build).
- Worktree copies: aadaf and af307 carry the same lines (RELEASING.md:46, the three Swift tests, af307 also server.py:23, leakage_check.py:66, test_bpm_extras.py:311). Resolved by merging/removing them in Step 2 BEFORE the edits, so no merge conflicts.

### C.2 Repo-adjacent state (THIS)
- `~/.claude.json` key `/Users/jshriver/dev/beat_dl` -> `/Users/jshriver/dev/beatkey` (Step 6a).
- Auto-memory dir (Step 6b); vault-folder memory dir (Step 7b).
- Session history: `~/.claude/session-dash/*/{meta,tracker}.json` (721 dirs, ~40 name the path), `~/loops/data/session-state/*.json` (cwd field, 7 of them name the path), `~/loops/data/sessions/mbp/*/{log.jsonl,meta.json}`: HISTORY. Do not rewrite. Dashboard history of old sessions keeps the old cwd by design.

### C.3 `~/.claude` (owner: global rules / rig, 06-ai/claude-code). Only name mentions, no functional path.
- `~/.claude/PROJECTS.md:37` `**beat_dl**, **video_dl**, ...` (Sofia copy same, synced) -> `**beatkey** (was beat_dl)`; then run sync-claude-setup.sh.
- `~/.claude/settings.json:309` description text "for the beat_dl harvester" (plugin/MCP description string; harmless, leave).
- `~/.claude/skills/project-tracker/SKILL.md:49` ("`--alias` for every other name J calls it (`beat_dl`/`beat-dl`/...)") is alias guidance, add `beatkey`; vault copy `goat-sync/claude-setup/skills-from-j/project-tracker/SKILL.md` same. Optional.
- `~/.claude/hook-candidates.md:19,21`, `standing-feedback.md:225`: historical incident text. Leave.
- No launchd plist, no hook, no script, no command, no zsh alias, no crontab names the path (grepped). `~/.claude-newaccount/{hooks,commands,skills,CLAUDE.md}` are symlinks into #1, covered.

### C.4 Vault notes (owner THIS for items under 10-dev/beat_dl; others named)
Inside the folder being renamed (THIS):
- 10-dev/beat_dl/CLAUDE.md:1 `# CLAUDE.md — 10-dev/beat_dl` -> `10-dev/beatkey`; :3 `Vault agent folder for **beat_dl**. Code: ~/dev/beat_dl (outside the vault; ...)` -> `**beatkey**. Code: ~/dev/beatkey`; :4 `Open beat_dl sessions HERE` -> `Open beatkey sessions HERE`. Add a one-line History: "2026-11-19 renamed from beat_dl (code folder and this folder); the old retired friends-page folder 10-dev/beatkey was trashed first."
- 10-dev/beat_dl/PICKUP.md:1 (`app state lives in ~/dev/beat_dl/PICKUP.md`), :6 ("`beat_dl` = the Beat Key app's code folder. `10-dev/beatkey` = the old friends download page, RETIRED") rewrite: beatkey is now the app; the retired page is gone), :9, :12, :21.
- 10-dev/beat_dl/HOUSE-KIT-RETROFIT.md:3 (`# Beat Key (beat_dl)`), :6 (`**Code:** ~/dev/beat_dl ... Vault folder 10-dev/beatkey is the retired download page; this one is the app.` -> `Code: ~/dev/beatkey`, delete the retired-page sentence).
- 10-dev/beat_dl/HANDOFF-disk-space-2026-11-18.md:2,13 (`~/dev/beat_dl is 11 GB`): history, leave or sed.
Outside it (owners):
- 10-dev/index.md:21 `- `beat_dl/` — code `~/dev/beat_dl`` -> `- `beatkey/` — code `~/dev/beatkey``, and check that index sorts/lists no second `beatkey` line (the retired one). Owner: 10-dev folder (vault 10-dev/CLAUDE.md). THIS may do it as it is the pointer to this folder; if policy says no edits outside, hand off.
- 10-dev/house-kit-recon-2026-11-18.md:29 `~/dev/beat_dl/docs/BOARD-TALK.md` -> beatkey. Owner: house-kit. Also `~/dev/house-kit/CLAUDE.md:7` (read-only-sources list `~/dev/beat_dl`) and `~/dev/house-kit/{sample/Sources/HouseSample/Accent.swift:7, modules/accent/swift/Accent.swift:7}` comments `beat_dl/app/Sources/Orion/Faceplate/Accent.swift`. House-kit owner (HANDOFF: "repoint 4 mentions to beatkey").
- 10-dev/artemis/HOUSE-KIT-RETROFIT.md:13 mentions `~/dev/beat_dl`-era text? (match was the word beat_dl in a line about board-talk): Artemis owner, comment only.
- 10-dev/fourletterrecords/PICKUP.md:13 contains a LIVE launch command `cd ~/goat-arc/obsidian-vault/goat-mind/10-dev/beat_dl && claude "..."` (breaks after Step 7) and `~/dev/beat_dl/handoff/...` replies at :40,:49,:54,:63; admin-jshriver-com-log.md:3; handoff/FROM-BEAT_DL-2026-11-18-admin-beatkey-gaps.md:14; handoff/FROM-FLR-2026-11-17-reply-to-beat_dl.md. Owner: fourletterrecords (handoff). Old handoff reply paths `~/dev/beat_dl/handoff/FROM-FLR-*.md` must now be `~/dev/beatkey/handoff/`.
- 06-ai/claude-code/PICKUP.md:25,30 (handoff paths `~/dev/beat_dl/handoff/TO-RIG-...`, `FROM-RIG-...`): rig owner; history, tell rig. 06-ai/claude-code/digs/macbook-disk-2026-10-17.md:27: history.
- 10-dev/MOVES-2026-11-14.md:49-50,194-195 and 10-dev/_sofia-move-log.md (many lines), 10-dev/{jos,jmessage}/move-log.md: move history; DO NOT edit. Add a new line in `_sofia-move-log.md` (owner of that log: fourletterrecords/rig) recording this move.
- Journals, 00-inbox, 03-tmr (somn-serious.md:28, network.md:101 about Studio E, off-limits): history, leave.
- No vault wikilinks to `[[beat_dl]]` found (grep over all .md).

### C.5 Loops (owner: ~/loops project, vault 01-loops; HANDOFF needed). Do before first new-cwd session.
- `~/goat-arc/obsidian-vault/goat-mind/journals/projects/data/registry-seed.json:546-558` (also read by `~/loops/core/jared/projstate.py` `resolve_key`, longest cwds prefix wins):
  - :549 `"home": "~/dev/beat_dl"` -> `"~/dev/beatkey"`
  - :551-554 `"cwds": ["~/dev/beat_dl", "Sofia:~/beat_dl"]` -> `["~/dev/beatkey", "~/dev/beat_dl", "Sofia:~/dev/beatkey", "Sofia:~/dev/beat_dl", "Sofia:~/beat_dl"]` (KEEP old entries so old sessions still map; the CLAUDE.md rule says never just repoint) plus the vault folder (`goat-mind/10-dev/beatkey`) if J wants those sessions on the card.
  - Card key `"beat_dl"` (line 546), `"title"` (547), `members` (`"beat_dl": "beat_dl"`, 555-556): J said "beat_dl -> beatkey everywhere". Full rename means: seed key + title + member key; `data/registry-a.json:422` (+ `src` 432, `pickup` 435, 437, 438 `~/dev/beat_dl/PICKUP.md|tracker.json`), `data/changed-keys.json:6,66`, `data/projects-feed.json`, `tools/regroup.py:46`, `data/pre-claude.json:12`, `data/candidates.json:417,757` (generated), `~/loops/loops-web/triage/project-types.json:33` (`"beat_dl": "lever"`), and RENAME the Loops projstate file `~/loops/data/jared/projstate/beat_dl.json` -> `beatkey.json` (plus archive/beat_dl-*.json prefix; projstate.py archives by `key + '-'` prefix). Loops cards `~/loops/data/jared/cards/LP-*.json` `"scope": "~/dev/beat_dl"` and `decide/D-*.json` `"cwd"` are history/ledger. Decide-card cwd is used to route answers: leave.
  - SAFE MINIMUM if Loops owner will not rename the key: add the new cwds above and keep key `beat_dl`; nothing breaks.
  - Add vault `_moved` pair `["10-dev/beat_dl", "10-dev/beatkey"]` (goat-mind-relative) per `journals/projects/CLAUDE.md` folder-move rule, and repoint seed cwds (done above).
  - Note: `_moved` is applied to every session cwd; the old trashed `10-dev/beatkey` sessions would merge into this card (fine).
- `~/loops/core/jared/trackermirror.py:5` docstring + `core/tests/test_trackermirror.py:14,27,29`: example only, but the mirror file name is DERIVED from the cwd: the tracker copy `~/loops/data/jared/trackers/mbp/dev__beat_dl.json` will become `dev__beatkey.json` on the next mirror; the old file stays as a stale copy on Sofia via Syncthing. Loops owner decides whether to delete `dev__beat_dl.json` (and whether the Loops UI maps tracker file names to project keys: check `loops-web/projects_api.py` for 'dev__').
- `~/loops/data/jared/projstate/beat_dl.json` is the live "registry key beat_dl" state J mentioned (cwd field `~/dev/beat_dl`).
- `~/loops/loops-web/triage/*`, `data/voice/*`, `data/triage-twin-verdicts.json`: free-text mentions of the name; leave.
- `journals/todo-mining/data/projects.json:35` `"beat_dl": {"cwd":"~/dev/beat_dl"}`: owner journals/todo-mining; handoff, optional.

### C.6 Sofia (owner: fourletterrecords for FLR files, THIS for the folder)
- `~/dev/beat_dl` itself -> mv (Step 9). Nothing launchd/cron/process uses it.
- FLR files that name the repo or old folder (owner fourletterrecords, HANDOFF; none breaks at runtime, they are comments or links):
  - `~/dev/fourletterrecords/flr-store.py:665` docstring "The beat_dl session ..." (text; the rename note in PICKUP said "FLR flr-store.py mention").
  - `~/dev/fourletterrecords/next/build.py:522` `Sources: ~/dev/beat_dl/handoff/TO-FLR-SITE-2026-11-09-...md` and `:523` `beat_dl README ... Shots: beat_dl handoff/flr-assets/` (comments) -> `~/dev/beatkey/...`.
  - `~/dev/fourletterrecords/next/build.py:654`, `next/beat-key.html:143`, and LIVE top-level `beat-key.html:143`: `<a href="https://github.com/thuhmadhatter42/beat_dl">Source code and licences</a>` -> `https://github.com/thuhmadhatter42/Orion` (works today via GitHub redirect; fix in build.py first, then regenerate html, as the page is generated).
- publish.sh's ssh targets: `tools/publish.sh:21,22,70,71,72` use `~/dev/fourletterrecords/...`, NOT beat_dl: no change.
- Also Sofia `~/.claude/PROJECTS.md` (same as C.3, arrives via sync), `~/.claude/skills/project-tracker/SKILL.md:49` (same).
- Sofia launchd `com.jshriver.beats-server` / `beats-tunnel` plists: no beat_dl or ~/dev/beatkey path inside (grepped); unaffected.
- NOT touched, per J's rules: Studio D/E/F copies (an old `~/beat_dl` copy exists on Studio E; its `git pull` still works through GitHub's redirect; leave).

## D. Handoffs to write (after the main session approves)
1. fourletterrecords: C.4 (PICKUP launch command + reply paths) and C.6 FLR file edits; reply dir now `~/dev/beatkey/handoff/`; record the move in `_sofia-move-log.md`.
2. Loops (~/loops owner): C.5 registry-seed + projstate rename + tracker mirror name.
3. house-kit: 4 comment/list mentions.
4. rig (06-ai/claude-code): PROJECTS.md line + project-tracker alias line + two PICKUP history lines.
5. journals/todo-mining: projects.json:35 (optional).

## E. Risks / things that bite
- Worktrees: moving with any worktree present without `git worktree repair` breaks them silently.
- Running soak/golden jobs of the plug-in agent write absolute paths under the worktree and a scratchpad named with `-Users-jshriver-dev-beat-dl`; do not move until it is done.
- The live session must end before the memory dir rename; otherwise the old `-dev-beat-dl` dir is re-created by the still-running process and memory splits in two.
- Old vault `10-dev/beatkey` memory dir + folder must be trashed before Step 7 or the mv fails / merges.
- PICKUP.md J-run publish commands (lines 15, 24) are copy-paste traps if left on the old path.
- `~/.claude.json` trust key: without Step 6a, first launch in the new folder shows the trust prompt (harmless), allowedTools reset.
- `app/.build` stale absolute paths: trash it, rebuild online.
- Installed apps on Studio D/E (not touched) keep updating via Sparkle and GitHub's Orion redirect.
