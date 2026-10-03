#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Generate synthetic inputs in a build directory; never commit the output.
set -euo pipefail
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <fixture-output-directory>" >&2
    exit 2
fi
for command in ffmpeg ffprobe python3; do
    command -v "$command" >/dev/null || { echo "Missing test dependency: $command" >&2; exit 1; }
done
mkdir -p "$1"
output="$(cd "$1" && pwd)"
temporary="$(mktemp -d "$output/.video-fixtures.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

# Luma identifies the original presentation index: Y = 32 + 4 * index.
# A non-lossless mode is deliberate: x264 disables B frames in lossless mode.
ffmpeg -nostdin -hide_banner -loglevel error \
    -f lavfi -i "nullsrc=size=160x96:rate=30,geq=lum='32+4*N':cb=128:cr=128" \
    -frames:v 18 -an -c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 18 -threads 1 \
    -x264-params 'bframes=2:b-adapt=0:b-pyramid=none:scenecut=0:keyint=60:aud=1:repeat-headers=1' \
    -f h264 "$temporary/reorder.h264"
ffprobe -v error -select_streams v:0 -show_frames \
    -show_entries frame=pkt_pos,pict_type -of json "$temporary/reorder.h264" > "$temporary/frames.json"
python3 - "$temporary" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
data = (root / "reorder.h264").read_bytes()
frames = json.loads((root / "frames.json").read_text())["frames"]
if len(frames) != 18 or not any(frame["pict_type"] == "B" for frame in frames):
    raise SystemExit("The generated test stream must contain 18 frames including B frames")
packets = sorted((int(frame["pkt_pos"]), index, frame["pict_type"])
                 for index, frame in enumerate(frames))
positions = [packet[0] for packet in packets]
if positions[0] != 0 or len(set(positions)) != len(packets):
    raise SystemExit("Expected one distinct Annex B access unit per decoded frame")
if [packet[1] for packet in packets] == list(range(18)):
    raise SystemExit("The B-frame fixture must actually reorder pictures")
with (root / "reorder.tsv").open("w") as manifest:
    for packet_index, (offset, presentation_index, picture_type) in enumerate(packets):
        end = positions[packet_index + 1] if packet_index + 1 < len(positions) else len(data)
        if not 0 <= offset < end <= len(data):
            raise SystemExit("Invalid packet boundaries reported by ffprobe")
        packet = data[offset:end]
        if not packet.startswith((b"\x00\x00\x00\x01\x09", b"\x00\x00\x01\x09")):
            raise SystemExit("Each test access unit must begin with an AUD")
        manifest.write(f"{offset}\t{end - offset}\t{presentation_index}\t{picture_type}\n")
PY

# Exceed the supported per-axis bound while keeping the sample cheap to encode.
ffmpeg -nostdin -hide_banner -loglevel error \
    -f lavfi -i 'color=red:size=4112x16:rate=1' -frames:v 1 -an \
    -c:v libx264 -pix_fmt yuv420p -preset ultrafast -tune zerolatency -threads 1 \
    -f h264 "$temporary/oversized.h264"
for name in reorder.h264 reorder.tsv oversized.h264; do
    mv "$temporary/$name" "$output/$name"
done
