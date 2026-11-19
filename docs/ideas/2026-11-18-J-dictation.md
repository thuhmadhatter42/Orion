# J's ideas, dictated 2026-11-18 02:51 — Beat Key side

Source: J's voice dictation in the beat_dl session. **Status 2026-11-18 18:59: every Beat Key idea below (1-6) is BUILT in 0.1.77 (published 18:51); the Artemis side (idea 5's receiver, `handoff/...`) is still open.** Artemis part: `handoff/TO-ARTEMIS-2026-11-18-beat-key-button.md`.

## 1. Drop many files at once
- **[BUILT 0.1.77]** one drop/open path (Intake.receive → Engine.submit) with a queue: window, menu bar icon, pocket, Mini, Dock icon, Open With. Studio D 3 files at once PASS (0.1.75); real-Mac drop on the menu-bar/Dock icon not hand-tested.
- Today: J got 10 beats over AirDrop and had to drop them into Beat Key one at a time.
- Want: drop any number of files at once; Beat Key queues and analyses each.

## 2. Toggle: add key + BPM to the file name
- **[BUILT 0.1.77]** Settings › File names (Ask me each time / Always / Never), rename prompt with remember choice, Pro Tools Audio Files guard. Format = the old one with all three keys (`KEY_COUNT = 3`), file renamed in place. The "Open" line below is answered by that.
- Setting, OFF by default (J agrees off is the right default).
- ON: every file Beat Key analyses gets its key + BPM added to the name, unless Beat Key already added its own tag.
- A producer's own key/BPM in the name does NOT stop it: dropping a file in Beat Key = the person wants Beat Key's reading.
- This was one of the original app's five features. Old format (app_run.py:9): `<stem> (<bpm> BPM <k1> <k2> <k3>).<ext>`.
- Open [CLOSED 2026-11-18: built with all three keys, renamed in place, 0.1.77]: same format or top key only; rename in place or a copy (decide list).
- J 03:00: rename the file itself, but ASK first. Once the key is found, a non-invasive prompt: "Rename the file?" + "Remember my choice" checkbox.
- Pro Tools guard: a file inside a Pro Tools session's `Audio Files` folder (parent folder holds a .ptx session) ALWAYS gets a forced, blocking confirm, whatever was remembered: renaming makes Pro Tools lose the file.
- History (read 03:01): the original run.sh:83-84 renamed the DOWNLOADED file in place with all three keys (`<stem> (<bpm> BPM k1 k2 k3).<ext>`); dropped files (dropped.py) were never renamed.
- Owner: the prompt is one chair (rename policy: ask / remember / Pro Tools guard), calling the one renamer `renamed_name`.

## 3. Listen: tap one running app
- **[BUILT 0.1.77]** Input › Add App submenu (Live/AudioApps.swift): playing-now apps first on macOS 14.2+, plain A-Z on 13, hidden below 13.
- Input options stay exactly as they are now.
- Add an "Add App" submenu listing every open app.
- Apps playing audio right now go at the top; the rest A–Z.
- Picking one = Listen hears only that app (today it hears every app, SystemAudio.swift:65).

## 4. Help text far shorter
- **[BUILT 0.1.77]** Board Talk written (docs/BOARD-TALK.md), all 69 tips rewritten, `HelpTip.maxBody` = 60. **Still open:** the length rule has not been checked against real Pro Tools tooltips (the Studio D capture never landed: two tries ended locked/cut off); HarmonyView wheel "why" strings are still verbose.
- J: current descriptions read "psychotic, very verbose". Model them on Pro Tools hover tooltips: a few words, not ten-word pop-ups.
- J offered: open Pro Tools on Studio D and hover controls to see their length. (Studio D window = his offer this session only.)
- J 03:00 picked "Look on Studio D": Sonnet agent capturing Pro Tools tooltips word for word (evidence → docs/research/pt-tooltips-2026-11-18/ on its worktree branch, stops by 04:45).
- J 03:02: first write a UI voice guide named **Board Talk** (like a scribble strip on a console). Built from (a) Pro Tools tooltip lengths and shape from Studio D, (b) J's own words: how he names things out loud in his dictation (e.g. "receive key", "get BPM from DAW", "auto get key"). Then every Help tip is rewritten in Board Talk, and HelpTip.maxBody drops to Board Talk's limit so the tests hold it.
- Board Talk lives at docs/BOARD-TALK.md; Artemis can use the same guide.

## 5. Beat Key side of the Artemis button
- **[BUILT 0.1.77]** Beat Key side only: Broadcast.swift + docs/protocol-beatkey-broadcast.md. **Still open:** Artemis has not picked up its handoff or confirmed the protocol.
- Beat Key must broadcast what it is hearing (key, BPM, song change) so Artemis can "auto get key" / "auto get BPM", and answer a one-shot "what is the key/BPM now?".
- Proposal in the Artemis handoff §Protocol; Beat Key builds its side once Artemis agrees.

## Score: where each idea plugs in (code-symphony create mode)
One owner per behavior; each idea extends the module that already owns it. Read 2026-11-18 03:0x from the code.

1. **Multi-file drop** — owner: `FaceplateView.drop` (FaceplateView.swift:177) → `Engine.analyze(files)` (Engine.swift:195). It already takes many files at once ("3 OF 3" pages). So something ate J's drop (rule 3). Lines that refuse: `guard !engine.state.isBusy … return false` (FaceplateView.swift:178, Engine.swift:202); the window is the ONLY drop target (no pocket, Mini or Dock-icon drop). Fix in the one path: one drop entry (window + pocket + Dock icon all call it), Engine queues instead of refusing while busy. Needs J: where he dropped.
2. **Key+BPM in name** — owner: `renamed_name` (app_run.py:61), today used only after a YouTube download (app_run.py:312). Extend the same step to `analyze` behind the setting (Settings.swift → helper arg). The same function that writes the tag also recognizes it ("already tagged by Beat Key"); no second renamer in Swift.
   - **BUILT (branch worktree-agent-ac9cf08b85089fd2d), chair map:** format + recogniser + the rename itself = `app_run.py` only (`renamed_name`, `is_tagged`, `rename_file`, `cmd_rename`; the one key-count constant is `KEY_COUNT`; the download path calls the same `rename_file`). The helper's `analyzed` event carries `tagged`; a new `rename <file> <bpm> <key>...` subcommand answers `renamed` / `rename_skipped` / `rename_failed(errno)`. Swift never builds or parses a name. Policy = `RenameCoordinator` (Rename.swift): ask / remembered choice (`RenameSettings`, UserDefaults `renameChoice` ask|always|never, same value in Settings › File names) / Pro Tools guard (`ProToolsGuard`: parent folder "Audio Files" whose parent holds a .ptx; always a blocking `NSAlert`, whatever was remembered). Running + path refresh = `Engine.rename` / `Engine.applyRenamed` (LCD reading, Recent Readings, pinned key all follow the new path). Key in the name = `Result.keyInUse` (pin first) read when the answer comes.
3. **Tap one app** — owner: `SystemAudio` capture, filter at SystemAudio.swift:66 (every app). App choice = change that filter to the chosen app; same capture path, same Input setting as devices. "Playing now" ordering needs an OS source for which app is outputting audio; check the documented API and its macOS floor live before building (Beat Key supports macOS 12, Sofia runs 12.7.6).
4. **Short Help** — owner: `HelpText` (Help.swift:58), cap `HelpTip.maxBody = 140` (Help.swift:48) enforced by HelpTests.swift:98. Lower the cap in that one place; the test then fails every long tip until rewritten.
5. **Broadcast to Artemis** — new chair `Broadcast`, fed only from the one reading source (live `LiveEvent.reading` and file results), never posted from views. Contract in the Artemis handoff §Protocol.

## 6. A picked key pins; the detector never stops (J, 02:58 on D-ed342f5288 item 1)
- **[BUILT 0.1.77]** pinned key keeps its slot (Result.keyInUse; no reorder). Gap a and b below are both closed: b = J ruled 2026-11-18 a MANUAL-menu pick teaches nothing (74601be). Cleanup done: KeyTeach.save, TeachStore, TeachLabel, TeachAudio, TeachSource, ClipRing, Wav, LiveController.recentClip removed; KeyTeach.teach renamed KeyTeach.pin.
- Clicking a key (top-3 slot, wheel, MANUAL menu, keyboard: every path) pins it: dial, wheel, piano, chords show it, and it is what gets broadcast (Artemis, Auto-Tune send, rename tag).
- The detector keeps running and showing its opinion. The pinned slot stays where it is (slot 2 stays B♭ in slot 2); the other slots keep updating.
- Click the pinned slot again → unpinned, slot shows whatever the detector now has there.
- A pick never makes Beat Key think that key is more likely.
- Code today (read 02:59): one owner already, `setManualKey` / `clearManualKey` (ManualKeySelection.swift:32/49); Listen keeps analysing while pinned (LiveSession has no manualKey reference). Gaps:
  a. `Result.respelled` (KeySpelling.swift:42) moves the pick to the front of the list, so slots reorder. Fix there: the pick no longer reorders; views mark the pinned slot.
  b. [CLOSED 2026-11-18: J ruled a pick teaches nothing; built 74601be, in 0.1.77] The MANUAL menu path saves a teach record (KeyTeach.teach, MenuBar.swift:335; for training later, not read by detection). J's rule says picks add no weight, so this record goes or J keeps it as opt-in data. Ask J.
