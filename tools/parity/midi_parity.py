#!/usr/bin/env python3
"""
tools/parity/midi_parity.py: the core's MIDI reader (core/src/midi.cpp, bk_analyze_midi) against
midi_analyze.py, the reference (plan step 19: the app's MIDI drops move onto the core).

No MIDI files live in the repo, so the set is made here, seeded (the same files every run):
tests/test_bpm_extras.py's own cases, then random files that use every part of the format the
reader handles (several tracks, tempo changes, running status, velocity-0 note-offs, the drum
channel, notes left sounding, sysex, key signatures, programme changes, truncation, junk).

Pass = for every file, both refuse it, or both give the same BPM, the same decimal BPM and the
same three keys with the same percentages, exactly (no tolerance: the arithmetic is the same).

Run with a Python that has numpy (the reference needs it), from the repo root:
    bin/python/bin/python3 tools/parity/midi_parity.py --work <scratch dir> [--count 2000]
It builds core/build.noindex/midi_dump itself (core/build.sh first).
"""

import argparse
import json
import os
import random
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tests"))
sys.dont_write_bytecode = True

import midi_analyze  # noqa: E402


def vlq(n):
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    return bytes(reversed(out))


def track(events, end=True):
    return b"".join(vlq(d) + e for d, e in events) + (vlq(0) + b"\xFF\x2F\x00" if end else b"")


def smf(tracks, tpq=480):
    out = b"MThd" + struct.pack(">IHHH", 6, 1, len(tracks), tpq)
    for t in tracks:
        out += b"MTrk" + struct.pack(">I", len(t)) + t
    return out


def tempo(us):
    return b"\xFF\x51\x03" + us.to_bytes(3, "big")


def fixed_cases():
    """tests/test_bpm_extras.py TestMidi's files."""
    tune = [60, 64, 67, 72, 67, 64, 60, 60, 67, 67, 62, 65, 60] * 4
    a_minor = [69, 72, 76, 81, 76, 72, 69, 69, 76, 76, 71, 74, 69] * 4

    def notes(pitches, length=480, ch=0):
        ev = []
        for p in pitches:
            ev += [(0, bytes([0x90 | ch, p, 90])), (length, bytes([0x80 | ch, p, 0]))]
        return ev

    run = []
    for p in tune:
        run += [(0, bytes([0x90, p, 90])), (480, bytes([p, 0]))]
    full = smf([track(notes(tune))])
    return [
        smf([track([(0, tempo(428000))] + notes(tune))]),
        full,
        smf([track([(0, tempo(600000)), (4800, tempo(666667))] + notes(tune))]),
        smf([track([(0, b"\xFF\x59\x02\x03\x00")] + notes(tune))]),
        smf([track(notes(a_minor))]),
        smf([track(notes(tune)), track(notes([61, 63, 66, 68, 70] * 20, length=960, ch=9))]),
        smf([track(run)]),
        smf([track(notes([60, 64]))]),
        b"RIFF....",
        full[:-9],
        b"",
        b"MThd",
    ]


def random_file(rng):
    tracks = []
    for _ in range(rng.choice([1, 1, 2, 3, 5])):
        ev = []
        status = None
        sounding = []
        scale_root = rng.randrange(12)
        minor = rng.random() < 0.5
        steps = [0, 2, 3, 5, 7, 8, 10] if minor else [0, 2, 4, 5, 7, 9, 11]
        for _ in range(rng.randrange(0, 120)):
            r = rng.random()
            dt = rng.choice([0, 0, 1, 60, 120, 240, 480, 960, rng.randrange(20000)])
            if r < 0.03:
                ev.append((dt, tempo(rng.choice([300000, 428000, 500000, 600000, 666667, rng.randrange(1, 1 << 24)]))))
                status = None
            elif r < 0.04:
                ev.append((dt, b"\xFF\x59\x02" + bytes([rng.randrange(256), rng.randrange(2)])))
                status = None
            elif r < 0.05:
                ev.append((dt, b"\xF0" + vlq(3) + b"\x7E\x7F\xF7"))
                status = None
            elif r < 0.06:
                ch = rng.randrange(16)
                ev.append((dt, bytes([0xC0 | ch, rng.randrange(128)])))
                status = 0xC0 | ch
            elif r < 0.08:
                ch = rng.randrange(16)
                ev.append((dt, bytes([0xB0 | ch, 7, rng.randrange(128)])))
                status = 0xB0 | ch
            elif r < 0.6 or not sounding:
                ch = 9 if rng.random() < 0.1 else rng.choice([0, 0, 1, 2])
                pitch = (rng.randrange(3, 8) * 12 + scale_root + rng.choice(steps)) % 128 \
                    if rng.random() < 0.85 else rng.randrange(128)
                st = 0x90 | ch
                body = bytes([pitch, rng.randrange(1, 128)])
                ev.append((dt, body if status == st and rng.random() < 0.5 else bytes([st]) + body))
                status = st
                sounding.append((ch, pitch))
            else:
                ch, pitch = sounding.pop(rng.randrange(len(sounding)))
                if rng.random() < 0.5:
                    st, body = 0x90 | ch, bytes([pitch, 0])          # note on, velocity 0
                else:
                    st, body = 0x80 | ch, bytes([pitch, 64])
                ev.append((dt, body if status == st and rng.random() < 0.5 else bytes([st]) + body))
                status = st
        tracks.append(track(ev, end=rng.random() < 0.9))
    data = smf(tracks, tpq=rng.choice([96, 480, 960]))
    r = rng.random()
    if r < 0.05:
        data = data[:rng.randrange(len(data))]                       # cut short
    elif r < 0.08:
        i = rng.randrange(14, len(data)) if len(data) > 14 else 0
        data = data[:i] + bytes([rng.randrange(256)]) + data[i + 1:]  # one byte damaged
    return data


def reference(path):
    try:
        bpm, keys, extras = midi_analyze.analyze_midi(path)
    except Exception as exc:                                       # bpm.py would exit non-zero: no reading
        return {"error": type(exc).__name__}
    return {"bpm": bpm, "bpm_exact": extras["bpm_exact"], "keys": [[k, float(p)] for k, p in keys]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--count", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=19)
    a = ap.parse_args()
    work = Path(a.work)
    files = work / "midi"
    files.mkdir(parents=True, exist_ok=True)

    core = REPO / "core"
    subprocess.run(["sh", str(core / "build.sh")], check=True, stdout=subprocess.DEVNULL)
    dump = core / "build.noindex" / "midi_dump"
    subprocess.run(["clang", "-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=12.0", "-std=c99",
                    "-Wall", "-Wextra", "-Werror", "-I", str(core / "include"), str(core / "test" / "midi_dump.c"),
                    str(core / "build.noindex" / "libbeatkey.a"), "-lc++", "-framework", "Accelerate",
                    "-o", str(dump)], check=True)

    rng = random.Random(a.seed)
    datas = fixed_cases() + [random_file(rng) for _ in range(a.count)]
    paths = []
    for i, d in enumerate(datas):
        p = files / f"{i:05d}.mid"
        p.write_bytes(d)
        paths.append(p)

    env = dict(os.environ, BEATKEY_LOG_DIR=str(work / "logs"))
    ok = True
    for arch in ("arm64", "x86_64"):
        got = {}
        for i in range(0, len(paths), 500):
            out = subprocess.run(["arch", f"-{arch}", str(dump)] + [str(p) for p in paths[i:i + 500]],
                                 capture_output=True, text=True, check=True, env=env).stdout
            for line in out.splitlines():
                o = json.loads(line)
                got[o.pop("file")] = o
        miss = refused = 0
        for p in paths:
            want, have = reference(p), got[str(p)]
            if "error" in want or "error" in have:
                refused += "error" in want
                if ("error" in want) != ("error" in have):
                    miss += 1
                    print(f"MISS {arch} {p.name}: reference {want} core {have}")
                continue
            if want != have:
                miss += 1
                print(f"MISS {arch} {p.name}: reference {want} core {have}")
        print(f"{arch}: {len(paths) - miss}/{len(paths)} files identical ({refused} refused by both)")
        ok = ok and miss == 0
    print("MIDI PARITY OK" if ok else "MIDI PARITY FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
