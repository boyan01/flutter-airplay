#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Generate raw 512-sample AirPlay AAC-ELD packets (length-prefixed, big endian)."""
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as directory:
    wav = Path(directory) / "tone.wav"
    m4a = Path(directory) / "tone.m4a"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                    "sine=frequency=997:sample_rate=44100:duration=2", "-ac", "2", str(wav)], check=True)
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aace", str(wav), str(m4a)], check=True)
    info = json.loads(subprocess.check_output(["ffprobe", "-v", "quiet", "-show_streams",
                    "-show_data", "-show_packets", "-show_entries", "packet=pos,size:stream=extradata",
                    "-of", "json", str(m4a)]))
    # afconvert's default ELD profile is the same ASC sent by AirPlay at 512 spf.
    if "f8e8 4000" not in info["streams"][0]["extradata"]:
        raise SystemExit("Unexpected AAC-ELD ASC; expected f8 e8 40 00")
    data = m4a.read_bytes()
    Path(sys.argv[1]).write_bytes(b"".join(struct.pack(">I", int(p["size"])) +
        data[int(p["pos"]):int(p["pos"]) + int(p["size"])] for p in info["packets"]))
    print(f"Generated {len(info['packets'])} AAC-ELD access units, ASC f8e84000")
