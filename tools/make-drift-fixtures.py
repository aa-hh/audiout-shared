#!/usr/bin/env python3
# Copyright (C) 2026 ahh and contributors.
# SPDX-License-Identifier: MIT
"""Turn dumped passive-drift windows into the small fixtures ProbeKitTests loads.

Input: one or more directories of raw dumps written by the Mac app's
PassiveDriftSampler when `audiout.driftDumpWindows` is set —
`<stamp>-ref.f32` (outgoing mix, mono Float32 at referenceRate),
`<stamp>-cap.f32` (built-in mic, mono Float32 at captureRate) and
`<stamp>-meta.json` (referenceRate, captureRate, baselines).

Output: `<stamp>-<label>-{ref,cap}.i16` plus `<stamp>-<label>-meta.json`, and one
`manifest.json` indexing them all. Both signals are band-limited, resampled to
one common rate and stored as Int16 little-endian, which is about a fifth of the
raw size. The whole window is kept: trimming the reference to its arrival region
saves little over four seconds and would stop a fixture from being usable for a
full-range check.

Levels stay absolute. The correlator refuses a reference quieter than -50 dBFS,
so a fixture that silently renormalised would test a different signal. Each
signal records the full-scale float value its 32767 stands for, and a reader
multiplies by that to get the original amplitude back. That also keeps a capture
whose peaks went over 0 dBFS (a near-field bump at the Mac does) from clipping.

Labels: a `labels.txt` beside the dumps gives one line per window,
`<stamp> <label> [trueDelayMs]`, with `#` comments and blank lines ignored. The
stamp may be any leading part of the window's stamp. More label files can be
named with --labels, which is how the first four windows are labelled: they were
dumped before the recording runbook wrote a labels.txt, so their labels live in
`tools/drift-window-labels.txt` here instead. Windows no label file names take
--default-label. `trueDelayMs` is for a window recorded with a known forced trim
change, where the right answer is known rather than expected.

Usage:
  python3 tools/make-drift-fixtures.py <dump-dir> [<dump-dir> ...] \
      --out Tests/ProbeKitTests/Fixtures

Needs numpy + scipy (python3 -m venv v && v/bin/pip install numpy scipy).
"""
import argparse, glob, json, os, sys
import numpy as np
from scipy import signal

# 24 kHz is the rate PassiveDriftCorrelatorTests already works at, and it keeps
# the whole 300 Hz - 8 kHz band the correlator judges.
FIXTURE_RATE = 24_000
# Slightly wider than the correlator's own 300-8000 band, so a fixture can still
# answer a question about the band edges themselves.
BAND = (200.0, 8_000.0)
SIZE_BUDGET_BYTES = 5 * 1024 * 1024


def band_limit(x, rate, lo, hi):
    hi = min(hi, rate / 2 * 0.99)
    sos = signal.butter(4, [lo, hi], btype="band", fs=rate, output="sos")
    return signal.sosfiltfilt(sos, x)


def to_fixture(x, rate, out_rate):
    """Band-limited, resampled to out_rate, quantised. Returns (int16, fullScale)."""
    y = band_limit(np.asarray(x, dtype=np.float64), rate, *BAND)
    if rate != out_rate:
        g = np.gcd(int(rate), int(out_rate))
        y = signal.resample_poly(y, int(out_rate) // g, int(rate) // g)
    full_scale = float(max(np.max(np.abs(y)), 1e-9))
    return np.round(y / full_scale * 32767).astype("<i2"), full_scale


def read_labels(path):
    if not os.path.exists(path):
        return []
    rows = []
    for line in open(path):
        line = line.split("#", 1)[0].replace(",", " ").split()
        if len(line) >= 2:
            rows.append((line[0], line[1], float(line[2]) if len(line) > 2 else None))
    return rows


def label_for(stamp, rows, default):
    for prefix, label, true_delay in rows:
        if stamp.startswith(prefix) or prefix in stamp:
            return label, true_delay
    print(f"  no label for {stamp}, using {default!r}", file=sys.stderr)
    return default, None


def convert(stem, label, true_delay, out_dir, out_rate):
    stamp = os.path.basename(stem)
    meta = json.load(open(stem + "-meta.json"))
    ref = np.fromfile(stem + "-ref.f32", dtype="<f4")
    cap = np.fromfile(stem + "-cap.f32", dtype="<f4")
    ref_i16, ref_scale = to_fixture(ref, float(meta["referenceRate"]), out_rate)
    cap_i16, cap_scale = to_fixture(cap, float(meta["captureRate"]), out_rate)

    name = f"{stamp}-{label}"
    ref_i16.tofile(os.path.join(out_dir, name + "-ref.i16"))
    cap_i16.tofile(os.path.join(out_dir, name + "-cap.i16"))
    entry = {
        "name": name,
        "label": label,
        "referenceRate": out_rate,
        "captureRate": out_rate,
        "referenceCount": int(len(ref_i16)),
        "captureCount": int(len(cap_i16)),
        "referenceFullScale": ref_scale,
        "captureFullScale": cap_scale,
        "bandHz": list(BAND),
        "sourceReferenceRate": meta["referenceRate"],
        "sourceCaptureRate": meta["captureRate"],
        # Only the delay travels. The dump's baselines are keyed by the
        # speaker's Bluetooth address, and these fixtures are tracked in a
        # public repository.
        "baselines": [{"expectedDelayMs": b["expectedDelayMs"], "anchor": b.get("anchor", False)}
                      for b in meta["baselines"]],
    }
    if true_delay is not None:
        entry["trueDelayMs"] = true_delay
    json.dump(entry, open(os.path.join(out_dir, name + "-meta.json"), "w"),
              indent=2, sort_keys=True)
    return entry


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--rate", type=int, default=FIXTURE_RATE)
    ap.add_argument("--labels", action="append", default=[],
                    help="extra label file, repeatable; read after each dump directory's own")
    ap.add_argument("--default-label", default="good")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    extra = [row for path in args.labels for row in read_labels(path)]
    entries = []
    for directory in args.dirs:
        rows = read_labels(os.path.join(directory, "labels.txt")) + extra
        for path in sorted(glob.glob(os.path.join(directory, "*-meta.json"))):
            stem = path[: -len("-meta.json")]
            label, true_delay = label_for(os.path.basename(stem), rows, args.default_label)
            entry = convert(stem, label, true_delay, args.out, args.rate)
            entries.append(entry)
            print(f"  {entry['name']}  ref {entry['referenceCount']/args.rate:.2f}s  "
                  f"cap {entry['captureCount']/args.rate:.2f}s")

    entries.sort(key=lambda e: e["name"])
    json.dump({"rate": args.rate, "fixtures": entries},
              open(os.path.join(args.out, "manifest.json"), "w"), indent=2, sort_keys=True)

    total = sum(os.path.getsize(os.path.join(args.out, f)) for f in os.listdir(args.out))
    print(f"{len(entries)} fixtures, {total/1024/1024:.2f} MB in {args.out}")
    if total > SIZE_BUDGET_BYTES:
        sys.exit(f"over the {SIZE_BUDGET_BYTES/1024/1024:.0f} MB tracked-set budget")


if __name__ == "__main__":
    main()
