# Overnight plan 2026-11-20: plug-in face = app window + DOWNLOAD into Pro Tools

J's asks (2026-11-19 17:19 and 01:30): the plug-in looks like the app window (his screenshot of the Faceplate). A YouTube beat downloads straight into Pro Tools. Work all night. Tomorrow J should only have to say "thanks, it's sick".
J's placement answer: "keep the history, but not active". The DOWNLOAD menu lists recent picks, nothing is pre-selected, and J picks every time.
Checklist: `overnight-2026-11-20-TOC.md`. Work it in order, tick each step, and write the hand-off line under each step.

## §1 Recon (read only)
Read `PICKUP.md`, `docs/plans/plugin-2026-11-19.md`, `plugin/ui/*.swift`, `app/Sources/Orion/Faceplate/*`, `app/Sources/BeatKeyShared/*`, `app/Sources/Orion/DAWSend/PTSLClient.swift` and the app downloader.
List every Faceplate control, and for each one say whether it can work inside a plug-in host (AU, VST3, AAX, AudioSuite). Write the table into §1 of this file.

### §1 result: Faceplate controls in a plug-in host (AU, VST3, AAX, AudioSuite)
Source: `FaceplateFace` (app/Sources/Orion/Faceplate/FaceplateView.swift) and the PocketView pieces it uses.

| Control | Works in a host? | Plug-in source / reason |
|---|---|---|
| Rail (wordmark, status legend) | Yes | status from the instance (alive, bypass, silent, error) |
| LCD readout: key dial, hero key, lamp | Yes | plug-in's own analysis (bkp_view_read) |
| LCD: BPM + ×2/÷2 factor chips | Yes | bkp_view_set_tempo_mult |
| LCD: top 3 keys with %, pin / MANUAL key menu | Yes | bkp_view_set_pin |
| LCD: scale keyboard, tuning meter | Yes | reading's key + tuning_cents |
| LCD: page arrows, SHOW IN FINDER, file name | No (hidden) | the plug-in reads the track, not files |
| Link field + DOWNLOAD (PASTE + DOWNLOAD) | Yes, via the app | §4: the app's downloader runs it; menu of §5 beside it |
| LOG IN TO YOUTUBE cap | Via the app | the app owns the login window; face says "Log in from the Beat Key app" |
| Open Audio field + FIND KEY/BPM | No (hidden) | the host feeds audio; AudioSuite has its own Analyze |
| Source field + level meter | Yes (read-only) | source = the track ("Track input"); meter not wired (no level in bkp_view yet) |
| HOLD | No (hidden) | the instance has no hold; pin does the job |
| NEW SONG (reset key) | Yes | bkp_view_new_song |
| LISTEN | No (hidden) | the plug-in always listens to its track |
| SEND TO DAW | Yes, via the app | = SEND BPM (PluginSend listener) |
| SEND TO AUTO-TUNE | Yes | AutoTuneButton (shared writer, no app) |
| EXPORT MIDI | Yes | MIDI drag-out .mid (MidiFile shared) / the MIDI variant |
| RECENT ▾ | Yes (download history) | the §5 menu's recent picks |
| SETTINGS | No (hidden) | an app window; COLOR + HELP cover the plug-in's settings |
| COLOR | Yes | FaceSettings swatches (no app colour panel in a host) |
| REPORT | Yes | FaceHouse.report (log attached) |
| HELP | Yes | tips (Board Talk) |
| ADVANCED (harmony column: chords, key wheel, MATCH TO, notes heard) | Yes | chords from the reading; chord sound via the MIDI variant only, drag-out works |

Hidden, not dead: page arrows / SHOW IN FINDER, Open Audio + FIND, HOLD, LISTEN, SETTINGS.

Hand-off §1 → §2: table above (b9f306c). Next: move the face's views into one shared place.

## §2 One face, shared
Move the Faceplate views into `BeatKeyShared` behind a small protocol: the model and actions the face needs.
The app and the plug-in both render that same view tree. The app keeps its behaviour; it is a refactor only.
Gate: swift tests are green, and the app face render is pixel-identical to before (MarketingRenderTests).

### §2 result
- Where: `app/Sources/Orion/Face/` (not the BeatKeyShared SwiftPM module). Both sides compile the same files: the app as
  part of its Orion target, each plug-in format into its own Swift module (plugin/ui/build-face.sh, like Glow.swift already
  was). Why not BeatKeyShared: as a separate SwiftPM module every type, property and init the window uses would need
  `public` (hundreds of declarations, a second API to keep in step) for no gain; the plug-in compiles the sources either way.
- The protocol: PocketState (every value the face draws) + PocketActions (every closure it calls). New: `surface`
  (FaceSurface .app / .plugin), `status`, `downloadMenu`, `colorOpen`; actions `pinKey` / `clearPin`, `color`, `report`,
  `pickPlacement`, `closeDownloadMenu`, `midiDrag`. What each side must provide beyond that: Face/FaceHost.swift
  (AppLog.log, AutoTuneSend.shortcutDisplay).
- Left in the app (machinery, never in Face/): FaceplateView, FaceplateModel, Faceplate/FaceAppWiring.swift (SpellingSettings
  pins, shownReading, harmony wiring, HarmonyPrefs <-> DisplaySettings, COLOR/REPORT), HelpApp.swift (HelpSettings, the
  help window's table), ReadingStores.swift, Accent.swift (AccentSettings, AccentPanel, PaletteRoot).
- Gate: swift 752 tests, 1 failure = the pre-existing What's New "0.1.78" test (fixed in the merged listener branch).
  Renders: 86 of 89 byte-identical to before; the 3 others differ run-to-run on the old code too (pocket/window dial-hover
  animation; Settings' device pop-up width depends on the Mac's audio devices).

Hand-off §2 → §3: the face compiles alone (`plugin/ui/build-face.sh`); next, the plug-in draws it.

## §3 Plug-in uses the shared face
`plugin/ui` FaceModel/FaceBridge implement the protocol. Controls that can't work in a host are hidden, not left dead; list them.
The plug-in readout (key, BPM, top 3, notes heard, tuning) comes from the plug-in's own analysis, as it does now.
Gate: `plugin/test.sh` face test, plus the plug-in face rendered at default and Advanced.

### §3 result
The plug-in draws FaceplateFace (plugin/ui/PluginFace.swift). Readout = the instance's own reading (top 3, BPM before ×2/÷2,
tuning, notes heard, pin, level meter). Hidden in a host (FaceSurface.plugin): page arrows / SHOW IN FINDER (no file),
Open Audio + FIND (the status line takes that row), HOLD, LISTEN, SETTINGS, MINI. COLOR = swatch menu; RECENT = downloaded
files (Finder); EXPORT MIDI = click saves + reveals, drag drops the .mid; chords drag as MIDI clips. View 512 x 750
(BKP_VIEW_W/H = FaceplateFace.pluginSize, checked); ADVANCED widens to 960 (VST3 resizeView, AAX SetViewSize, AU frame).
Gate: plugin/test.sh PASS both slices, face_test 145/145; renders in plugin-evidence/face-2026-11-20/.
Hand-off §3 → §4: DOWNLOAD wiring is the plug-in's DownloadSend + the app's PluginDownloadListener.

## §4 DOWNLOAD in the plug-in
Paste a link and press DOWNLOAD. The existing Swift downloader runs (no Python) and the file is named with BPM and key.
If a host's sandbox or process blocks the download, route it through the Beat Key app's listener, the same path SEND BPM uses. Write the choice here.
Outside Pro Tools, the file is saved and shown in Finder.

### §4 choice: through the app, always
The plug-in never downloads in the host. yt-dlp, deno, ffmpeg and the saved YouTube login are the app's; Logic's AU
service is sandboxed and Pro Tools owns its process. DOWNLOAD posts `com.jshriver.orion.download` (PluginDownload.swift),
the app's PluginDownloadListener runs the Swift downloader, names the file with BPM + key, then PTSL-imports or reveals it.
Same route as SEND BPM (launches the app if needed, pings, posts). A second press while one runs is refused with a line.

## §5 Import into Pro Tools (PTSL CId_Import)
ImportType IType_Audio, AudioData with: file_list = the downloaded file; audio_operations = ConvertAudio; destination = MD_NewTrack or MD_ClipList; location = ML_Selection (edit cursor), ML_SessionStart, ML_SongStart or ML_Spot (with SpotLocationData).
- The menu next to DOWNLOAD shows those choices plus the recent picks as history. Nothing is pre-selected and nothing is applied without J's click.
- The request is unit-tested by its encoded bytes. Live Pro Tools test steps are listed in §8.
- PTSL not running or not enabled: the face shows one plain line saying so and saves the file.

### §5 result
PTSLImport.body / run (app/Sources/Orion/DAWSend/PTSLImport.swift); field names checked against PTSL.proto (SDK 2026.04,
~/dev/ProTools SDK/stem-bouncer/pt_stems/proto). Tests: request bytes for all five placements + command id 2; a fake PTSL
server end to end. Menu: opens above DOWNLOAD in Pro Tools only; RECENT picks listed (DownloadHistory), nothing pre-selected.
Not provable without Pro Tools: that `destination_path` is the converted-file folder and that Clip List takes MLocation_None (§8 list).

## §6 Error logging (house kit rule)
Every failure (downloader, import, PTSL connect, app-listener hand-off) is written to `~/Library/Logs/Beat Key/beatkey.log` with source "plugin" and the host name. This is the same log the app writes and the same log the app's REPORT button sends. The plug-in also shows a short status line.
Unit tests cover that each failure path writes one log line.

### §6 result
One line each in beatkey.log, `[plugin host=<host>] <source>: ...`: download / analyze / login / Downloads folder (app,
source download), PTSL connect, PTSL import (app), bad or busy request and every plug-in hand-off failure (app-listener),
face load (bkp_view_create). Tests: PluginDownloadTests (app) and face_test 5b (plug-in). The app's own sink no longer
copies the line a second time. Plug-in REPORT now attaches beatkey.log beside plugin.log.

## §7 Gates, evidence, merge
- Gates green: swift tests, core tests, `plugin/validate.sh`, `plugin/test.sh`.
- Evidence in `docs/plans/plugin-evidence/face-2026-11-20/`: app and plug-in renders side by side (default and Advanced), with the DOWNLOAD menu open.
- Merge to main and push. VERSION, publish and installs are untouched.

## §8 Build and Sofia check (no MBP GUI)
- Bump VERSION by +1 and run the full `app/build.sh` (PACE signing, notarize).
- Install on Sofia by drag-copy. Check the app face there with screenshots, then auval and pluginval on our own bundles only.
- Pro Tools on Sofia is blocked on J's helper password [SUPERSEDED 2026-11-20: no iLok on Sofia; the test ran on Studio D]. Write the live test list for that: AAX load, DOWNLOAD → New Track at cursor, Clip List, Spot, and AudioSuite.
- PICKUP gets the one J line: `! bash ~/dev/beatkey/tools/publish.sh`. [CLOSED 2026-11-20: 0.1.80 published 11:18, 0.1.81 published 13:02]

### §7-§8 results
Gates green on the merged code (swift 784/0, core 268/0, plugin/test.sh PASS, plugin/validate.sh PASS); merged 7c76c2a, pushed;
worktrees removed. 0.1.80 built (notarized, PACE-signed AAX). Sofia: installed by drag-copy, auval PASS both AUs, app face drawn
(evidence sofia/). Not run: pluginval on Sofia (not installed there), Pro Tools (helper password) [SUPERSEDED 2026-11-20: Pro Tools ran on Studio D].

### §8 Pro Tools live test list (Sofia, after J types the helper password once) [SUPERSEDED 2026-11-20: no iLok on Sofia; items 1-5, 7, 8 ran on Studio D (PT 2025.6.1) 12:26-12:57 and passed after fix 19a4bd7 (0.1.81); items 6 (PTSL off) and 9 (REPORT) not run; evidence docs/plans/plugin-evidence/protools-studio-d-2026-11-20/]
1. AAX load: insert Beat Key on an audio track. The face is the app window's (512 x 750); play a beat: key + BPM show.
2. ADVANCED: the window widens to 960 and back (AAX SetViewSize).
3. DOWNLOAD → New Track at Cursor: paste a YouTube link, DOWNLOAD, pick it. A new track at the edit cursor, file named with BPM + key, in the session's Audio Files.
4. DOWNLOAD → Clip List: the clip is in the Clip List, no new track (checks MLocation_None is accepted).
5. DOWNLOAD → New Track, Spot at Cursor, then Session Start and Song Start: each lands where named.
6. PTSL off / Pro Tools without a session: the status line says so, the file is saved; one beatkey.log line ptsl-connect / ptsl-import with host=Pro Tools.
7. RECENT in the menu lists the last picks; nothing is pre-selected on the next press.
8. AudioSuite Analyze on a clip: the face reads it ("SELECT A CLIP, THEN PRESS ANALYZE" before).
9. REPORT: Mail opens with plugin.log and beatkey.log attached.

## §9 Morning hand-off
`PICKUP.md` CURRENT STATE says what's built, what's verified with proof, and the one or two things only J can do (publish; Pro Tools password on Sofia [SUPERSEDED 2026-11-20: no iLok on Sofia; Pro Tools tested on Studio D; publish CLOSED, 0.1.81 public 13:02]). Nothing else.

## Rules (in every agent brief)
- No GUI, DAW, auval -a, scans or browsers on the MBP. Web lookups run only on Sofia via ssh-rc. No WebSearch/WebFetch tools.
- Never touch Studio D/E/F. Never restart Sofia. Trash, never `rm`.
- Agents never alert J or contact him. If blocked, write it into PICKUP and move on to the next step.
- Work in a git worktree off main; merge only with every gate green.
