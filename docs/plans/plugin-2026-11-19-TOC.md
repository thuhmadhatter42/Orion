# Beat Key plug-in — TOC (plan: plugin-2026-11-19.md)

Read once before step 1: §V (J's words), §L (licence), §A (architecture), §S (the two buttons). J's open answers: §Q (work goes ahead on the defaults).
Steps 3-6 (core) and 7-8 (shims) can run side by side. Steps 9-11 and 16 touch `app/`: after the finish plan's app edits are merged.

- [x] 1. Read plan, preflight → §1
- [ ] 2. Freeze Python goldens → §2
- [ ] 3. Core skeleton and ring → §3
- [ ] 4. Core key parity → §4
- [ ] 5. Core BPM parity → §5
- [ ] 6. Core streaming and worker → §6
- [ ] 7. Plug-in instance layer → §7
- [ ] 8. VST3 + AU, validator gate → §8
- [ ] 9. SwiftUI face, house kit → §9
- [ ] 10. SEND AUTO-TUNE button → §10
- [ ] 11. SEND BPM through app → §11
- [ ] 12. Milestone A, J's check → §12
- [ ] 13. AAX Native, signed → §13
- [ ] 14. AudioSuite Analyze pass → §14
- [ ] 15. MIDI variant → §15
- [ ] 16. Installer and plug-in updates → §16
- [ ] 17. Manual, What's New, licences → §17
- [ ] 18. Ship gate, J publishes → §18
- [ ] 19. App onto the core → §19
- [ ] 20. Close and save → §20

## Hand-offs (one per finished step: what it produced, what is next)

**1 → 2 (2026-11-19).** Preflight on the MacBook Pro, branch `worktree-agent-aadaf41124b37be8f`:
- `git status` clean. Finish plan (`finish-2026-11-19-TOC.md`): nothing ticked yet, so §9-§11 and §16 here still wait on its `app/` edits. `core/` and `tools/parity/` are new and touch nothing of `app/`.
- On disk: AAX SDK 2.9.0 (`~/dev/ProTools SDK/AAX/sdk/aax-sdk-2-9-0`), `~/dev/JUCE`, `/Applications/pluginval.app`, `/usr/bin/auval`, AAX validator archive (`aax-validator-dsh-2024-6-0-138bab0d-mac-arm64.tar.gz`, arm64 only), Xcode 27.2 (Apple clang 21.0.0, Swift 6.4.2). macOS 27.2.1, M1 Pro, 10 cores.
- Hosts on the MacBook Pro: Ableton Live 10 Suite, Logic Pro 12.4, Artemis, and also Pro Tools 2026.11 + 2026.4.1 (the plan said Pro Tools is on Sofia only; it is on both). Sofia not checked from this step.
- Artemis `plugin/`: read fully `MODULE.md`, `build.sh`, `test.sh`, `test/tripwire.c`, `test/harness.{h,c}`, `core/recall_log.{h,c}` (the patterns steps 3-6 reuse: universal objects, `-Werror`, tripwire dylib, log writer with the real home from the password database). The three shim sources were opened, not studied line by line: that read belongs to whoever does §7-§8.
- The Python reference is the bundled one (`bin/python`, Python 3.11.17, numpy 1.26.4, our essentia 2.1b6.dev1110 without TensorFlow: so `tempocnn_np.py` and `decode_ffmpeg` are the reference paths, as in the shipped app).
- Looked up in essentia's source at the pinned commit 77a6a954 (the plan's §4 "look it up before vendoring"): `Resample` default `quality` is **1 = libsamplerate SRC_SINC_MEDIUM_QUALITY** (not best), run as one `src_simple` call per array; libsamplerate 0.2.2, BSD-2-Clause. FFT is FFTW 3.3.10 single precision, `FFTW_ESTIMATE`. The streaming FrameCutter's silent-frame noise is uniform ±1e-10 from a time-seeded MT19937, so the reference itself is random on digital silence.
- The "20-file smoke set" did not exist anywhere. Step 2 defines it (`tools/parity/smoke_set.json`): 20 clips made from bench audio with ffmpeg (other sample rates, mono, short, silence, detuned, back-to-back, quiet).
Next: §2 writes `tools/parity/make_goldens.py` and freezes the outputs into `core/test/golden/`.
