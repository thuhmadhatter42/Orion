#!/usr/bin/env python3
"""
core/test/parity.py: the parity gate (plug-in plan A5). Runs the core (parity_dump) on the PCM
tools/parity/make_goldens.py wrote and holds its answers against the frozen Python outputs in
core/test/golden. Standard library only. Run it through core/parity.sh.

The gate, per file (a miss is a bug in the port, never a new tolerance):
  key     same top-3 names in the same order with the same percentages; same retune decision;
          tuning within 0.5 cent (and offered / not offered alike)
  tempo   same TempoCNN class for every patch; same global BPM; refined BPM within 0.01
  stream  (smoke set) the same events at the same half-second chunks; inside a reading the rules
          above (percentages are whole numbers there)
Fields A5 does not name are held to one unit of the rounding bpm.py applies to them, and the
report says how many matched exactly: chroma (3 decimals), boundary scores (3 decimals),
silence / sound levels (1 decimal).
A TempoCNN patch made only of digital silence is random in the reference itself (essentia adds
clock-seeded noise); the goldens mark those "noise_only" and they are counted here, not compared.
"""

import argparse
import array
import hashlib
import json
import math
import os
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TUNING_TOL = 0.5
BPM_EXACT_TOL = 0.01
EPS = 1e-9


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def f32(path):
    a = array.array("f")
    with open(path, "rb") as f:
        a.frombytes(f.read())
    return a


def i32(path):
    a = array.array("i")
    with open(path, "rb") as f:
        a.frombytes(f.read())
    return a


def close(a, b, tol):
    if a is None or b is None:
        return a is None and b is None
    return abs(a - b) <= tol + EPS


def check_key(g, c):
    """-> (list of misses, info dict)"""
    miss = []
    if [list(k) for k in g["keys"]] != [list(k) for k in c["keys"]]:
        miss.append(f"keys: golden {g['keys']} core {c['keys']}")
    if g["retuned"] != c["retuned"]:
        miss.append(f"retune decision: golden {g['retuned']} core {c['retuned']} (raw tuning {g['tuning_raw']} / {c['tuning_raw']})")
    if not close(g["tuning_cents"], c["tuning_cents"], TUNING_TOL):
        miss.append(f"tuning: golden {g['tuning_cents']} core {c['tuning_cents']}")
    if g["n_frames"] != c["n_frames"]:
        miss.append(f"HPCP frames: golden {g['n_frames']} core {c['n_frames']}")
    chroma_exact = g["chroma"] == c["chroma"]
    if any(not close(a, b, 0.001) for a, b in zip(g["chroma"], c["chroma"])):
        miss.append(f"chroma: golden {g['chroma']} core {c['chroma']}")
    info = {
        "chroma_exact": chroma_exact,
        "tuning_exact": g["tuning_cents"] == c["tuning_cents"],
        "peaks_equal": g["n_peaks"] == c["n_peaks"],
        "max_score_diff": max((abs(g["scores"][k] - c["scores"].get(k, 0.0)) for k in g["scores"]), default=0.0),
        "max_pcp_diff": max((abs(a - b) for a, b in zip(g["pcp12"], c["pcp12"])), default=0.0),
    }
    return miss, info


def check_tempo(g, c):
    miss = []
    undefined = sum(g["noise_only"])
    if g["n_frames"] != c["n_frames"]:
        miss.append(f"mel frames: golden {g['n_frames']} core {c['n_frames']}")
    if len(g["classes"]) != len(c["classes"]):
        miss.append(f"patches: golden {len(g['classes'])} core {len(c['classes'])}")
    else:
        for i, (a, b) in enumerate(zip(g["classes"], c["classes"])):
            if a is None:                    # a noise-only patch: the reference has no answer
                continue
            if a != b:
                miss.append(f"patch {i}: golden class {a} ({a + 30} BPM) core {b} ({b + 30} BPM), core margin {c['margins'][i]:.6f}")
    if g["decided"]:                         # the real patches decide the vote: the BPM is defined
        if g["global_bpm"] != c["global_bpm"] or g["bpm"] != c["bpm"]:
            miss.append(f"global BPM: golden {g['global_bpm']} core {c['global_bpm']}")
        if not close(g["bpm_exact"], c["bpm_exact"], BPM_EXACT_TOL):
            miss.append(f"refined BPM: golden {g['bpm_exact']} core {c['bpm_exact']}")
    info = {
        "patches": len(g["classes"]), "undefined_patches": undefined, "bpm_defined": g["decided"],
        "bpm_exact_equal": g["decided"] and g["bpm_exact"] == c["bpm_exact"],
        "bpm_exact_diff": abs(g["bpm_exact"] - c["bpm_exact"]) if g["decided"] else 0.0,
        "min_margin": min((m for i, m in enumerate(c["margins"]) if i < len(g["classes"]) and g["classes"][i] is not None), default=None),
    }
    return miss, info


def check_stream(g, c):
    miss, exact = [], {"chroma": [0, 0], "scores": [0, 0], "bpm_exact": [0, 0], "tuning": [0, 0]}
    ge, ce = g["events"], c["events"]
    if g["chunks"] != c["chunks"]:
        miss.append(f"chunks: golden {g['chunks']} core {c['chunks']}")
    if [(i, e["event"]) for i, e in ge] != [(i, e["event"]) for i, e in ce]:
        gs = [(i, e["event"]) for i, e in ge]
        cs = [(i, e["event"]) for i, e in ce]
        first = next((n for n, (a, b) in enumerate(zip(gs, cs)) if a != b), min(len(gs), len(cs)))
        miss.append(f"event sequence differs at event {first}: golden {gs[first:first + 3]} core {cs[first:first + 3]} "
                    f"({len(gs)} vs {len(cs)} events)")
        return miss, exact

    def tally(name, same):
        exact[name][1] += 1
        exact[name][0] += bool(same)

    for (i, a), (_, b) in zip(ge, ce):
        kind = a["event"]
        where = f"chunk {i} {kind}"
        if kind == "reading":
            if a["keys"] != b["keys"]:
                miss.append(f"{where}: keys golden {a['keys']} core {b['keys']}")
            if a["bpm"] != b["bpm"]:
                miss.append(f"{where}: bpm golden {a['bpm']} core {b['bpm']}")
            if not close(a["bpm_exact"], b["bpm_exact"], BPM_EXACT_TOL):
                miss.append(f"{where}: refined BPM golden {a['bpm_exact']} core {b['bpm_exact']}")
            if a["secs"] != b["secs"]:
                miss.append(f"{where}: secs golden {a['secs']} core {b['secs']}")
            if not close(a["tuning_cents"], b["tuning_cents"], TUNING_TOL):
                miss.append(f"{where}: tuning golden {a['tuning_cents']} core {b['tuning_cents']}")
            if any(not close(x, y, 0.001) for x, y in zip(a["chroma"], b["chroma"])):
                miss.append(f"{where}: chroma golden {a['chroma']} core {b['chroma']}")
            tally("chroma", a["chroma"] == b["chroma"])
            tally("bpm_exact", a["bpm_exact"] == b["bpm_exact"])
            tally("tuning", a["tuning_cents"] == b["tuning_cents"])
        elif kind in ("silence", "sound"):
            for field in ("db", "after"):
                if field in a and not close(a[field], b.get(field), 0.1):
                    miss.append(f"{where}: {field} golden {a[field]} core {b.get(field)}")
        elif kind == "boundary":
            if a["reason"] != b["reason"]:
                miss.append(f"{where}: reason golden {a['reason']} core {b['reason']}")
            sa, sb = a.get("scores"), b.get("scores")
            if (sa is None) != (sb is None):
                miss.append(f"{where}: scores golden {sa} core {sb}")
            elif sa is not None:
                if sa["grid"] != sb["grid"] or sa["bpm_ref"] != sb["bpm_ref"]:
                    miss.append(f"{where}: pulse golden {sa['grid']} {sa['bpm_ref']} core {sb['grid']} {sb['bpm_ref']}")
                for field in ("disappeared", "harmonic", "dphase", "grid_ref", "grid_cur"):
                    if not close(sa[field], sb[field], 0.001):
                        miss.append(f"{where}: {field} golden {sa[field]} core {sb[field]}")
                tally("scores", sa == sb)
    return miss, exact


def layer_report(golden_dir, out_prefix, item_id):
    """How far each layer of the core sits from the reference (the five dumped files). Information
    for finding a port bug by layer; the gate is the answers above."""
    meta = json.loads((golden_dir / "layers" / f"{item_id}.json").read_text())
    rep = {}
    g = f32(golden_dir / "layers" / meta["hpcp"]["file"])
    c = f32(f"{out_prefix}.hpcp.f32")
    n = min(len(g), len(c))
    rep["hpcp_max_abs"] = max((abs(g[i] - c[i]) for i in range(n)), default=0.0)
    rep["hpcp_max"] = max(g, default=0.0)
    gc, cc = i32(golden_dir / "layers" / meta["peaks"]["counts"]), i32(f"{out_prefix}.peak_counts.i32")
    rep["peak_count_frames_differ"] = sum(1 for i in range(len(gc)) if gc[i] != cc[i])
    gp, cp = f32(golden_dir / "layers" / meta["peaks"]["file"]), f32(f"{out_prefix}.peaks.f32")
    worst = 0.0
    if rep["peak_count_frames_differ"] == 0:
        for i in range(len(gp)):
            worst = max(worst, abs(gp[i] - cp[i]) / max(abs(gp[i]), 1e-12))
    rep["peaks_max_rel"] = worst if rep["peak_count_frames_differ"] == 0 else None
    g, c = f32(golden_dir / "layers" / meta["mel"]["file"]), f32(f"{out_prefix}.mel.f32")
    skip = set(meta["mel"]["silent_rows_zeroed"])
    worst = 0.0
    for row in range(meta["mel"]["shape"][0]):
        if row in skip:
            continue
        for j in range(40):
            a, b = g[row * 40 + j], c[row * 40 + j]
            worst = max(worst, abs(a - b) / max(abs(a), 1e-6))
    rep["mel_max_rel"] = worst
    g, c = f32(golden_dir / "layers" / meta["cnn"]["file"]), f32(f"{out_prefix}.cnn.f32")
    skip = set(meta["cnn"]["unstable_rows_zeroed"])
    worst = 0.0
    for row in range(meta["cnn"]["shape"][0]):
        if row in skip:
            continue
        for j in range(256):
            worst = max(worst, abs(g[row * 256 + j] - c[row * 256 + j]))
    rep["cnn_max_abs"] = worst
    for name, full in (("key44100_edges", "key44100"), ("tempo11025_edges", "tempo11025")):
        g, c = f32(golden_dir / "layers" / meta[name]["file"]), f32(f"{out_prefix}.{full}.f32")
        each = meta[name]["each"]
        head = max((abs(g[i] - c[i]) for i in range(min(each, len(c)))), default=0.0)
        tail = max((abs(g[each + i] - c[len(c) - each + i]) for i in range(each)), default=0.0) if len(c) >= each else None
        rep[name + "_max_abs"] = max(head, tail) if tail is not None else head
    return rep


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dump", help="the parity_dump binary")
    ap.add_argument("--weights")
    ap.add_argument("--ids", help="comma-separated clip ids: gate only these (a subset run, e.g. on another Mac)")
    ap.add_argument("--jobs-only", metavar="REMOTE_DIR", help="write --out/jobs.tsv with PCM and output paths under "
                    "REMOTE_DIR (for running parity_dump on another Mac) and stop")
    ap.add_argument("--no-run", action="store_true", help="do not run parity_dump: judge the outputs already in --out")
    ap.add_argument("--label", help="what ran, for the report's first line (e.g. 'x86_64 on Sofia, 2013 Xeon')")
    ap.add_argument("--pcm", required=True, help="<work>/pcm from tools/parity/make_goldens.py")
    ap.add_argument("--out", required=True, help="scratch folder for the core's outputs and the report")
    ap.add_argument("--golden", default=str(HERE / "golden"))
    ap.add_argument("--arch", choices=["arm64", "x86_64"], help="run this slice of the binary (arch -<slice>)")
    ap.add_argument("--only", choices=["key", "tempo", "stream"], action="append",
                    help="gate only these parts (default: all three)")
    a = ap.parse_args()
    if not (a.no_run or a.jobs_only) and not (a.dump and a.weights):
        ap.error("--dump and --weights are needed unless --no-run or --jobs-only is given")
    parts = a.only or ["key", "tempo", "stream"]
    only_ids = set(a.ids.split(",")) if a.ids else None
    golden_dir, pcm_dir, out_dir = Path(a.golden), Path(a.pcm), Path(a.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((golden_dir / "manifest.json").read_text())

    # one job per distinct clip; a clip in two sets is analyzed once
    by_id, jobs = {}, []
    for item in manifest["items"]:
        if only_ids is not None and item["id"] not in only_ids:
            continue
        first = item["id"] not in by_id
        entry = by_id.setdefault(item["id"], dict(item, sets=[]))
        entry["sets"].append(f"{item['set']}/{item['name']}")
        entry["stream"] = entry["stream"] or item["stream"]
        entry["layers"] = entry["layers"] or item["layers"]
        if not first:
            continue
        pcm = pcm_dir / f"{item['id']}.f32"
        if a.no_run:
            continue
        if not pcm.is_file():
            print(f"REFUSED: no PCM for {item['set']}/{item['name']} at {pcm}. "
                  f"Make it with tools/parity/make_goldens.py --check --work <folder>.", file=sys.stderr)
            return 2
        if sha256_file(pcm) != item["pcm_sha256"]:
            print(f"REFUSED: {pcm} is not the audio the goldens were made from (sha256 differs). "
                  f"Another ffmpeg? Remake the PCM, or the goldens, with tools/parity/make_goldens.py.", file=sys.stderr)
            return 2
    if only_ids is not None and set(by_id) != only_ids:
        print(f"REFUSED: --ids names clips the goldens do not have: {sorted(only_ids - set(by_id))}", file=sys.stderr)
        return 2
    job_pcm, job_out = (Path(a.jobs_only), Path(a.jobs_only)) if a.jobs_only else (pcm_dir, out_dir)
    for item_id, e in by_id.items():
        stream_file = golden_dir / "stream" / f"{item_id}.json"
        new_song = json.loads(stream_file.read_text())["new_song_at_chunk"] if e["stream"] else None
        jobs.append("\t".join([item_id, str(e["sample_rate"]), str(job_pcm / f"{item_id}.f32"), str(job_out / item_id),
                               "1" if e["layers"] else "0", "1" if (e["stream"] and "stream" in parts) else "0",
                               str(-1 if new_song is None else new_song)]))
    if a.jobs_only:
        (out_dir / "jobs.tsv").write_text("\n".join(jobs) + "\n")
        print(f"wrote {out_dir / 'jobs.tsv'} for {len(jobs)} clip(s), paths under {a.jobs_only}")
        return 0
    if not a.no_run:
        (out_dir / "jobs.tsv").write_text("\n".join(jobs) + "\n")
        cmd = (["arch", f"-{a.arch}"] if a.arch else []) + [a.dump, a.weights, str(out_dir / "jobs.tsv")]
        env = dict(os.environ, BEATKEY_LOG_DIR=str(out_dir / "logs"))
        run = subprocess.run(cmd, env=env)
        if run.returncode != 0:
            print(f"REFUSED: parity_dump exited {run.returncode}; its log is {out_dir / 'logs' / 'plugin.log'}", file=sys.stderr)
            return 2

    report, failed = {"items": {}, "arch": a.label or (a.arch + " slice" if a.arch else os.uname().machine)}, {p: [] for p in parts}
    times, stream_ms, reading_ms = [], [], []
    exact_totals = {}
    undefined = 0
    for item_id, e in by_id.items():
        g = json.loads((golden_dir / "files" / f"{item_id}.json").read_text())
        c = json.loads((out_dir / f"{item_id}.core.json").read_text())
        row = {"sets": e["sets"], "secs": e["samples"] / e["sample_rate"], "analyze_ms": c["analyze_ms"], "miss": {}}
        times.append((c["analyze_ms"], row["secs"]))
        row["resample_identical"] = {k: g["resampled"][k]["sha256"] == c["resampled"][k]["sha256"] for k in g["resampled"]}
        for k in g["resampled"]:
            if g["resampled"][k]["samples"] != c["resampled"][k]["samples"]:
                for p in parts:
                    row["miss"].setdefault(p, []).append(
                        f"{k}: golden {g['resampled'][k]['samples']} samples, core {c['resampled'][k]['samples']}")
        if "key" in parts:
            miss, row["key"] = check_key(g["key"], c["key"])
            row["miss"].setdefault("key", []).extend(miss)
        if "tempo" in parts:
            miss, row["tempo"] = check_tempo(g["tempo"], c["tempo"])
            row["miss"].setdefault("tempo", []).extend(miss)
            undefined += row["tempo"]["undefined_patches"]
        if "stream" in parts and e["stream"]:
            gs = json.loads((golden_dir / "stream" / f"{item_id}.json").read_text())
            cs = json.loads((out_dir / f"{item_id}.stream.json").read_text())
            miss, exact = check_stream(gs, cs)
            row["miss"].setdefault("stream", []).extend(miss)
            row["stream"] = {"events": len(gs["events"]), "readings": cs["readings"], "worst_push_ms": cs["worst_push_ms"],
                             "median_full_reading_ms": cs["median_full_reading_ms"], "audio_secs": row["secs"],
                             "total_push_ms": cs["total_push_ms"]}
            stream_ms.append(cs["worst_push_ms"])
            if cs["median_full_reading_ms"] is not None:
                reading_ms.append(cs["median_full_reading_ms"])
            for k, (same, total) in exact.items():
                t = exact_totals.setdefault(k, [0, 0])
                t[0] += same
                t[1] += total
        if e["layers"] and (out_dir / f"{item_id}.hpcp.f32").is_file():
            row["layers"] = layer_report(golden_dir, str(out_dir / item_id), item_id)
        for p in parts:
            if row["miss"].get(p):
                failed[p].append(item_id)
        report["items"][item_id] = row

    n = len(by_id)
    n_stream = sum(1 for e in by_id.values() if e["stream"])
    print(f"\nParity, {report['arch']}: {n} clips" + (" (a subset)" if only_ids is not None else f" ({len(manifest['items'])} manifest rows)"))
    summary = {}
    for p in parts:
        total = n_stream if p == "stream" else n
        ok = total - len(failed[p])
        summary[p] = {"pass": ok, "total": total, "percent": round(100.0 * ok / total, 2)}
        print(f"  {p:6s} {ok}/{total} = {summary[p]['percent']} %")
    for p in parts:
        for item_id in failed[p]:
            row = report["items"][item_id]
            print(f"  MISS {p} {item_id} {row['sets']}")
            for m in row["miss"][p][:8]:
                print(f"       {m}")
            if len(row["miss"][p]) > 8:
                print(f"       ... {len(row['miss'][p]) - 8} more")
    rows = report["items"].values()
    if "key" in parts:
        print(f"  key detail: chroma exact on {sum(r['key']['chroma_exact'] for r in rows)}/{n}, tuning exact on "
              f"{sum(r['key']['tuning_exact'] for r in rows)}/{n}, same peak count on {sum(r['key']['peaks_equal'] for r in rows)}/{n}, "
              f"largest key-score difference {max(r['key']['max_score_diff'] for r in rows):.3g}")
    if "tempo" in parts:
        patches = sum(r["tempo"]["patches"] for r in rows)
        margins = [r["tempo"]["min_margin"] for r in rows if r["tempo"]["min_margin"] is not None]
        defined = sum(r["tempo"]["bpm_defined"] for r in rows)
        print(f"  tempo detail: {patches} patches, {undefined} of them undefined in the reference (digital silence) and not compared; "
              f"BPM defined in the reference for {defined}/{n} clips; refined BPM exact on "
              f"{sum(r['tempo']['bpm_exact_equal'] for r in rows)}/{defined}, largest difference "
              f"{max(r['tempo']['bpm_exact_diff'] for r in rows):.3g}; smallest winning margin {min(margins):.4g}")
    if "stream" in parts and exact_totals:
        print("  stream detail (exact matches of fields held to one rounding unit): "
              + ", ".join(f"{k} {v[0]}/{v[1]}" for k, v in sorted(exact_totals.items())))
    ident = {k: sum(r["resample_identical"][k] for r in rows) for k in ("key_44100", "tempo_11025")}
    print(f"  resampler: output bit-identical to the reference on {ident['key_44100']}/{n} (44.1 kHz) and {ident['tempo_11025']}/{n} (11.025 kHz) clips")
    full = [ms for ms, secs in times if secs >= 100]
    if full:
        print(f"  CPU, one whole-clip analysis (the {len(full)} clips of 120 s): median {statistics.median(full):.0f} ms, worst {max(full):.0f} ms")
    if stream_ms:
        live = [r["stream"] for r in rows if "stream" in r]
        share = 100.0 * sum(x["total_push_ms"] for x in live) / (1000.0 * sum(x["audio_secs"] for x in live))
        print(f"  CPU, live: one reading with a BPM in it (the half-second push that makes it) median {statistics.median(reading_ms):.0f} ms; "
              f"worst single push {max(stream_ms):.0f} ms; all pushes together {share:.1f} % of one core in real time")
    for item_id, row in report["items"].items():
        if "layers" in row:
            print(f"  layers {item_id}: " + ", ".join(f"{k} {v:.3g}" if isinstance(v, float) else f"{k} {v}" for k, v in row["layers"].items()))
    report["summary"] = summary
    (out_dir / "parity-report.json").write_text(json.dumps(report, indent=1, sort_keys=True) + "\n")
    print(f"  report: {out_dir / 'parity-report.json'}")
    bad = any(failed[p] for p in parts)
    print("PARITY FAILED" if bad else "PARITY OK")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
