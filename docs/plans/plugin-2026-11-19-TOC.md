# Beat Key plug-in — TOC (plan: plugin-2026-11-19.md)

Read once before step 1: §V (J's words), §L (licence), §A (architecture), §S (the two buttons). J's open answers: §Q (work goes ahead on the defaults).
Steps 3-6 (core) and 7-8 (shims) can run side by side. Steps 9-11 and 16 touch `app/`: after the finish plan's app edits are merged.

- [x] 1. Read plan, preflight → §1
- [x] 2. Freeze Python goldens → §2
- [x] 3. Core skeleton and ring → §3
- [x] 4. Core key parity → §4
- [x] 5. Core BPM parity → §5
- [x] 6. Core streaming and worker → §6
- [x] 7. Plug-in instance layer → §7
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

**4 → 5 (2026-11-19).** The key half reproduces the Python outputs on every golden file.
- The gate is `sh core/parity.sh <pcm folder> [arm64|x86_64|both] [key] [tempo] [stream]`: it builds the core, runs `core/test/parity_dump.cpp` (the core on the frozen PCM, answers written in the goldens' shape; it judges nothing) and `core/test/parity.py` (standard-library Python; the A5 rules; exit 0 only on PARITY OK; `parity-report.json` beside the outputs).
- **Key parity: 99/99 clips = 100 % on the arm64 slice, 99/99 = 100 % on the x86_64 slice (Rosetta), 10/10 on Sofia's own Intel CPU (subset).** Per clip: the same three key names in the same order with the same percentages, the same retune decision, tuning within 0.5 cent. In fact tighter than the rule on every slice: tuning identical and chroma identical on 99/99, the same number of spectral peaks on 99/99, largest difference in any of the 24 key scores 2.6e-6. No tolerance was touched.
- By layer, on the five dumped clips (arm64): resampled 44.1 kHz and 11.025 kHz signals bit-identical; HPCP frames within 3.1e-4 of values up to 32; peaks within 2.6e-5 relative, same count in every frame.
- Resampler, looked up before vendoring as the step asks: essentia's `Resample` is libsamplerate `src_simple` at its default `quality` 1 = SRC_SINC_MEDIUM_QUALITY, ratio = a float division of the two rates. Vendored: `core/vendor/libsamplerate-0.2.2` (BSD-2-Clause, the tarball `essentia.sh` pins, unmodified files + our `config.h`; only the medium converter is built, the 9 MB best-quality table is not copied). **Its output is bit-identical to the reference on 99/99 clips at both rates**, on every slice. Licence recorded: `VENDOR.txt`, and the `THIRD-PARTY-LICENSES.md` row (its full text was already Appendix G).
- FFT: Accelerate vDSP in double (the plan's choice), not FFTW; the answers above are with it.
- Awkward parts copied on purpose (each is commented where it lives): zero-phase windowing, essentia's float arithmetic in peaks / whitening / HPCP, numpy's float32 means and pairwise sums, CPython's `round`, the float32 comparison with the 0.2 gate.
Next: §5 gates the tempo half and measures the time of a reading.

**5 → 6 (2026-11-19).** The tempo half reproduces the Python outputs on every golden file.
- **BPM parity: 99/99 clips = 100 % on the arm64 slice, 99/99 = 100 % on the x86_64 slice (Rosetta), 10/10 on Sofia's own Intel CPU (subset).** Per clip: the same TempoCNN class on every patch the reference defines (1627 of 1636; the other 9 are digital silence, random in the reference, step 2), the same global BPM, refined BPM within 0.01. Tighter than the rule: the refined BPM is identical on all 98 clips that have one (largest difference 0). No tolerance was touched.
- By layer, on the five dumped clips (arm64): mel bands within 4.3e-5 relative, CNN output (softmax) within 7.2e-7. Closest call in the whole set: one patch wins by 1.6e-4 (softmax units), about 200 times the largest CNN difference seen.
- Port notes: the mel front end is essentia's streaming FrameCutter + TensorflowInputTempoCNN rebuilt (frame count measured against essentia for 23 lengths: ceil(n / 512) + 1); the silent-frame noise is reproduced as a mechanism (clock-seeded Mersenne Twister, ±1e-10), including the reference's quirk that a silent first frame is noise alone; the network runs on Accelerate's sgemm; z-score and softmax use numpy's pairwise float32 sums; `refine_bpm` uses numpy's own `arange` fill rule.
- Sofia's CPU, confirmed as the plan asked: `Intel Xeon E5-2697 v2`, `machdep.cpu` lists AVX1.0 only (no AVX2). The x86_64 slice is plain x86_64 and ran there natively.
- Time, measured (and logged per reading by the worker: "... NN.N ms" in `plugin.log`):
  | Where | One whole clip (120 s of audio) | One live reading (key + BPM) | Live, share of one core in real time |
  |---|---|---|---|
  | MacBook Pro, arm64 slice (M1 Pro, load average about 4) | median 770 ms, worst 798 ms (80 clips) | median 80 ms, worst push 121 ms | 3.4 % |
  | MacBook Pro, x86_64 slice under Rosetta | median 1057 ms, worst 1194 ms (80 clips) | median 105 ms, worst push 130 ms | 4.4 % |
  | Sofia, x86_64 native (2013 Xeon, load average 5-6) | median 2141 ms, worst 2179 ms (4 clips) | median 214 ms, worst push 228 ms | 10.0 % |
  Sofia ran a subset: 10 clips (3 bench, 7 smoke) copied to a scratch folder under `/tmp` there, the thin x86_64 test binary run over ssh, the answers copied back and judged here (`parity.py --no-run --ids ...`): key 10/10, tempo 10/10, stream 7/7, resampler bit-identical on 10/10. The scratch folder was removed and checked gone. Nothing was installed on Sofia.
- Where the time goes in one live reading (MacBook Pro, profiled by stage): resampling the 12 s window 44.1 → 11.025 kHz with the reference's sinc converter is about 80 % (61 ms of ~75); the decimal BPM 9 ms; TempoCNN 1.5 ms; mel 1 ms; key under 1 ms. The resampler cannot be swapped without leaving parity.
Next: §6 gates the streaming port and soaks the worker.

**6 → 7 (2026-11-19).** The streaming port matches the Python events and the worker passed the soak.
- **Streaming parity: 20/20 smoke clips = 100 % on the arm64 slice, 20/20 = 100 % on the x86_64 slice (Rosetta), 7/7 on Sofia's own Intel CPU (subset).** The same events (reading / reset / boundary / silence / sound) at the same half-second chunks, 398 readings; in every reading the same keys and whole-number percentages, the same BPM string, the same seconds; refined BPM and tuning identical on 398/398; the three audio boundaries carry identical scores. Chroma, which A5 does not name, is held to one unit of its 3-decimal rounding: identical on 397 of 398 readings, one unit off on the other.
- `core/src/boundary.cpp` = `BoundaryDetector`, `core/src/live.cpp` = `LiveAnalyzer` (a rate other than 44.1 kHz is resampled chunk by chunk with a fresh converter, exactly as the reference does), `core/src/worker.cpp` = one thread per process for every analyzer + the snapshot (a seqlock: readers never block).
- **Soak (`sh core/soak.sh <pcm folder> 10`): PASS** on the tree as committed (03:02-03:13, load average 5-6). Four analyzers (44.1 / 48 / 96 / 48 kHz) fed real music in real time for 10 minutes: 298 / 239 / 239 / 235 readings, each equal to what `LiveAnalyzer` gives for the same audio fed directly; 0 frames dropped; heap in use 117.02 MB → 117.11 MB (+0.09 MB; 81 MB of it is the test's own music, so about 9 MB per analyzer); CPU 4.7 % of one core per analyzer; never more than 0.97 s of audio waiting; slowest reading 0.35 s.
- What the soak found first, and what changed (two failed runs before the pass):
  1. With a 4 s ring the soak FAILED twice: the Mac was busy (first a second job on 4+ cores, then a Time Machine backup and other agents' builds, load average 20-33) and the low-priority worker was starved for up to 6 s, so audio was dropped. Fix at the source: the ring now holds about 11 s (10 s rounded up to a power of two: 2 MB at 44.1 / 48 kHz) and is the ONLY place audio waits. The worker's second buffer ("pending") is gone; it takes one whole half-second per analyzer per visit, so analyzers take turns and a backlog is worked off in order.
  2. "No missed hop" is judged as: no audio dropped and every reading the audio calls for was made. How LATE the worker ever was is printed, not judged. An earlier passing 10-minute run (02:42, load average 33 at its start) was once 8.6 s behind and caught up; nothing was lost, same reading counts, heap +0.02 MB.
  3. The worker runs at macOS "utility" priority, the plan's "low priority" (`BK_WORKER_QOS` in `worker.cpp`, one constant). Measured side by side on the same busy Mac for 4 minutes: utility = up to 2.4 s behind, slowest reading 1.2 s; default priority = up to 0.8 s behind, slowest reading 0.14 s; both lost nothing. Left at utility; raising it is J's or the main session's call.
- `core/test.sh` covers the worker too (246 checks per slice): the snapshot equals what `LiveAnalyzer` says for the same chunks, the real `bk_analyzer_push_channels` path under the tripwire (0 allocations, 0 locks), new song, silence, garbage samples refused and counted (`refused_chunks`), overflow counted (`dropped_frames`) and logged, create / destroy in any order with the worker joined after the last instance.
- For §7 (the instance layer), from the core's side:
  1. The whole surface is `core/include/beatkey.h`. Link `core/build.noindex/libbeatkey.a` + `-framework Accelerate`. Call `bk_load_weights(<bundle>/Contents/Resources/deeptemp-k16-3.bkw)` once before the first `bk_analyzer_create`; without it create returns NULL with the sentence to show.
  2. The audio function calls `bk_analyzer_push_channels` (or `bk_analyzer_push` with its own downmix) and nothing else of the core. The face polls `bk_analyzer_snapshot` (cheap, lock-free); `song` / `reading_song` tell a stale reading from a current one.
  3. `bk_analyzer_destroy` of the LAST analyzer joins the worker thread (it can take as long as one reading, about 0.1-0.2 s). Each format's bundle links its own copy of the core, so a host with the AU and the VST3 both loaded has two workers; they share nothing but the log file.
  4. AudioSuite (§14) calls `bk_analyze_buffer`; it refuses samples that are not numbers or sit over +60 dB.
  5. Session state (pin, ×2 / ÷2, last reading) is the instance layer's: the core keeps none.
- Nothing blocks §7. Two things for the main session to know (neither is a blocker):
  1. At 48, 96 and 192 kHz a reading comes every 2.5 s, not 2 s: the reference's chunk arithmetic (each resampled half-second is 22049 samples, measured, so four of them fall just short of 2 s; at 44.1 and 88.2 kHz it is 22050 and the hop is 2 s). Parity keeps it.
  2. At rates other than 44.1 kHz the live path resamples each half-second on its own, so the converter starts cold twice a second. That is the reference's behaviour (`LiveAnalyzer` with `rate` set) and the goldens hold the core to it. A continuous resampler would be cleaner for a plug-in at 48 kHz, but it is a change to the reference first (bpm.py + new goldens), not a core-only change.

**7 → 8 (2026-11-19).** The instance layer exists and its gate is green on both slices.
- `plugin/shared/bkp.{h,cpp}`: `bkp_instance`, the one object every shim owns. Plain C API. It owns bring-up (`bk_load_weights` once, the analyzer for the host's rate, swapped on a rate change with the reading kept), THE audio function `bkp_process` (N in = N out, float or double, in place, extra outputs silent, then the tap into the core's ring; bypass = still a pass-through, the analyzer hears nothing), the host-tempo slot, pin / x2 / ÷2, the values the two buttons send (`bkp_key_in_use`, `bkp_bpm_in_use`) and their log line (`bkp_log_send`), the session blob, and the crash marker (A7: `~/Library/Logs/Beat Key/running/<pid>-<format>` while an instance is open; a dead process's marker is logged `HOST DIED ...` once and removed).
- The audio thread never waits: `bkp_prepare` swaps the analyzer with an atomic exchange, then waits (on the host thread) until the audio thread is out of `bkp_process`. Proven by a test that changes the rate six times while another thread keeps calling `bkp_process`.
- State blob v1: `BKPS`, version, 16-byte header with a checksum, 173-byte payload (pin, x2 / ÷2, the last reading), 189 bytes; cap 4096. Refused, logged, instance unchanged: garbage, cut short, trailing bytes, over the cap, a newer version, version 0, damaged checksum, a pin or key that is not one of the core's 24 names, multiplier out of range, NaN / out-of-range values, unknown flags.
- Core: one addition, `bk_key_index(name)` (the 24 names the core reads out; the layer validates pins and saved keys against it, so key spelling keeps one owner). `core/test.sh`: 248 checks, 0 failed, both slices.
- `plugin/test.sh`: builds the core and `bkp_test` universal, runs it on arm64 and on x86_64 (Rosetta) under the core's tripwire: **132 checks, 0 failed, on each slice**; the audio path (float, double, bypass, 80 channels, host tempo) made 0 allocations and 0 locks.
- Logging (one owner each): the core logs analyzer created / destroyed, readings, drops, refusals; the layer logs `plug-in opened: host ..., Beat Key <format> <version>`, `plug-in closed`, rate changes, weights and state refusals, sends, the crash marker.
Next: §8, the VST3 and AU shims on top of `bkp_*`, and the validator gate.
