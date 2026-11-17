# Beat Key Help audit 2026-11-17 03:39 (0.1.73, Sofia live + code)
Help = hover-tip mode only (app/Sources/Orion/Help.swift; HELP chip FaceplateView.swift:335, PocketView.swift:133; View > Help Mode OrionApp.swift:92). Shots: scratchpad help-audit/ (session 304faf5d).
1. Help menu "Beat Key Help" is enabled and pops "Help isn't available for Beat Key." (no help book; confirmed live, m-helpitem2.png). Worst.
2. Help off at launch; chip dim; Help Mode lives under View, not Help.
3. LOG IN TO YOUTUBE shows the DOWNLOAD tip (FaceplateView.swift:287, PocketView.swift:217) — code only.
4. Paging arrows ‹ › have no tip (PocketView.swift:1105-1107, 1237) — code only.
5. Settings, permissions guide, Doctor have no help layer — code only.
6. KEYBOARD tip omits Z/X octave keys (Help.swift ~49 vs PlayToFind.swift:46-58); AUTO-TUNE tip says ⇧⌘A, menu is ⌃⌥⌘A (AutoTuneSend.swift:90). Confirmed live.
7. Readout panel ("Drop a beat", KEY/BPM area) has no tip (live).
8. Tip cards cover neighbouring buttons: DOWNLOAD over FIND KEY/BPM, LINK over LISTEN (live).
Status: awaiting J's go to fix.
