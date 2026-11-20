# Overnight plan 2026-11-20: plug-in face = app window + DOWNLOAD into Pro Tools

J's asks (2026-11-19 17:19 and 01:30): the plug-in looks like the app window (his screenshot of the Faceplate). A YouTube beat downloads straight into Pro Tools. Work all night. Tomorrow J should only have to say "thanks, it's sick".
J's placement answer: "keep the history, but not active". The DOWNLOAD menu lists recent picks, nothing is pre-selected, and J picks every time.
Checklist: `overnight-2026-11-20-TOC.md`. Work it in order, tick each step, and write the hand-off line under each step.

## §1 Recon (read only)
Read `PICKUP.md`, `docs/plans/plugin-2026-11-19.md`, `plugin/ui/*.swift`, `app/Sources/Orion/Faceplate/*`, `app/Sources/BeatKeyShared/*`, `app/Sources/Orion/DAWSend/PTSLClient.swift` and the app downloader.
List every Faceplate control, and for each one say whether it can work inside a plug-in host (AU, VST3, AAX, AudioSuite). Write the table into §1 of this file.

## §2 One face, shared
Move the Faceplate views into `BeatKeyShared` behind a small protocol: the model and actions the face needs.
The app and the plug-in both render that same view tree. The app keeps its behaviour; it is a refactor only.
Gate: swift tests are green, and the app face render is pixel-identical to before (MarketingRenderTests).

## §3 Plug-in uses the shared face
`plugin/ui` FaceModel/FaceBridge implement the protocol. Controls that can't work in a host are hidden, not left dead; list them.
The plug-in readout (key, BPM, top 3, notes heard, tuning) comes from the plug-in's own analysis, as it does now.
Gate: `plugin/test.sh` face test, plus the plug-in face rendered at default and Advanced.

## §4 DOWNLOAD in the plug-in
Paste a link and press DOWNLOAD. The existing Swift downloader runs (no Python) and the file is named with BPM and key.
If a host's sandbox or process blocks the download, route it through the Beat Key app's listener, the same path SEND BPM uses. Write the choice here.
Outside Pro Tools, the file is saved and shown in Finder.

## §5 Import into Pro Tools (PTSL CId_Import)
ImportType IType_Audio, AudioData with: file_list = the downloaded file; audio_operations = ConvertAudio; destination = MD_NewTrack or MD_ClipList; location = ML_Selection (edit cursor), ML_SessionStart, ML_SongStart or ML_Spot (with SpotLocationData).
- The menu next to DOWNLOAD shows those choices plus the recent picks as history. Nothing is pre-selected and nothing is applied without J's click.
- The request is unit-tested by its encoded bytes. Live Pro Tools test steps are listed in §8.
- PTSL not running or not enabled: the face shows one plain line saying so and saves the file.

## §6 Error logging (house kit rule)
Every failure (downloader, import, PTSL connect, app-listener hand-off) is written to `~/Library/Logs/Beat Key/beatkey.log` with source "plugin" and the host name. This is the same log the app writes and the same log the app's REPORT button sends. The plug-in also shows a short status line.
Unit tests cover that each failure path writes one log line.

## §7 Gates, evidence, merge
- Gates green: swift tests, core tests, `plugin/validate.sh`, `plugin/test.sh`.
- Evidence in `docs/plans/plugin-evidence/face-2026-11-20/`: app and plug-in renders side by side (default and Advanced), with the DOWNLOAD menu open.
- Merge to main and push. VERSION, publish and installs are untouched.

## §8 Build and Sofia check (no MBP GUI)
- Bump VERSION by +1 and run the full `app/build.sh` (PACE signing, notarize).
- Install on Sofia by drag-copy. Check the app face there with screenshots, then auval and pluginval on our own bundles only.
- Pro Tools on Sofia is blocked on J's helper password. Write the live test list for that: AAX load, DOWNLOAD → New Track at cursor, Clip List, Spot, and AudioSuite.
- PICKUP gets the one J line: `! bash ~/dev/beatkey/tools/publish.sh`.

## §9 Morning hand-off
`PICKUP.md` CURRENT STATE says what's built, what's verified with proof, and the one or two things only J can do (publish; Pro Tools password on Sofia). Nothing else.

## Rules (in every agent brief)
- No GUI, DAW, auval -a, scans or browsers on the MBP. Web lookups run only on Sofia via ssh-rc. No WebSearch/WebFetch tools.
- Never touch Studio D/E/F. Never restart Sofia. Trash, never `rm`.
- Agents never alert J or contact him. If blocked, write it into PICKUP and move on to the next step.
- Work in a git worktree off main; merge only with every gate green.
