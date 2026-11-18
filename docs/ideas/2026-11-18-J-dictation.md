# J's ideas, dictated 2026-11-18 02:51 — Beat Key side

Source: J's voice dictation in the beat_dl session. Nothing built yet. Artemis part: `handoff/TO-ARTEMIS-2026-11-18-beat-key-button.md`.

## 1. Drop many files at once
- Today: J got 10 beats over AirDrop and had to drop them into Beat Key one at a time.
- Want: drop any number of files at once; Beat Key queues and analyses each.

## 2. Toggle: add key + BPM to the file name
- Setting, OFF by default (J agrees off is the right default).
- ON: every file Beat Key analyses gets its key + BPM added to the name, unless Beat Key already added its own tag.
- A producer's own key/BPM in the name does NOT stop it: dropping a file in Beat Key = the person wants Beat Key's reading.
- This was one of the original app's five features. Old format (app_run.py:9): `<stem> (<bpm> BPM <k1> <k2> <k3>).<ext>`.
- Open: same format or top key only; rename in place or a copy (decide list).
- J 03:00: rename the file itself, but ASK first. Once the key is found, a non-invasive prompt: "Rename the file?" + "Remember my choice" checkbox.
- Pro Tools guard: a file inside a Pro Tools session's `Audio Files` folder (parent folder holds a .ptx session) ALWAYS gets a forced, blocking confirm, whatever was remembered: renaming makes Pro Tools lose the file.
- History (read 03:01): the original run.sh:83-84 renamed the DOWNLOADED file in place with all three keys (`<stem> (<bpm> BPM k1 k2 k3).<ext>`); dropped files (dropped.py) were never renamed.
- Owner: the prompt is one chair (rename policy: ask / remember / Pro Tools guard), calling the one renamer `renamed_name`.

## 3. Listen: tap one running app
- Input options stay exactly as they are now.
- Add an "Add App" submenu listing every open app.
- Apps playing audio right now go at the top; the rest A–Z.
- Picking one = Listen hears only that app (today it hears every app, SystemAudio.swift:65).

## 4. Help text far shorter
- J: current descriptions read "psychotic, very verbose". Model them on Pro Tools hover tooltips: a few words, not ten-word pop-ups.
- J offered: open Pro Tools on Studio D and hover controls to see their length. (Studio D window = his offer this session only.)

## 5. Beat Key side of the Artemis button
- Beat Key must broadcast what it is hearing (key, BPM, song change) so Artemis can "auto get key" / "auto get BPM", and answer a one-shot "what is the key/BPM now?".
- Proposal in the Artemis handoff §Protocol; Beat Key builds its side once Artemis agrees.

## Score: where each idea plugs in (code-symphony create mode)
One owner per behavior; each idea extends the module that already owns it. Read 2026-11-18 03:0x from the code.

1. **Multi-file drop** — owner: `FaceplateView.drop` (FaceplateView.swift:177) → `Engine.analyze(files)` (Engine.swift:195). It already takes many files at once ("3 OF 3" pages). So something ate J's drop (rule 3). Lines that refuse: `guard !engine.state.isBusy … return false` (FaceplateView.swift:178, Engine.swift:202); the window is the ONLY drop target (no pocket, Mini or Dock-icon drop). Fix in the one path: one drop entry (window + pocket + Dock icon all call it), Engine queues instead of refusing while busy. Needs J: where he dropped.
2. **Key+BPM in name** — owner: `renamed_name` (app_run.py:61), today used only after a YouTube download (app_run.py:312). Extend the same step to `analyze` behind the setting (Settings.swift → helper arg). The same function that writes the tag also recognizes it ("already tagged by Beat Key"); no second renamer in Swift.
3. **Tap one app** — owner: `SystemAudio` capture, filter at SystemAudio.swift:66 (every app). App choice = change that filter to the chosen app; same capture path, same Input setting as devices. "Playing now" ordering needs an OS source for which app is outputting audio; check the documented API and its macOS floor live before building (Beat Key supports macOS 12, Sofia runs 12.7.6).
4. **Short Help** — owner: `HelpText` (Help.swift:58), cap `HelpTip.maxBody = 140` (Help.swift:48) enforced by HelpTests.swift:98. Lower the cap in that one place; the test then fails every long tip until rewritten.
5. **Broadcast to Artemis** — new chair `Broadcast`, fed only from the one reading source (live `LiveEvent.reading` and file results), never posted from views. Contract in the Artemis handoff §Protocol.

## 6. A picked key pins; the detector never stops (J, 02:58 on D-ed342f5288 item 1)
- Clicking a key (top-3 slot, wheel, MANUAL menu, keyboard: every path) pins it: dial, wheel, piano, chords show it, and it is what gets broadcast (Artemis, Auto-Tune send, rename tag).
- The detector keeps running and showing its opinion. The pinned slot stays where it is (slot 2 stays B♭ in slot 2); the other slots keep updating.
- Click the pinned slot again → unpinned, slot shows whatever the detector now has there.
- A pick never makes Beat Key think that key is more likely.
- Code today (read 02:59): one owner already, `setManualKey` / `clearManualKey` (ManualKeySelection.swift:32/49); Listen keeps analysing while pinned (LiveSession has no manualKey reference). Gaps:
  a. `Result.respelled` (KeySpelling.swift:42) moves the pick to the front of the list, so slots reorder. Fix there: the pick no longer reorders; views mark the pinned slot.
  b. The MANUAL menu path saves a teach record (KeyTeach.teach, MenuBar.swift:335; for training later, not read by detection). J's rule says picks add no weight, so this record goes or J keeps it as opt-in data. Ask J.
