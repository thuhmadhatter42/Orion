# Beat Key plug-in — TOC (plan: plugin-2026-11-19.md)

Read once before step 1: §V (J's words), §L (licence), §A (architecture), §S (the two buttons). J's open answers: §Q (work goes ahead on the defaults).
Steps 3-6 (core) and 7-8 (shims) can run side by side. Steps 9-11 and 16 touch `app/`: after the finish plan's app edits are merged.

- [x] 1. Read plan, preflight → §1
- [x] 2. Freeze Python goldens → §2
- [x] 3. Core skeleton and ring → §3
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

**2 → 3 (2026-11-19).** The Python outputs are frozen.
- `tools/parity/make_goldens.py` + `tools/parity/smoke_set.json`. It runs `bpm.py`'s and `tempocnn_np.py`'s own functions layer by layer, then `analyze_full` once more and refuses unless both say the same.
- `core/test/golden/` (2.8 MB, no audio): `manifest.json` (100 rows = 40 key-bench + 40 bpm-bench + 20 smoke; 99 distinct clips, the last smoke clip is a bench file on purpose), `files/` (99: key top-3 with %, 24 scores, pcp12, tuning, chroma; TempoCNN class per patch, global / 0.1 / refined BPM), `stream/` (20: `LiveAnalyzer` events, fed 0.5 s at a time like `--stream`), `layers/` (5 clips: HPCP frames, peaks, mel bands, CNN output, the resampled signals' edges).
- Done test met: a second run reproduced all 161 files byte for byte (`--check`: "CHECK OK: 161 files, byte for byte", 02:21).
- The smoke set did not exist; it is now 20 ffmpeg recipes over bench audio: 48 / 96 / 88.2 / 32 / 22.05 / 11.025 kHz, mono, 3 s / 5 s / 11.5 s, 20 s of digital silence, a 5 s gap, +30 and -17 cents, two songs back to back, -32 dB and -70 dB, one mp3 as it is. The bench files are all 44.1 kHz stereo mp3 of 120 s, so only the smoke set exercises the 44.1 kHz resampler.
- Found while freezing: the first try at the done test FAILED on 2 files. The reference is random on digital silence (essentia's FrameCutter adds clock-seeded noise to silent frames), so a TempoCNN patch made only of silence gets a different class every run. Those patches are now written as `null` ("noise_only"); a file's BPM is frozen only when the real patches decide the vote whatever the silent ones say ("decided"). This is not only a smoke-set case: `bpm-bench/4703149` ends in 50 s of digital silence (7 of its 19 patches). Counts: 1636 patches, 9 undefined; 98 of 99 clips have a defined BPM (the one without is the 20 s silence clip).
- The core's parity runner reads mono float32 PCM, not audio files: `<work>/pcm/<id>.f32` (1.9 GB, outside the repo). To make it again: `bin/python/bin/python3 tools/parity/make_goldens.py --check --work <folder> [--bench-root <checkout with the bench audio>/docs/research --ffmpeg-bin <that checkout>/bin]`. Another ffmpeg version gives other smoke clips; the tools refuse on the sha256 mismatch instead of comparing the wrong audio.
Next: §3 builds the core skeleton against these files.

**3 → 4 (2026-11-19).** The core exists and its own gate is green on both slices.
- `core/include/beatkey.h`: the whole C API. Bring-up (`bk_load_weights`, `bk_ready`), whole clip (`bk_analyze_buffer`), live (`bk_analyzer_create / destroy / push / push_channels / snapshot / new_song`), the log (`bk_log*`), `bk_version`. Rigid bring-up: nothing analyzes before the weights load; there is no key-only mode.
- `core/src/`, one owner per behaviour: `ring.h` (lock-free single-producer ring: takes what fits, drops and counts the rest, never waits) · `log.{h,cpp}` (`~/Library/Logs/Beat Key/plugin.log`, 1 MB roll, real home from the password database, mirrored to os_log, `$BEATKEY_LOG_DIR` for tests) · `tempocnn.cpp` (weights loader + network) · `np.h` (numpy / CPython sum orders and rounding) · `fft` · `resample` · `hpcp` · `key` (with the tuning estimate and the retune rule, as in `bpm.py`) · `mel` · `refine` · `boundary` · `live` · `file` · `worker` · `sane.h` (what counts as "not audio") · `error.h` · `api.cpp` (argument checks, error → code + sentence + log line). Inside, anything that cannot go on throws `bk::Error`; nothing crosses the C API and the audio-thread path runs no code that can throw.
- Weights: `models/deeptemp-k16-3.bkw` (1,282,846 bytes) from the `.npz` by `core/tools/make_weights.py`; CC BY-NC-SA, a separate file, never compiled in. The loader refuses garbage, a cut-short file, trailing bytes, a wrong shape, a non-number, a missing file (each tested).
- `core/build.sh`: universal objects + `build.noindex/libbeatkey.a`, macOS 12.0 minimum, `-Wall -Wextra -Werror`, hidden visibility, `-ffp-contract=off`, plain x86_64 (no AVX flags). `core/test.sh`: header compiles as C and C++, `.bkw` matches the `.npz`, then `core_test` under the tripwire dylib on arm64 and on x86_64 (`arch -x86_64`). Result: **246 checks, 0 failed, on each slice**. The tripwire shows 0 allocations and 0 locks on the thread that plays the audio thread, for `Ring::push` and for the real `bk_analyzer_push_channels` path; the tripwire itself is proven to count.
- The first build compiled clean. Two test faults were mine, not the core's: the tripwire's self-check was optimised away by the compiler (now a `volatile` pointer), and the live test's pacing depended on machine speed (it now waits for the worker chunk by chunk).
- Written ahead of their steps because `api.cpp` links them: the key, tempo and streaming code. Their gates are steps 4-6.
Next: §4 gates the key half against the goldens.
