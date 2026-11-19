# Beat Key broadcast protocol (Beat Key <-> Artemis)

Beat Key's side of the Artemis "auto get key / auto get BPM" button. Code: `app/Sources/Orion/Broadcast.swift` (its header holds the same contract; keep the two in step). Tests: `app/Tests/OrionTests/BroadcastTests.swift`. Proposal came from `handoff/TO-ARTEMIS-2026-11-18-beat-key-button.md` §Protocol; not yet confirmed by Artemis.

Transport: macOS distributed notifications (`DistributedNotificationCenter`). `userInfo` is a property list (String / NSNumber only).

## `com.jshriver.orion.reading` (Beat Key posts)

| key | type | meaning |
|---|---|---|
| `source` | String | `"listen"` (Listen's reading), `"file"` (a finished download or analysed file), `"none"` (nothing on show), `"plugin"` (a plug-in's SEND BPM in Artemis, below). Always present. |
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

## `source: "plugin"` in `reading` (the plug-in's SEND BPM in Artemis)

When a Beat Key plug-in inside Artemis presses SEND BPM, the app posts one `reading` with `source: "plugin"`, the plug-in's `bpm`, no `key` / `confidence`, and `songID` = a salted hash of the host process (no name). It is not the app's own reading: `request` is still answered with the app's own (`last`), and a `plugin` reading is never deduped. Code: `Broadcast.relayPlugin`. The Artemis side is unconfirmed, like the rest of this contract.

# Plug-in SEND BPM (Beat Key plug-in <-> Beat Key app)

Plan `docs/plans/plugin-2026-11-19.md` §S1. No plug-in format can set the host's tempo, and the Accessibility permission the DAWs need belongs to an app, so the plug-in asks and the app sends through Send to DAW's own drivers. One contract, compiled by both sides: `app/Sources/BeatKeyShared/PluginSend.swift`. App half: `app/Sources/Orion/PluginSendListener.swift` (tests `PluginSendTests.swift`). Plug-in half: `plugin/ui/Senders.swift` (tests `plugin/test/face_test.swift`). Same transport (distributed notifications, property-list `userInfo`).

## `com.jshriver.orion.send` (plug-in posts)

| key | type | meaning |
|---|---|---|
| `requestID` | String | a fresh UUID per press (1-64 characters) |
| `bpm` | Double | the BPM as the face shows it (x2 / ÷2 applied), 20...999 |
| `hostBundleID` | String | the host's bundle id (`""` when it has none) |
| `hostName` | String | the host's name; the app falls back to it to find the DAW |
| `hostPid` | Int | the host's process id |
| `proto` | Int | `1` |

## `com.jshriver.orion.sent` (app posts)

| key | type | meaning |
|---|---|---|
| `requestID` | String | the request's |
| `ok` | Bool | the DAW took it |
| `message` | String | one line for the face: the driver's own result, or why not |

## What the app does with a `send`

- Host is a DAW Beat Key drives (`DAW.from(bundleID:name:)`): `DAWSendController.sendQuiet`, tempo only (plan §Q3 default): the same drivers, queue and one-at-a-time rule as Reading › Send to DAW, no result alert. Setup steps and the Accessibility guide still show in the app, as from the menu. Busy: `ok: false`, "Beat Key is already sending. Try again."
- Host is Artemis (`com.jshriver.artemis…`): the `reading` relay above, then `ok: true`.
- Any other host: `ok: false`, "Beat Key can't set the tempo in <host>."
- A payload that is not a request (no requestID, another `proto`, a BPM that is not a tempo): logged as `ERROR plug-in send refused: …`; answered `ok: false` with the reason when it has a requestID.
- The app answers within 7 s (`PluginSend.appDeadline`) even when the driver is still working ("<DAW> didn't answer in 7 s."); a later result is logged, never sent twice.

## What the plug-in does

1. Sandboxed host (`APP_SANDBOX_CONTAINER_ID` set): says so, sends nothing.
2. App not installed: "SEND BPM needs the Beat Key app." with a GET IT link to the download page.
3. App not running: opens it in the background, then posts `request` every 0.5 s until a `reading` answers (15 s at most). A running app gets 3 s to answer before the send goes anyway.
4. Posts `send`, waits 8 s (`PluginSend.pluginTimeout`) for the `sent` with its requestID. None: "Beat Key app didn't answer. Update it?"
5. On `ok`: reads the host's tempo back for up to 2 s. Moved: "Session tempo 141.98". Not moved: "Session still 120.00". The host gives plug-ins no tempo: "Sent 141.98. Host won't say its tempo."

## Logging (SEND BPM)

- App, beatkey.log (`[PluginSendListener]`, `[DAWSend]`): every request (`plug-in send: BPM 141.98 from com.ableton.live (pid …)`), every answer (`plug-in send answered (request …): ok|FAILED: …`), every refusal, a late driver result.
- Plug-in, plugin.log: the press, the launch, the post, and one `SEND BPM <bpm>: [FAILED: ]<outcome> (session was <tempo>)` line per press.
