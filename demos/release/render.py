#!/usr/bin/env python3
"""Render the release video: every frame of release.html in headless Chromium, the score from score.py, one MP4.

    python3 demos/release/render.py                  # full render into target/release-video/unrager.mp4
    python3 demos/release/render.py --stills 1 4.5   # a PNG of those moments, for checking a change
    python3 demos/release/render.py --preview        # a quick 30 fps, fast-encode pass
"""
import argparse
import base64
import http.server
import json
import multiprocessing
import pathlib
import resource
import shutil
import subprocess
import sys
import threading
from functools import partial
from io import BytesIO

import numpy as np
from PIL import Image
from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = ROOT / "target" / "release-video"
SIZE = 1080
PORT = 18791
SHUTTER = 0.5


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve() -> http.server.ThreadingHTTPServer:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), partial(Quiet, directory=str(HERE)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def open_page(p):
    """A headless Chromium on release.html, ready to seek.

    Playwright's default --disable-dev-shm-usage puts Chromium's shared memory in /tmp, which
    ten renderers at 1080p fill within a minute, crashing them all; /dev/shm is meant for it."""
    browser = p.chromium.launch(
        args=["--font-render-hinting=none", "--disable-lcd-text", "--force-color-profile=srgb"],
        ignore_default_args=["--disable-dev-shm-usage"],
    )
    page = browser.new_page(viewport={"width": SIZE, "height": SIZE}, device_scale_factor=1)
    page.goto(f"http://127.0.0.1:{PORT}/release.html", wait_until="networkidle")
    page.wait_for_function("window.__ready === true")
    return browser, page


def grab(page, cdp) -> bytes:
    shot = cdp.send(
        "Page.captureScreenshot",
        {"format": "png", "optimizeForSpeed": True, "clip": {"x": 0, "y": 0, "width": SIZE, "height": SIZE, "scale": 1}},
    )
    return base64.b64decode(shot["data"])


def render_frames(job):
    """One Chromium per worker, rendering every frame index in its share.

    Each frame averages `blur` moments spread across half a frame interval, a 180 degree shutter,
    so fast camera moves smear the way film does instead of strobing."""
    indices, fps, frame_dir, blur = job
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with sync_playwright() as p:
        browser, page = open_page(p)
        cdp = page.context.new_cdp_session(page)
        for i in indices:
            target = pathlib.Path(frame_dir) / f"f_{i:05d}.png"
            if blur <= 1:
                page.evaluate("t => seek(t)", i / fps)
                target.write_bytes(grab(page, cdp))
                continue
            acc = None
            for k in range(blur):
                offset = ((k + 0.5) / blur - 0.5) * SHUTTER
                page.evaluate("t => seek(t)", (i + offset) / fps)
                shot = np.asarray(Image.open(BytesIO(grab(page, cdp))).convert("RGB"), dtype=np.float32)
                acc = shot if acc is None else acc + shot
            Image.fromarray(np.clip(acc / blur + 0.5, 0, 255).astype(np.uint8)).save(target, compress_level=1)
        browser.close()
    return len(indices)


def page_facts():
    with sync_playwright() as p:
        browser, page = open_page(p)
        facts = page.evaluate("({ duration: window.DURATION, cues: window.CUES, scenes: window.SCENES })")
        browser.close()
    return facts


def stills(times):
    target = OUT / "stills"
    target.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser, page = open_page(p)
        cdp = page.context.new_cdp_session(page)
        for t in times:
            page.evaluate("t => seek(t)", t)
            path = target / f"t_{t:06.2f}.png"
            path.write_bytes(grab(page, cdp))
            print(path)
        browser.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stills", type=float, nargs="*")
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("--workers", type=int, default=max(2, min(10, multiprocessing.cpu_count() // 3)))
    parser.add_argument("--out", type=pathlib.Path)
    parser.add_argument("--blur", type=int, default=8, help="moments averaged into each frame (1 turns motion blur off)")
    args = parser.parse_args()

    server = serve()
    try:
        if args.stills is not None:
            stills(args.stills)
            return 0

        fps = 30 if args.preview else 60
        facts = page_facts()
        duration = facts["duration"]
        total = round(duration * fps)
        frame_dir = OUT / ("frames-preview" if args.preview else "frames")
        shutil.rmtree(frame_dir, ignore_errors=True)
        frame_dir.mkdir(parents=True)
        blur = 1 if args.preview else args.blur
        jobs = [(list(range(w, total, args.workers)), fps, str(frame_dir), blur) for w in range(args.workers)]
        with multiprocessing.get_context("spawn").Pool(args.workers) as pool:
            done = 0
            for n in pool.imap_unordered(render_frames, jobs):
                done += n
                print(f"frames {done}/{total}", flush=True)

        sys.path.insert(0, str(HERE))
        import score

        wav = OUT / "score.wav"
        score.render(facts["cues"], facts["scenes"], duration, wav)
        (OUT / "cues.json").write_text(json.dumps(facts["cues"], indent=1))

        out = args.out or OUT / f"unrager{'-preview' if args.preview else ''}.mp4"
        video = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"] if args.preview else [
            "-c:v", "libx264", "-preset", "slow", "-crf", "15", "-profile:v", "high", "-level:v", "4.2",
            "-tune", "animation", "-x264-params", "keyint=120:min-keyint=60:colorprim=bt709:transfer=bt709:colormatrix=bt709",
        ]
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-framerate", str(fps), "-i", str(frame_dir / "f_%05d.png"),
            "-i", str(wav),
            "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p",
            *video,
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
            "-movflags", "+faststart", "-shortest", str(out),
        ]
        subprocess.run(cmd, check=True)
        print(f"wrote {out} ({out.stat().st_size / 1e6:.1f} MB)")
        return 0
    finally:
        server.shutdown()


if __name__ == "__main__":
    sys.exit(main())
