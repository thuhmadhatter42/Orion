#!/usr/bin/env python3
"""
core/tools/make_weights.py: the TempoCNN weights as the flat binary the core loads.

    python3 core/tools/make_weights.py models/deeptemp-k16-3.npz models/deeptemp-k16-3.bkw
    python3 core/tools/make_weights.py --check models/deeptemp-k16-3.npz models/deeptemp-k16-3.bkw

The .bkw is a format conversion of the .npz (itself a conversion of Essentia's deeptemp-k16-3
model, fine-tuned: models/README.md), so it carries the same licence, CC BY-NC-SA 4.0. It ships as
a separate data file beside the binary and is never compiled into it (plan L8).

Layout, little-endian: "BKW1", uint32 tensor count, then per tensor (names sorted):
  uint16 name length, name, uint32 ndim, uint32 dims[ndim], float32 data (C order).
--check exits 1 unless the .bkw on disk is byte-for-byte what the .npz gives now.
Needs numpy (any Python that has it; the bundled analyzer Python does).
"""

import struct
import sys


def encode(npz_path):
    import numpy as np
    out = [b"BKW1"]
    with np.load(npz_path) as z:
        names = sorted(z.files)
        out.append(struct.pack("<I", len(names)))
        for name in names:
            a = z[name]
            if a.dtype != np.float32:
                raise SystemExit(f"REFUSED: {name} is {a.dtype}, the core reads float32 only")
            if not np.isfinite(a).all():
                raise SystemExit(f"REFUSED: {name} holds a value that is not a number")
            raw = name.encode("ascii")
            out.append(struct.pack("<H", len(raw)) + raw)
            out.append(struct.pack("<I", a.ndim) + b"".join(struct.pack("<I", d) for d in a.shape))
            out.append(np.ascontiguousarray(a, "<f4").tobytes())
    return b"".join(out)


def main(argv):
    check = argv[:1] == ["--check"]
    args = argv[1:] if check else argv
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    npz, bkw = args
    data = encode(npz)
    if check:
        try:
            have = open(bkw, "rb").read()
        except OSError as exc:
            print(f"CHECK FAILED: cannot read {bkw}: {exc}", file=sys.stderr)
            return 1
        if have != data:
            print(f"CHECK FAILED: {bkw} is not what {npz} gives now; run make_weights.py again", file=sys.stderr)
            return 1
        print(f"CHECK OK: {bkw} matches {npz} ({len(data)} bytes)")
        return 0
    with open(bkw, "wb") as f:
        f.write(data)
    print(f"wrote {bkw} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
