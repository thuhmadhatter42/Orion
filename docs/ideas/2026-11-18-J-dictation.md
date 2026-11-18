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
