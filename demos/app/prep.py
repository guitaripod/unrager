#!/usr/bin/env python3
"""Turns the raw simulator recordings into framed phone clips for `compose.py`.

    python3 prep.py [--raw DIR] [--out DIR] [--color White] [scene ...]

Each recording (`01Feed.mp4` ... from `record.sh`) is cut to the part of it that
shows the app, resampled to a constant 60 fps (the simulator records at a
variable rate) and put in an iPhone Air bezel by `frames video --alpha`, which
writes a ProRes 4444 clip with transparent corners. `manifest.json` in the
output directory lists every clip's path, size and length for `compose.py`.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

TRIMS: dict[str, tuple[float, float]] = {
    "01Feed": (3.9, 30.7),
    "02Filter": (3.9, 19.6),
    "03ComposeMenu": (3.2, 10.0),
    "04Stats": (5.5, 22.0),
    "05Thread": (5.8, 19.4),
    "06Profile": (3.6, 19.8),
    "07Ask": (20.0, 36.0),
    "08Settings": (3.8, 15.8),
    "09NotifList": (9.0, 35.4),
    "10NotifChips": (5.0, 29.6),
    "11NotifActions": (6.6, 31.2),
    "12NotifLive": (3.6, 29.6),
}


def run(cmd: list[str]) -> str:
    """Runs a command, returning its stdout and stopping the script on failure."""
    done = subprocess.run(cmd, capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(f"{' '.join(cmd[:3])} failed:\n{done.stderr[-1500:]}")
    return done.stdout


def probe(path: Path) -> dict:
    """Width, height and duration of a clip's video stream."""
    out = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
               "stream=width,height:format=duration", "-of", "json", str(path)])
    info = json.loads(out)
    stream = info["streams"][0]
    return {"width": stream["width"], "height": stream["height"],
            "duration": float(info["format"]["duration"])}


def trim_to_constant_rate(raw: Path, start: float, end: float, out: Path) -> None:
    """Cuts `raw` to [start, end] at a constant 60 fps, nearly lossless.

    The simulator only writes a frame when the screen changes, so the rate is
    fixed first (holding the last frame through still moments) and the cut made
    after it; seeking on the input would start the clip at the first change
    after `start` instead.
    """
    cut = f"fps=60,trim=start={start}:end={end},setpts=PTS-STARTPTS"
    run(["ffmpeg", "-v", "error", "-y", "-i", str(raw), "-vf", cut, "-an", "-c:v", "libx264",
         "-crf", "8", "-preset", "fast", "-pix_fmt", "yuv420p", str(out)])


def frame_clip(flat: Path, folder: Path, color: str) -> Path:
    """Puts a clip in the phone bezel, transparent outside it, and returns the new file."""
    run(["frames", "--json", "video", "--alpha", "--color", color, "-o", str(folder), str(flat)])
    framed = folder / f"{flat.stem}_framed.mov"
    if not framed.exists():
        sys.exit(f"frames wrote no {framed}")
    return framed


def prepare(scene: str, raw_dir: Path, out_dir: Path, color: str) -> dict:
    """The framed clip for one scene, and its manifest entry."""
    start, end = TRIMS[scene]
    flat = out_dir / "flat" / f"{scene}.mp4"
    trim_to_constant_rate(raw_dir / f"{scene}.mp4", start, end, flat)
    framed = frame_clip(flat, out_dir / "framed", color)
    return {"scene": scene, "path": str(framed.resolve()), **probe(framed)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scenes", nargs="*", help="scene names, default all")
    parser.add_argument("--raw", type=Path, default=Path("/mnt/nvme8tb/unrager-demo/raw"))
    parser.add_argument("--out", type=Path, default=Path("/mnt/nvme8tb/unrager-demo/clips"))
    parser.add_argument("--color", default="White")
    args = parser.parse_args()

    scenes = args.scenes or sorted(TRIMS)
    (args.out / "flat").mkdir(parents=True, exist_ok=True)
    (args.out / "framed").mkdir(parents=True, exist_ok=True)
    manifest_path = args.out / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}

    with ThreadPoolExecutor(max_workers=4) as pool:
        for entry in pool.map(lambda s: prepare(s, args.raw, args.out, args.color), scenes):
            manifest[entry["scene"]] = entry
            print(f"{entry['scene']}: {entry['width']}x{entry['height']} {entry['duration']:.1f}s")
    manifest_path.write_text(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
