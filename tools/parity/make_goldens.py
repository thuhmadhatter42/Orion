#!/usr/bin/env python3
"""
tools/parity/make_goldens.py: freeze the Python analyzer's outputs (plug-in plan step 2, A5).

The native core (core/) is trusted only when it reproduces these files. Python stays the reference.
Everything here is computed by bpm.py's and tempocnn_np.py's own functions; nothing is re-derived.

Run it with the bundled analyzer Python (the one the app ships), from the repo root:

    bin/python/bin/python3 tools/parity/make_goldens.py --work <scratch dir>
        [--bench-root docs/research] [--ffmpeg-bin bin] [--out core/test/golden] [--check]

  --work        scratch folder OUTSIDE the repo: the smoke clips ffmpeg makes, the mono PCM the
                core's parity runner reads (<work>/pcm/<id>.f32, float32 at the file's own rate),
                and this run's log (<work>/make_goldens.log). About 2 GB.
  --bench-root  folder holding key-bench/audio and bpm-bench/audio (fetched by their fetch.sh;
                never in the repo). In a git worktree point it at the main checkout's docs/research.
  --ffmpeg-bin  folder with ffmpeg and ffprobe (deps.sh puts them in ./bin).
  --check       write nothing into --out; fail unless every file a fresh run would write is
                byte-for-byte what is there now (step 2's "done" test).

What it writes into --out (audio never; files are keyed by the audio's sha256, first 16 hex):
  manifest.json            every item (set, name, id, sample rate, samples, PCM sha256) + versions
  files/<id>.json          key: top-3 with %, the 24 scores, pcp12, tuning, chroma
                           tempo: TempoCNN class per patch, global BPM, 0.1 BPM, refined BPM
  stream/<id>.json         smoke set only: LiveAnalyzer events, fed 0.5 s at a time (as --stream does)
  layers/<id>.json + .f32  five files: HPCP frames, spectral peaks, mel bands, CNN output, by layer

Reference quirk frozen here on purpose: essentia's streaming FrameCutter adds random noise
(+-1e-10, seeded from the clock) to silent frames. A patch made only of such frames has no
defined tempo class (two runs of bpm.py disagree on it): it is marked in "noise_only", its class
is written as null, and the core is not compared on it. The file's BPM is still frozen whenever
the real patches decide the vote whatever those patches say ("decided"); a clip of nothing but
digital silence has no BPM to freeze. bpm-bench/4703149 ends in 50 s of digital silence, so this
is a real file's case, not only the smoke set's.
"""

import argparse
import hashlib
import json
import logging
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
sys.dont_write_bytecode = True

SMOKE = Path(__file__).resolve().parent / "smoke_set.json"
LAYER_HPCP_FRAMES = 300        # ~28 s of key frames per layer dump
LAYER_MEL_FRAMES = 600         # ~28 s of tempo frames per layer dump
EDGE = 4096                    # samples kept from each end of a resampled signal in a layer dump
NOISE_DRIVEN_PEAK = 1e-8       # a frame whose samples all sit under this is decided by the noise

log = logging.getLogger("make_goldens")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def dumps(obj):
    return json.dumps(obj, indent=1, sort_keys=True, allow_nan=False) + "\n"


class Out:
    """Writes a file into --out, or (--check) compares it with what is there."""

    def __init__(self, root, check):
        self.root, self.check = Path(root), check
        self.written, self.differ, self.missing = [], [], []

    def put(self, rel, data):
        if isinstance(data, str):
            data = data.encode("utf-8")
        p = self.root / rel
        self.written.append(rel)
        if self.check:
            if not p.is_file():
                self.missing.append(rel)
            elif p.read_bytes() != data:
                self.differ.append(rel)
            return
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)

    def stale(self):
        """Files under --out that this run did not produce."""
        have = {str(p.relative_to(self.root)) for p in self.root.rglob("*") if p.is_file()}
        return sorted(have - set(self.written))


def bench_files(bench_root, bench):
    d = Path(bench_root) / bench / "audio"
    files = sorted(p for p in d.iterdir() if p.suffix.lower() == ".mp3") if d.is_dir() else []
    if len(files) != 40:
        raise SystemExit(f"REFUSED: {d} holds {len(files)} mp3 files, want 40 "
                         f"(run docs/research/{bench}/fetch.sh, or pass --bench-root)")
    return files


def build_smoke(clip, benches, ffmpeg, work):
    """Make one smoke clip with ffmpeg (bit-exact flags, so the same ffmpeg gives the same file)."""
    def src(spec):
        bench, idx = spec.split("/")
        return benches[bench][int(idx)]

    if clip.get("copy"):
        return src(clip["inputs"][0])
    out = Path(work) / "smoke" / (clip["id"] + ".wav")
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [ffmpeg, "-nostdin", "-v", "error", "-y"]
    for spec in clip["inputs"]:
        if spec.startswith("lavfi:"):
            cmd += ["-f", "lavfi", "-i", spec[len("lavfi:"):]]
        else:
            cmd += ["-i", str(src(spec))]
    cmd += clip["args"] + ["-fflags", "+bitexact", "-flags:a", "+bitexact", "-map_metadata", "-1", str(out)]
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0 or not out.is_file():
        raise SystemExit(f"REFUSED: ffmpeg could not make smoke clip {clip['id']}: "
                         f"{r.stderr.decode(errors='replace').strip()}")
    return out


def frame_flags(a11, n_frames):
    """Which TempoCNN frames essentia's FrameCutter saw as silent, and which of those are so close
    to digital zero that the added noise (+-1e-10) decides them. Frame i covers samples
    [512 i - 512, 512 i + 512), zero-padded (FrameCutter(1024, 512), startFromZero = false)."""
    import numpy as np
    x = np.concatenate([np.zeros(512, np.float32), np.asarray(a11, np.float32), np.zeros(1024, np.float32)])
    silent, noise = [], []
    for i in range(n_frames):
        fr = x[i * 512:i * 512 + 1024]
        power = np.add.reduce(fr * fr, dtype=np.float32) / np.float32(1024)
        silent.append(bool(power < 1e-10))
        noise.append(bool(np.abs(fr).max() < NOISE_DRIVEN_PEAK) if len(fr) else True)
    return silent, noise


def analyze_item(path, bpm, tempocnn_np, es, np):
    """The Python reference for one file, layer by layer, with bpm.py's own functions.
    Returns (golden dict, arrays for the layer dump, mono PCM, sample rate)."""
    stereo, sr, nch = bpm.decode_ffmpeg(path)
    mono = es.MonoMixer()(stereo, nch)
    sr = int(sr)
    a_key = mono if sr == bpm.KEY_SR else es.Resample(inputSampleRate=sr, outputSampleRate=bpm.KEY_SR)(mono)
    a_bpm = mono if sr == bpm.TEMPOCNN_SR else es.Resample(inputSampleRate=sr, outputSampleRate=bpm.TEMPOCNN_SR)(mono)

    # ---- key
    peaks = []
    H = bpm.hpcp_frames(a_key, peaks)
    reading = bpm.key_reading(H, peaks)
    tuning_raw = bpm.estimate_tuning(peaks) if peaks else None
    retuned = bool(tuning_raw is not None and abs(tuning_raw) >= bpm.TUNING_RETUNE_CENTS and len(peaks) == len(H))
    H_used = bpm.hpcp_from_peaks(peaks, 440.0 * 2 ** (tuning_raw / 1200)) if retuned else H
    keys, pcp = bpm._keys_and_pcp(H_used)
    if [list(k) for k in keys] != [list(k) for k in reading["keys"]]:
        raise SystemExit(f"REFUSED: {path}: layered key {keys} is not key_reading's {reading['keys']}")
    has_key = bool(len(H_used) and H_used.max() != 0)
    scores = bpm.key_scores(pcp, bpm.BGATE) if has_key else {}
    key = {
        "keys": [[name, pct] for name, pct in reading["keys"]],
        "tuning_cents": reading["tuning_cents"],
        "tuning_raw": tuning_raw,
        "retuned": retuned,
        "chroma": reading["chroma"],
        "pcp12": [float(v) for v in pcp],
        "scores": {bpm.fmt_key(pc, mode): s for (pc, mode), s in scores.items()},
        "n_frames": int(len(H)),
        "n_peaks": int(sum(len(p[0]) for p in peaks)),
    }

    # ---- tempo
    bands = tempocnn_np.mel_bands(a_bpm)
    P = tempocnn_np.patches(bands)
    pred = tempocnn_np.predict(P) if len(P) else np.zeros((0, 256), np.float32)
    global_bpm, local, _probs = tempocnn_np.aggregate(pred)
    bpm_round = round(float(global_bpm), 1)
    silent, noise = frame_flags(a_bpm, len(bands))
    n_patches = len(P)
    noise_only = [all(noise[i * 128:i * 128 + 256]) for i in range(n_patches)]
    has_silent = [any(silent[i * 128:i * 128 + 256]) for i in range(n_patches)]
    classes = [None if noise_only[i] else int(c) - tempocnn_np.BPM_OFFSET for i, c in enumerate(local)]
    # The majority vote is decided when no answer the noise-only patches could give would change
    # it: the leader among the real patches is ahead of the runner-up by more than their number.
    votes = sorted((classes.count(c) for c in set(classes) if c is not None), reverse=True) + [0, 0]
    decided = votes[0] > votes[1] + sum(noise_only) if any(noise_only) else True
    tempo = {
        "classes": classes,                       # null = a noise-only patch: random in the reference
        "noise_only": noise_only,
        "decided": decided,                       # false: the three BPM values below are null
        "global_bpm": float(global_bpm) if decided else None,
        "bpm": bpm_round if decided else None,
        "bpm_exact": bpm.refine_bpm(a_bpm, bpm_round) if decided else None,
        "n_frames": int(len(bands)),
        "n_silent_frames": int(sum(silent)),
    }

    # ---- the whole thing once more through the app's entry point: it must say the same
    full_bpm, full_keys, extras = bpm.analyze_full(path)
    same = ([list(k) for k in full_keys] == key["keys"]
            and extras.get("tuning_cents") == key["tuning_cents"] and extras["chroma"] == key["chroma"])
    if decided:
        same = same and full_bpm == tempo["bpm"] and extras.get("bpm_exact") == tempo["bpm_exact"]
    if not same:
        raise SystemExit(f"REFUSED: {path}: analyze_full gave {full_bpm} {full_keys} {extras}, "
                         f"the layered run gave {tempo['bpm']} {key['keys']}")

    golden = {
        "sample_rate": sr,
        "samples": int(len(mono)),
        "pcm_sha256": sha256_bytes(np.ascontiguousarray(mono, "<f4").tobytes()),
        "resampled": {
            "key_44100": {"samples": int(len(a_key)), "sha256": sha256_bytes(np.ascontiguousarray(a_key, "<f4").tobytes())},
            "tempo_11025": {"samples": int(len(a_bpm)), "sha256": sha256_bytes(np.ascontiguousarray(a_bpm, "<f4").tobytes())},
        },
        "key": key,
        "tempo": tempo,
    }
    layers = {"H": H, "peaks": peaks, "bands": bands, "pred": pred, "silent": silent,
              "has_silent": has_silent, "a_key": a_key, "a_bpm": a_bpm}
    return golden, layers, mono, sr


def layer_dump(out, item_id, layers, np):
    """Intermediate arrays as raw little-endian float32, shapes in the JSON beside them.
    Rows the reference's random noise touches (silent mel frames, CNN rows of patches holding one)
    are written as zeros and listed, so two runs give the same bytes."""
    H = np.asarray(layers["H"], "<f4").reshape(-1, 36)[:LAYER_HPCP_FRAMES]
    pk = layers["peaks"][:len(H)]
    counts = np.array([len(p[0]) for p in pk], "<i4")
    flat = [np.stack([p[0], p[1], p[2]], axis=1).astype("<f4").ravel() for p in pk if len(p[0])]
    peaks = np.concatenate(flat) if flat else np.zeros(0, "<f4")
    bands = np.array(layers["bands"], "<f4").reshape(-1, 40)[:LAYER_MEL_FRAMES]
    silent = [i for i, s in enumerate(layers["silent"][:len(bands)]) if s]
    bands[silent] = 0
    pred = np.array(layers["pred"], "<f4").reshape(-1, 256)
    unstable = [i for i, s in enumerate(layers["has_silent"]) if s]
    pred[unstable] = 0
    a_key = np.asarray(layers["a_key"], "<f4")
    a_bpm = np.asarray(layers["a_bpm"], "<f4")
    out.put(f"layers/{item_id}.hpcp.f32", H.tobytes())
    out.put(f"layers/{item_id}.peak_counts.i32", counts.tobytes())
    out.put(f"layers/{item_id}.peaks.f32", peaks.tobytes())
    out.put(f"layers/{item_id}.mel.f32", bands.tobytes())
    out.put(f"layers/{item_id}.cnn.f32", pred.tobytes())
    out.put(f"layers/{item_id}.key44100_edges.f32", np.concatenate([a_key[:EDGE], a_key[-EDGE:]]).tobytes())
    out.put(f"layers/{item_id}.tempo11025_edges.f32", np.concatenate([a_bpm[:EDGE], a_bpm[-EDGE:]]).tobytes())
    out.put(f"layers/{item_id}.json", dumps({
        "hpcp": {"file": f"{item_id}.hpcp.f32", "shape": [int(len(H)), 36],
                 "what": "hpcp_frames rows (A = 440), first frames of the file"},
        "peaks": {"file": f"{item_id}.peaks.f32", "counts": f"{item_id}.peak_counts.i32",
                  "what": "per HPCP frame: count (int32), then count x (frequency, magnitude, whitened magnitude)"},
        "mel": {"file": f"{item_id}.mel.f32", "shape": [int(len(bands)), 40], "silent_rows_zeroed": silent,
                "what": "tempocnn_np.mel_bands rows, first frames of the file"},
        "cnn": {"file": f"{item_id}.cnn.f32", "shape": [int(len(pred)), 256], "unstable_rows_zeroed": unstable,
                "what": "tempocnn_np.predict rows (softmax over the 256 tempo classes), every patch"},
        "key44100_edges": {"file": f"{item_id}.key44100_edges.f32", "each": int(min(EDGE, len(a_key))),
                           "what": "first and last samples of the 44.1 kHz signal the key reads"},
        "tempo11025_edges": {"file": f"{item_id}.tempo11025_edges.f32", "each": int(min(EDGE, len(a_bpm))),
                             "what": "first and last samples of the 11.025 kHz signal the tempo reads"},
    }))


def stream_events(mono, sr, bpm, new_song_at):
    """LiveAnalyzer fed the way `bpm.py --stream` feeds it: 0.5 s of mono float32 at the file's own
    rate per push, then finish(). Returns [[chunk index, event], ...]."""
    live = bpm.LiveAnalyzer(rate=sr)
    chunk = max(1, int(sr * bpm.STREAM_CHUNK_SECS))
    events = []
    n_chunks = 0
    for i, start in enumerate(range(0, len(mono), chunk)):
        if new_song_at is not None and i == new_song_at:
            events += [[i, e] for e in live.new_song("title")]
        events += [[i, e] for e in live.push(mono[start:start + chunk])]
        n_chunks = i + 1
    events += [[n_chunks, e] for e in live.finish()]
    return {"rate": sr, "chunk_samples": chunk, "chunks": n_chunks, "new_song_at_chunk": new_song_at,
            "events": events}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--work", required=True)
    ap.add_argument("--bench-root", default=str(REPO / "docs" / "research"))
    ap.add_argument("--ffmpeg-bin", default=str(REPO / "bin"))
    ap.add_argument("--out", default=str(REPO / "core" / "test" / "golden"))
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--limit", type=int, help="trial run: the first N files of each set; needs an explicit --out")
    a = ap.parse_args()
    if a.limit and a.out == ap.get_default("out"):
        raise SystemExit("REFUSED: --limit is a trial run; give it its own --out, never the real goldens")

    work = Path(a.work).resolve()
    if REPO in work.parents or work == REPO:
        raise SystemExit(f"REFUSED: --work {work} is inside the repo; audio and PCM stay out of it")
    (work / "pcm").mkdir(parents=True, exist_ok=True)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                        handlers=[logging.FileHandler(work / "make_goldens.log"), logging.StreamHandler(sys.stderr)])

    ffmpeg, ffprobe = Path(a.ffmpeg_bin) / "ffmpeg", Path(a.ffmpeg_bin) / "ffprobe"
    if not ffmpeg.is_file() or not ffprobe.is_file():
        raise SystemExit(f"REFUSED: no ffmpeg/ffprobe in {a.ffmpeg_bin} (pass --ffmpeg-bin)")
    os.environ["ORION_BIN"] = str(Path(a.ffmpeg_bin).resolve())     # bpm._tool looks here first

    import numpy as np
    import bpm
    if not bpm.analyzer_ready():
        raise SystemExit("REFUSED: " + bpm.ANALYZER_INCOMPLETE + " Run this with the bundled Python (bin/python).")
    import essentia
    import essentia.standard as es
    import tempocnn_np
    if hasattr(es, "TempoCNN") or hasattr(es, "AudioLoader"):
        raise SystemExit("REFUSED: this Python has essentia-tensorflow; the reference is the bundled build "
                         "(tempocnn_np + ffmpeg decode), the one the app ships")

    benches = {b: bench_files(a.bench_root, b) for b in ("key-bench", "bpm-bench")}
    smoke = json.loads(SMOKE.read_text())
    items = [(b, p.name, p, None) for b in ("key-bench", "bpm-bench") for p in benches[b][:a.limit]]
    for clip in smoke["clips"][:a.limit]:
        items.append(("smoke", clip["id"], build_smoke(clip, benches, str(ffmpeg), work), clip))
    want_layers = set()
    for spec in smoke["layer_dumps"]:
        s, key = spec.split("/")
        want_layers.add((s, benches[s][int(key)].name if s != "smoke" else key))

    out = Out(a.out, a.check)
    manifest_items = []
    for n, (set_name, name, path, clip) in enumerate(items, 1):
        file_sha = sha256_file(path)
        item_id = file_sha[:16]
        log.info("%d/%d %s %s (%s)", n, len(items), set_name, name, item_id)
        try:
            golden, layers, mono, sr = analyze_item(path, bpm, tempocnn_np, es, np)
        except SystemExit:
            raise
        except Exception:
            log.exception("analysis failed on %s", path)
            raise SystemExit(f"REFUSED: analysis failed on {path}; see {work / 'make_goldens.log'}")
        np.ascontiguousarray(mono, "<f4").tofile(work / "pcm" / f"{item_id}.f32")
        entry = {"set": set_name, "name": name, "id": item_id, "sha256": file_sha,
                 "sample_rate": golden["sample_rate"], "samples": golden["samples"],
                 "pcm_sha256": golden["pcm_sha256"], "stream": False, "layers": False}
        golden = dict(golden, sha256=file_sha)     # set and name live in the manifest (one clip can sit in two sets)
        if set_name == "smoke":
            entry["stream"] = True
            out.put(f"stream/{item_id}.json",
                    dumps(stream_events(mono, sr, bpm, clip.get("new_song_at_chunk"))))
        if (set_name, name) in want_layers:
            entry["layers"] = True
            layer_dump(out, item_id, layers, np)
        # a clip listed twice (a bench file reused as a smoke clip) keeps one file: same audio, same answer
        out.put(f"files/{item_id}.json", dumps(golden))
        manifest_items.append(entry)

    ffver = subprocess.run([str(ffmpeg), "-version"], capture_output=True, text=True).stdout.splitlines()[0]
    out.put("manifest.json", dumps({
        "what": "Frozen outputs of the Python analyzer (tools/parity/make_goldens.py). The core must reproduce them (plan A5).",
        "reference": {
            "bpm.py": sha256_file(REPO / "bpm.py"),
            "tempocnn_np.py": sha256_file(REPO / "tempocnn_np.py"),
            "models/deeptemp-k16-3.npz": sha256_file(REPO / "models" / "deeptemp-k16-3.npz"),
            "essentia": essentia.__version__,
            "numpy": np.__version__,
            "python": sys.version.split()[0],
            "ffmpeg": ffver,
            "machine": os.uname().machine,
        },
        "items": manifest_items,
    }))

    stale = out.stale()
    if a.check:
        if out.differ or out.missing or stale:
            for rel in out.differ:
                log.error("DIFFERS from a fresh run: %s", rel)
            for rel in out.missing:
                log.error("MISSING (a fresh run writes it): %s", rel)
            for rel in stale:
                log.error("STALE (a fresh run does not write it): %s", rel)
            raise SystemExit(f"CHECK FAILED: {len(out.differ)} differ, {len(out.missing)} missing, {len(stale)} stale")
        log.info("CHECK OK: %d files, byte for byte", len(out.written))
    else:
        for rel in stale:
            log.error("STALE file left in %s (this run did not write it): %s", a.out, rel)
        if stale:
            raise SystemExit(f"REFUSED to call this done: {len(stale)} stale file(s) in {a.out}; move them out")
        log.info("wrote %d files into %s; PCM for the parity runner in %s", len(out.written), a.out, work / "pcm")
    return 0


if __name__ == "__main__":
    sys.exit(main())
