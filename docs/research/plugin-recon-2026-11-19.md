# Beat Key plug-in version: recon (2026-11-19, read-only, nothing in the repo changed)

Evidence tags: **[doc]** = a page fetched this session (URL given); **[repo]** = read in ~/dev/beat_dl this session; **[forum]** = community post, not authoritative; **[unverified]** = could not confirm, must be checked before building.

## 0. Findings that change the plan

1. Antares already sells exactly the "key to Auto-Tune" plug-in: Auto-Key 2, AAX Native / AU / VST3, bundled free with Auto-Tune Pro 11 at one retailer. [doc: https://www.sweetwater.com/store/detail/AutoKey2--antares-auto-key-2-automatic-key-and-scale-detection-plug-in , https://www.pluginboutique.com/product/81-Bundles/39-Effects-Bundles/14831-AutoTune-Pro-11-FREE-AutoKey-2 , https://www.antarestech.com/blog/tutorial-auto-key-analyzing-key-scale]. Beat Key's plug-in edge would be BPM, top-3 keys with confidence, tuning in cents, the pin, MIDI out and the Beat Key app link, not "a key detector in a DAW".
2. Beat Key is AGPL-3.0 because it uses Essentia (AGPL); the TempoCNN weights are CC BY-NC-SA 4.0 ("Beat Key must stay free"). [repo: THIRD-PARTY-LICENSES.md, models/README.md]. Any plug-in that reuses that engine inherits both: AGPL source offer, free of charge. This decides the JUCE licence route (section 2).
3. The analyzer is Python + numpy + a custom Essentia wheel (312 MB `vendor/`). [repo: `du -sh vendor`]. It cannot go inside a plug-in. A native port is required (section 2c).
4. PTSL (Pro Tools scripting) cannot set tempo or key rulers; the app already types them via Accessibility. [repo: ProToolsDriver.swift header]. A Pro Tools plug-in cannot set the session tempo/key either (no host API found); it can only show values, write the Auto-Tune handoff, or output MIDI.

## 1. Formats J needs: cost, licence, signing

| Format | Host | SDK licence | Cost | Signing / extra |
|---|---|---|---|---|
| VST3 | Ableton Live (Mac: VST3 and AU both listed in the Live 12 manual) | MIT since SDK 3.8 (Oct 2025). "No need to sign any documents." GPLv3 and the old proprietary licence are no longer offered. "VST" name/logo optional; if used, follow Steinberg trademark rules. [doc: https://steinbergmedia.github.io/vst3_dev_portal/pages/VST+3+Licensing/VST3+License , https://www.soundonsound.com/news/steinberg-adopt-mit-license-vst3] | $0 | Apple Developer ID sign + notarize (J's paid membership, cert `Developer ID Application: J Shriver (9WTFGV63S2)` per CLAUDE.md). |
| AU | Artemis, Logic, Live | No fee (Apple SDK in Xcode). AUv2 `.component` is what J's plug-in policy keeps ("every AU/.component"). AUv3 = an app extension inside a container app. [Apple page https://developer.apple.com/documentation/audiotoolbox/audio_unit_v3_plug-ins did not render for the fetcher; the AUv3 = app-extension description is from general knowledge: unverified] | $0 | Developer ID + notarize. Ableton lists AUv3 (64-bit, from Live 11.2) as supported [doc: https://help.ableton.com/hc/en-us/articles/5937501570460 via search snippet; page itself returned 403]. |
| AAX Native | Pro Tools | Avid AAX SDK behind a click-through licence; "contact audiosdk@avid.com" for commercial tools and licence. Avid account + iLok account needed to run Pro Tools for AAX testing. [doc: https://developer.avid.com/aax/]. SDK 2.8.0 source banner (July 2024): "subject to commercial or open-source licensing ... may also use this code under the terms of the GPL v3", and "By using the AAX SDK, you agree to the terms of both the Avid AAX SDK License Agreement and Avid Privacy Policy." [forum quoting the banner: https://forum.juce.com/t/aax-open-source-release/44017] | SDK fee not stated on Avid's page. | **Mandatory PACE signing**: plug-ins "must be signed with PACE's AAX Code Signing Tools" to load in Pro Tools [doc: https://paceap.com/juce/]. Process: email Avid, subject "PACE AAX Code Signing Tools Request" (company, admin contact, website, plug-in summary, Avid Developer email); Avid vets you, forwards to PACE; "You'll need an iLok USB to safely store the signing certificate"; PACE also offers a cloud signing service with no physical iLok [doc: https://paceap.com/getting-started-with-aax-code-signing-for-pro-tools-plugins/]. JUCE forum: a physical iLok is needed to sign for distribution [forum: https://forum.juce.com/t/signing-aax-plugin-do-i-need-the-ilok-usb/48016]. Unsigned builds only load in the special "Pro Tools Developer" build [forum]. **Costs: not published on any official page I could fetch**; forum posts say Avid registration gets you a free PACE developer plan (otherwise about $500/yr) and you buy the iLok yourself [forum: forum.hise.audio posts, unverified]. Ask Avid/PACE for the figure. |
| CLAP | not needed | - | - | Ableton, Logic, Pro Tools, FL do not support it [doc: https://www.antarestech.com/blog/vst3-au-aax-clap-plugin-formats-2026, vendor page]. Skip. |

Hosts only take their own format: Pro Tools = AAX only, Logic = AU only, VST3/AU never appear in Pro Tools [doc, same Antares page]. So J needs all three: AAX (Pro Tools), VST3 (Ableton), AU (Artemis).

Sofia (the Pro Tools rig) is a 2013 Intel Mac Pro on macOS 12.7.6 [CLAUDE.md]. Builds must be universal (x86_64 + arm64) with a macOS 12 deployment target; whether the current AAX SDK still builds for that is [unverified], read the SDK release notes after the click-through.

## 2. Architecture options

Reusable inventory [repo]:
- `bpm.py` (924 lines): key = Essentia HPCP front end (frame 4096/hop 4096, 36 bins, whitening, retune at the track's own A when 5+ cents off) + `bgate` profiles over 24 keys + segment agreement for confidence; BPM = TempoCNN (11025 Hz, 40 mel x 256-frame patches) + `refine_bpm` (0.01 BPM); `LiveAnalyzer` = the streaming version (12 s tempo window, 30 s key window, reading every 2 s, silence/boundary rules); `BoundaryDetector` (new song with no pause).
- `tempocnn_np.py` (135 lines): the whole network in numpy: 12 conv layers (16-128 channels, kernel 3 and 5) + batchnorm + pooling + 1x1 head; weights in `models/deeptemp-k16-3.npz` (a few MB; 12-layer, max 128 channels). Small enough for a plain C++ port.
- Swift side: `Result`/`Reading.swift` (key spelling, tuning meter, TempoFactor), `KeySpelling.swift`, `AutoTuneSend.swift` (writes `~/Music/Audio Music Apps/Temp/Auto-Key.handoff`, KeyClass 0-11 + KeyType 0/1 + ReferencePitch + TempoBPM), `MidiExport.swift`, `Harmony.swift`, `Broadcast.swift` (+ `docs/protocol-beatkey-broadcast.md`).

Options:

**(a) Native Swift/C++ AUv3 + separate VST3 + AAX.** Three bindings by hand: AUv3 (Swift/ObjC AUAudioUnit), VST3 (C++ SDK, MIT), AAX (C++ SDK, Avid agreement). Three UIs, three state/parameter systems. Maximum control, most work; the "same engine three ways" burden is on J. Not recommended.

**(b) JUCE: one codebase to AU / VST3 / AAX** (JUCE also does AUv3, LV2, standalone). Licences [doc: https://juce.com/get-juce/ , https://juce.com/legal/juce-9-licence/ (JUCE 9; the 8 page 404s)]: Starter free up to $20k revenue; Indie $40/user/month or $800 perpetual up to $300k; Pro $175/month or $3,500 perpetual, unlimited; Educational free (no commercial use). Dual-licensed AGPLv3 as an alternative. The JUCE 9 licence page says you must not do anything that subjects the framework to an open-source licence, so a **Starter/Indie/Pro build cannot carry Beat Key's AGPL engine**; Beat Key's engine is AGPL anyway. Therefore the consistent route is **JUCE under AGPLv3 + Essentia/our port under AGPL + VST3 (MIT) + AAX**. The open question is AAX: the SDK carries a GPLv3 alternative (banner above) but the Avid agreement still applies, and one JUCE forum poster says "for AAX, AUv3, VST2 and iOS you cannot use the GPL based clause" and shipped AAX under the JUCE personal licence with the rest GPL [forum: https://forum.juce.com/t/juce8-license-and-open-source-projects/60987 , https://forum.juce.com/t/help-understanding-licenses/69205; not authoritative]. **Not settled by any official page: ask sales@juce.com and audiosdk@avid.com in writing before building the AAX target.** Even with a free JUCE tier, revenue is $0 (Beat Key is free), so Starter would be $0 if the AGPL conflict were not there.

**(c) iPlug2.** Targets CLAP, VST2, VST3, AUv2, AUv3, AAX (Native), WAM; "liberal zlib-like licence", usable in closed-source projects [doc: https://iplug2.github.io/]. The page gives no AAX detail; the Avid SDK terms and PACE signing apply regardless of framework. Smaller community, thinner GUI toolkit than JUCE; zlib licence sits fine under an AGPL product. Viable fallback if JUCE's licence/AAX answer is bad.

**Recommendation: (b) JUCE, with the analysis engine as its own C++ library ("BeatKeyCore") that does not depend on JUCE.** Reasons: JUCE's plug-in wrappers are the part that is expensive to hand-write; the engine is where Beat Key's value is and must be shared.

### Can the analyzer run in a plug-in?

- Not as-is. Python/numpy/Essentia wheel cannot ship inside a plug-in bundle (size, signing every dylib, no GIL-safe realtime, macOS 12 Intel + arm64).
- Realtime rule (general audio-plug-in practice; each host API doc says the same, not re-fetched): the audio callback must not allocate, lock or do FFT/CNN work of this size. Pattern: audio thread only downmixes to mono, resamples to 44.1 kHz (lock-free ring buffer), and a worker thread runs the analysis and posts the result back. The existing `LiveAnalyzer.push` shape (chunk in, a reading every 2 s) already matches that.
- Port plan [repo-derived]: HPCP + bgate + retune + confidence = about 40 lines of numpy plus Essentia's HPCP/peaks front end (Essentia is C++, so link its C++ library directly under AGPL, or re-implement the hann/FFT/peaks/HPCP chain); TempoCNN = 12 convs, plain C++ (weights from the `.npz`, converted to a header or binary blob; stays CC BY-NC-SA, attribution kept); `refine_bpm`, `BoundaryDetector`, silence rules = numpy ports. **Parity gate: the C++ core must reproduce the Python outputs on the existing key-bench / bpm-bench sets** (`docs/research/key-bench`, `bpm-bench`; GS+ 85.1/79.5 % key, J's 243 Pro Tools sessions BPM) before it is trusted. CPU cost of one TempoCNN pass in C++ is not measured: measure it in milestone 1.
- Because the same core can feed the Mac app, the app's Python runtime could later be retired. That is the "final architecture"; do not build a plug-in-only engine.

### Existing Broadcast protocol as a plug-in <-> app bridge

`com.jshriver.orion.reading` / `.request` over `DistributedNotificationCenter`; payload = source, songID, key, bpm, confidence; no names [repo]. Useful for an optional "follow the app" mode (plug-in shows/forwards what Beat Key is hearing, so Listen of any app drives a track-less plug-in). It is not a substitute for in-plug-in analysis: it carries one global reading, not "the track this plug-in sits on", and does nothing when the app is closed ("nothing is posted and nobody answers" [repo]). Whether a sandboxed host (Logic's AUv3, any sandboxed AUv3 extension) may send/receive distributed notifications or write the Auto-Tune handoff file is [unverified]; test per host. Prefer the plug-in analyzing on its own and the broadcast being optional.

## 3. What the plug-in does in the DAW, and host limits

- **Analyze its own track**: a real-time effect (AAX Native, VST3, AU) receives only the audio passing through at that moment (SoS: real-time AAX plug-ins "respond only to the audio passing through them" and have "the least contextual awareness") [doc: https://www.soundonsound.com/techniques/pro-tools-ara-or-aax-processing-audio]. It has no file path, clip, or song identity: it must be played, and it needs about 12 s for BPM plus longer for a confident key (the app's own windows: 12 s tempo, 30 s key [repo]). Looped sections and silence gaps behave as in Listen. This is the same behaviour as Listen, minus the song-title watcher.
- **Pro Tools offline (AudioSuite)**: AudioSuite processes whole clips, "ideal for ... full-clip analysis" [doc, SoS above]. AAX SDK: an optional AudioSuite "Analysis pass" gives the plug-in "access to the incoming audio before the actual Render pass starts", random access to the whole selection, and needs the host-processor entry (`AAX_CHostProcessor`) [doc: https://learn-cdn.avid.com/AAX_SDK_2p1p1/Documentation/Doxygen/output/html/a00274.html, SDK 2.1.1 docs; check current SDK]. So the right Pro Tools UX is a second entry point in the same AAX binary: AudioSuite "Beat Key" analyzes the selected clip faster than real time, then shows the values / writes handoff. JUCE has no built-in AudioSuite host-processor support that I could confirm [forum: https://forum.juce.com/t/aax-offline-analyze-pass/15059 , https://forum.juce.com/t/aax-chostprocessor-support/28640: users report having to implement the Host Processor themselves]: that is custom AAX code, expect it to be the hardest single piece. ARA (whole-timeline access) arrived in Pro Tools end of 2022 (Melodyne first) but allows "only one ARA process ... on a track at a time" [doc, SoS]; not worth it for a read-only analyzer.
- **Ableton / other VST3 hosts**: real-time only as above. I found no doc showing Live hands a plug-in the clip's file; [unverified], do not promise it. The app's "Analyze Selection" (Remote Script) already covers clip-level analysis for Live.
- **Push to Auto-Tune**: the plug-in can write the same `Auto-Key.handoff` XML the app writes (`AutoTuneSend.contents`), so every Auto-Tune Pro instance with Auto Key Detection on takes the key [repo]. Same undocumented-by-Antares caveat as the app; plus host sandbox permission to write `~/Music/Audio Music Apps/Temp/` [unverified per host].
- **MIDI out**: AUv3 exposes a MIDI output block/names (general knowledge; Apple's page did not render: unverified). In VST3 and AAX, MIDI output is tied to instrument or MIDI-effect plug-in types, not an audio effect on an audio track: JUCE forum reports you need "Plugin Is Synth / MIDI Input / Output" for Pro Tools MIDI out, and that "MIDI FX flag on breaks AAX" [forum: https://forum.juce.com/t/midi-fx-doesnt-work-in-aax/45243 ; SoS search snippet]. Pro Tools added AAX MIDI-effect plug-ins in 2024.3 (routing within a track, between tracks, between plug-ins) [doc: https://www.mixonline.com/technology/pro-tools-2024-3-adds-new-ways-to-work-with-midi]; the article does not describe MIDI output from an audio-track insert. Practical consequence: plan **two plug-in types sharing one core: "Beat Key" (audio effect: analyze + display + Auto-Tune push) and "Beat Key MIDI" (MIDI effect/instrument: emits the chord/key notes or tempo-key meta)**. Per-host MIDI-out behaviour must be tested live on each of Pro Tools, Live, Artemis.
- **What a plug-in cannot do**: set the DAW's tempo/key (no host API found; the app's DAWSend drivers do this from outside; PTSL has no tempo/key commands [repo]). "Send to DAW" stays an app feature, or the plug-in talks to the app (Broadcast-style request) and asks the app to send.
- **Pro Tools guard** (existing app feature): not applicable inside Pro Tools; leave in the app.

## 4. Recommendation and step list ("$250 shoes")

Final architecture, first time: **BeatKeyCore (C++, no UI, no JUCE) + JUCE plug-in project (AU, VST3, AAX, standalone for tests) + the existing Mac app later switched to the same core.** Not a stand-in: no Python in the plug-in, no web wrapper, no "VST3 only first" engine that gets rewritten for AAX. Milestones are cuts of this same structure.

Gate 0 (before any code, answers only J/others can give; each is a written reply):
- G0.1 JUCE (sales@juce.com): may an AGPL-3.0 plug-in include AAX built with the Avid SDK? Which JUCE licence tier then? (official page does not say.)
- G0.2 Avid (audiosdk@avid.com): AAX SDK commercial/GPL terms for a free AGPL product; PACE signing cost; whether a free plug-in qualifies.
- G0.3 J: ship one plug-in or two (analyzer + MIDI)? (my default: two, one core.) Free/AGPL stays (non-commercial model licence).

Steps:
1. Parity spec: freeze Python outputs for every file in key-bench/bpm-bench + a 20-file smoke set as golden JSON. (gate for 2-4)
2. BeatKeyCore: HPCP/bgate/retune/confidence in C++; compare to goldens; then TempoCNN + refine_bpm; then LiveAnalyzer/silence/boundary. Benchmark CPU per reading on Sofia (Intel) and MBP. Add `VERSION`, error log, per house-kit SOP (~/dev/house-kit/SOP.md: logging, About, Report, update path).
3. JUCE shell, VST3 + AU (AUv2) first on the MBP: audio thread -> ring buffer -> worker -> UI (key top-3 + %, BPM x2/x0.5, tuning cents, pin). Test in Ableton and Artemis. Developer ID sign + notarize.
4. Auto-Tune push (handoff writer reused) and optional Broadcast "follow the app" mode; test host sandbox on each host.
5. AAX Native build: SDK click-through, Avid signing request, iLok + PACE signing in the build script; test in Pro Tools on Sofia (Developer build until signed). Intel + arm64.
6. AudioSuite analysis pass (AAX_CHostProcessor) for whole-clip analysis in Pro Tools.
7. MIDI plug-in variant (MIDI effect/instrument) per host test matrix.
8. Installer (.pkg like Beat Key), Sparkle-style update path, licences file, release `0.1.0`.
9. Optional: move the Mac app onto BeatKeyCore and retire the Python runtime (the same engine everywhere).

Open [unverified] items to settle during Gate 0/steps: Apple AUv3/midiOutputEventBlock docs (page did not render), AAX SDK macOS 12 / Intel target, per-host sandbox rights for the handoff file and distributed notifications, Live clip-file access, AAX MIDI-out behaviour on an audio track, PACE signing cost.

## Source list
- https://steinbergmedia.github.io/vst3_dev_portal/pages/VST+3+Licensing/VST3+License
- https://www.soundonsound.com/news/steinberg-adopt-mit-license-vst3
- https://developer.avid.com/aax/
- https://paceap.com/getting-started-with-aax-code-signing-for-pro-tools-plugins/
- https://paceap.com/juce/
- https://forum.juce.com/t/signing-aax-plugin-do-i-need-the-ilok-usb/48016
- https://forum.juce.com/t/aax-open-source-release/44017
- https://forum.juce.com/t/juce8-license-and-open-source-projects/60987
- https://juce.com/get-juce/ , https://juce.com/legal/juce-9-licence/
- https://iplug2.github.io/
- https://learn-cdn.avid.com/AAX_SDK_2p1p1/Documentation/Doxygen/output/html/a00274.html
- https://www.soundonsound.com/techniques/pro-tools-ara-or-aax-processing-audio
- https://www.mixonline.com/technology/pro-tools-2024-3-adds-new-ways-to-work-with-midi
- https://www.antarestech.com/blog/vst3-au-aax-clap-plugin-formats-2026
- https://www.sweetwater.com/store/detail/AutoKey2--antares-auto-key-2-automatic-key-and-scale-detection-plug-in
- https://help.ableton.com/hc/en-us/articles/5937501570460 (search snippet; page 403)
- https://developer.apple.com/documentation/audiotoolbox/audio_unit_v3_plug-ins (did not render)
