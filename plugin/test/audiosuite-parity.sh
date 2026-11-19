#!/bin/sh
# plugin/test/audiosuite-parity.sh: the AudioSuite Analyze path gives the app's answer (plan step 14, "a clip analysed
# in AudioSuite gives the same key and BPM as the same file dropped on the app"), checked without Pro Tools.
#   sh plugin/test/audiosuite-parity.sh [bench root]     (default: $BENCH_ROOT, else <repo>/docs/research)
#
# For every key-bench and bpm-bench file in core/test/golden/manifest.json (80; the smoke clips are made in a
# scratch folder by make_goldens.py and are not here): decode it the way the app does (bpm.py decode_ffmpeg:
# ffprobe, ffmpeg's fixed-point mp3 decoder to s16, the file's own rate and channels), hand it to the instance
# layer in 4096-frame windows of de-interleaved channels the way the AAX host processor does (clip_parity), and hold
# the reading against the app's frozen answer for that file (core/test/golden/files/<id>.json) with plan A5's
# rules: same top-3 key names and percentages, same whole BPM, refined BPM within 0.01, tuning within 0.5 cent.
# Arm64 slice (the core's own parity gate covers both slices).  Scratch in plugin/build.noindex, removed on exit.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$HERE/.." && pwd)
fail() { echo "plugin/test/audiosuite-parity.sh: FAIL: $*" >&2; exit 1; }
BENCH=${1:-${BENCH_ROOT:-$ROOT/docs/research}}
[ -d "$BENCH/key-bench/audio" ] || fail "no bench audio at $BENCH/key-bench/audio (pass the bench root)"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || fail "ffmpeg / ffprobe not on PATH"
sh "$ROOT/core/build.sh" >/dev/null
VERSION=$(tr -d ' \n' < "$ROOT/VERSION")
mkdir -p "$HERE/build.noindex"
TMP=$(mktemp -d "$HERE/build.noindex/asparity.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM
clang++ -arch arm64 -mmacosx-version-min=12.0 -std=c++17 -Wall -Wextra -Werror -O2 -I"$ROOT/core/include" \
  "-DBKP_VERSION=\"$VERSION\"" "$HERE/shared/bkp.cpp" "$HERE/test/clip_parity.cpp" "$ROOT/core/build.noindex/libbeatkey.a" \
  -framework Accelerate -framework CoreFoundation -o "$TMP/clip_parity" || fail "clip_parity did not build"
mkdir -p "$TMP/logs"
BEATKEY_LOG_DIR="$TMP/logs" python3 -I - "$ROOT" "$BENCH" "$TMP" <<'PY'
import json, subprocess, sys
from pathlib import Path
root, bench, tmp = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
golden = root / "core/test/golden"
items = [i for i in json.loads((golden / "manifest.json").read_text())["items"] if i["set"] in ("key-bench", "bpm-bench")]
jobs, wanted = [], {}
for it in items:
    src = bench / it["set"] / "audio" / it["name"]
    if not src.is_file():
        sys.exit(f"missing bench file {src}")
    info = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
                                      "stream=codec_name,sample_rate,channels", "-of", "json", str(src)],
                                     capture_output=True, check=True).stdout)["streams"][0]
    sr, nch, mp3 = int(info["sample_rate"]), min(int(info["channels"]), 2), info.get("codec_name") == "mp3"
    pcm = tmp / f"{it['id']}.pcm"
    cmd = ["ffmpeg", "-nostdin", "-v", "error"] + (["-c:a", "mp3"] if mp3 else []) + \
          ["-i", str(src), "-map", "0:a:0", "-ac", str(nch), "-f", "s16le" if mp3 else "f32le",
           "-c:a", "pcm_s16le" if mp3 else "pcm_f32le", "-y", str(pcm)]
    subprocess.run(cmd, check=True)
    jobs.append(f"{it['id']}\t{sr}\t{nch}\t{'s16' if mp3 else 'f32'}\t{pcm}")
    wanted[it["id"]] = it
out = subprocess.run([str(tmp / "clip_parity"), str(root / "models/deeptemp-k16-3.bkw")], input="\n".join(jobs) + "\n",
                     capture_output=True, text=True)
rows = [json.loads(l) for l in out.stdout.splitlines() if l.strip()]
if len(rows) != len(jobs):
    sys.exit(f"clip_parity answered {len(rows)} of {len(jobs)} jobs: {out.stderr[-2000:]}")
bad = 0
for r in rows:
    it = wanted[r["id"]]
    g = json.loads((golden / "files" / f"{r['id']}.json").read_text())
    miss = []
    if "error" in r:
        miss.append(r["error"])
    else:
        if r["frames"] != it["samples"]:
            miss.append(f"decoded {r['frames']} frames, the app had {it['samples']}")
        gk = [[k[0], round(k[1], 1)] for k in g["key"]["keys"]]
        ck = [[k[0], round(k[1], 1)] for k in r["keys"]]
        if gk != ck:
            miss.append(f"keys: app {gk} audiosuite {ck}")
        gt = g["key"]["tuning_cents"]   # None = the app offers no tuning (key under 50 %)
        if (gt is None) != (r["has_tuning"] == 0):
            miss.append(f"tuning offered: app {gt is not None} audiosuite {r['has_tuning'] == 1}")
        elif gt is not None and abs(gt - r["tuning_cents"]) > 0.5 + 1e-9:
            miss.append(f"tuning: app {gt} audiosuite {r['tuning_cents']:.2f}")
        t = g["tempo"]
        if t["bpm"] != round(r["bpm"], 1):
            miss.append(f"BPM: app {t['bpm']} audiosuite {r['bpm']}")
        if t["decided"] and abs(t["bpm_exact"] - r["bpm_exact"]) > 0.01 + 1e-9:
            miss.append(f"refined BPM: app {t['bpm_exact']} audiosuite {r['bpm_exact']:.4f}")
    if miss:
        bad += 1
        print(f"MISS {it['set']}/{it['name']}: " + "; ".join(miss))
    else:
        print(f"ok   {it['set']}/{it['name']}: {r['keys'][0][0]} {r['keys'][0][1]}%  {r['bpm_exact']:.2f} BPM")
print(f"AudioSuite parity: {len(rows) - bad} of {len(rows)} files give the app's key and BPM")
sys.exit(1 if bad else 0)
PY
echo "plugin/test/audiosuite-parity.sh: PASS"
