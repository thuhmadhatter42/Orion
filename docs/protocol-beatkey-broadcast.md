# Beat Key broadcast protocol (Beat Key <-> Artemis)

Beat Key's side of the Artemis "auto get key / auto get BPM" button. Code: `app/Sources/Orion/Broadcast.swift` (its header holds the same contract; keep the two in step). Tests: `app/Tests/OrionTests/BroadcastTests.swift`. Proposal came from `handoff/TO-ARTEMIS-2026-11-18-beat-key-button.md` §Protocol; not yet confirmed by Artemis.

Transport: macOS distributed notifications (`DistributedNotificationCenter`). `userInfo` is a property list (String / NSNumber only).

## `com.jshriver.orion.reading` (Beat Key posts)

| key | type | meaning |
|---|---|---|
| `source` | String | `"listen"` (Listen's reading), `"file"` (a finished download or analysed file), `"none"` (nothing on show). Always present. |
| `songID` | String | Opaque id of the song or file. A salted hash, new each Beat Key launch; never a name. `""` when source is `"none"`. Always present. |
| `key` | String | The key IN USE, Auto-Tune's spelling (`"Ebm"`, `"F#"`, `"Bb"`): the key J pinned if there is a pin, else the detector's #1 (`Result.keyInUse`). Absent = no key. |
| `bpm` | Double | The BPM as Beat Key's dial shows it, including the x2 / x0.5 click (141.98 measured, else the analyzer's own number). Absent = no BPM. |
| `confidence` | Double | 0...1, the detector's own % for `key`. 0 when the key is a pick the detector does not list. Absent when there is no key. |

Posted when any of those values changes, and only then (identical consecutive payloads are not posted twice):
- a new live reading, or a new file result (or paging to another dropped file);
- a song change (a new `songID`, even with the same key and BPM);
- a pin set or cleared (the key changes);
- the BPM x2 / x0.5 click;
- the reading going away (Listen stopped, nothing on show): `source: "none"`, no key, no bpm.

One is also posted when Beat Key starts (`source: "none"`).

## `com.jshriver.orion.request` (anyone posts, no userInfo)

Beat Key answers with exactly one `reading` (same name, same keys) carrying the current state; `source: "none"` and no key / bpm when there is nothing on show. The answer is posted even when nothing changed since the last `reading`. It is the one-shot "what is the key / BPM now?".

## Not in the payload

No song title, file name or path, ever. `songID` cannot be reversed to a name.

## Beat Key not running

Nothing is posted and nobody answers. Artemis greys its Beat Key items (checks for the running process); no error dialog.

## Where it comes from (the score)

`PocketState.shownReading` (Pocket.swift) is the one place the app's current reading is chosen: Listen's while it is on, else the file result paged to, with a pick pinned. `Broadcast.install` (called from `OrionApp.launch`) subscribes to the same sources the menu bar reads and calls `Broadcast.feed`; nothing else posts, no view posts, and the broadcast keeps no second copy of the reading (`last` is only what was said last, used for the dedupe and the reply).

## Logging (beatkey.log, tag `[Broadcast]`)

- every post: `post: key Ebm bpm 141.98 source file conf 80 song a1b2c3d4e5f6` (values and opaque id only);
- every request answered: `request answered: …` (same text);
- identical payloads skipped: counted, logged at most once a minute (`dedupe: N identical readings skipped (T in all)`);
- a key or BPM that is not usable is left out and logged as `ERROR broadcast: …`.
