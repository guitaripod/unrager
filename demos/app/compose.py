#!/usr/bin/env python3
"""Renders the iPhone app's marketing video from the framed clips `prep.py` made.

    python3 compose.py render [--out FILE] [--jobs N]
    python3 compose.py stills 4.5 20 33       # PNGs of single moments

The picture is a pure function of time, `frame_at(t)`: a background that
pulses with the song's beat, phones playing the recordings, captions, shock
rings and flashes, all laid out in `edit.py` in beats rather than seconds.
`render` cuts the timeline into one-second chunks, draws them in parallel and
joins them with the song's matching stretch.
"""

from __future__ import annotations

import argparse
import functools
import json
import math
import shutil
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

import edit

W, H, FPS = edit.WIDTH, edit.HEIGHT, edit.FPS
CHUNK_FRAMES = 60
FONT_FILE = "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf"
ENTER_SECONDS = 0.55
EXIT_SECONDS = 0.32
BACKGROUND_SCALE = 4


def clamp(x: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, x))


def lerp(a: float, b: float, x: float) -> float:
    return a + (b - a) * x


def ease_out_cubic(x: float) -> float:
    return 1 - (1 - x) ** 3


def ease_in_cubic(x: float) -> float:
    return x ** 3


def ease_out_back(x: float, overshoot: float = 1.5) -> float:
    c3 = overshoot + 1
    return 1 + c3 * (x - 1) ** 3 + overshoot * (x - 1) ** 2


def beat_time(n: float) -> float:
    """Seconds into the video at which song beat `n` lands."""
    return edit.BEAT_ZERO + edit.BEAT_SECONDS * n


def beat_pulse(t: float) -> float:
    """1 on a beat, falling away after it; downbeats hit harder than the others."""
    n = math.floor((t - edit.BEAT_ZERO) / edit.BEAT_SECONDS)
    if n < 0:
        return 0.0
    age = t - beat_time(n)
    return math.exp(-age / 0.17) * (1.0 if n % 4 == 0 else 0.4)


@functools.lru_cache(maxsize=None)
def font(size: int, weight: str = "Bold") -> ImageFont.FreeTypeFont:
    face = ImageFont.truetype(FONT_FILE, size)
    face.set_variation_by_name(weight)
    return face


@functools.lru_cache(maxsize=1)
def manifest() -> dict:
    path = Path(edit.CLIPS_DIR) / "manifest.json"
    return json.loads(path.read_text())


@functools.lru_cache(maxsize=1)
def grain() -> np.ndarray:
    """Fixed fine noise added to the background so its gradients don't band."""
    return np.random.default_rng(7).normal(0, 1.1, (H, W, 1)).astype(np.float32)


def palette_at(t: float) -> edit.Palette:
    """The palette in force at `t`, blended with the one before it just after a change."""
    current = edit.SECTIONS[0]
    previous = current
    for section in edit.SECTIONS:
        if t >= beat_time(section.beat):
            previous, current = current, section
    blend = ease_out_cubic(clamp((t - beat_time(current.beat)) / 0.7))
    return edit.blend_palettes(previous.palette, current.palette, blend)


@functools.lru_cache(maxsize=1)
def background_grid() -> tuple[np.ndarray, np.ndarray]:
    gh, gw = H // BACKGROUND_SCALE, W // BACKGROUND_SCALE
    ys, xs = np.mgrid[0:gh, 0:gw].astype(np.float32)
    return xs / gw, ys / gh


def background(t: float) -> Image.Image:
    """The gradient and the glows drifting through it, brighter on each beat."""
    palette = palette_at(t)
    xs, ys = background_grid()
    pulse = beat_pulse(t)
    top, bottom = np.array(palette.top, np.float32), np.array(palette.bottom, np.float32)
    mix = ys[..., None]
    image = top * (1 - mix) + bottom * mix
    for index, glow in enumerate(palette.glows):
        cx = glow.x + glow.sway * math.sin(t * glow.speed + index * 2.1)
        cy = glow.y + glow.sway * math.cos(t * glow.speed * 0.8 + index * 1.3)
        radius = glow.radius * (1 + 0.07 * pulse)
        distance = ((xs - cx) * (W / H)) ** 2 + (ys - cy) ** 2
        weight = np.exp(-distance / (2 * radius * radius)) * glow.strength * edit.GLOW_GAIN * (1 + 0.5 * pulse)
        image = image + weight[..., None] * np.array(glow.color, np.float32)
    small = Image.fromarray(np.clip(image, 0, 255).astype(np.uint8), "RGB")
    return small.resize((W, H), Image.BICUBIC)


def with_grain(image: Image.Image) -> Image.Image:
    arr = np.asarray(image.convert("RGB"), np.float32) + grain()
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")


class ClipReader:
    """Reads consecutive RGBA frames of a framed clip, scaled to one height."""

    def __init__(self, scene: str, start: float, height: int, first_index: int, speed: float = 1.0):
        entry = manifest()[scene]
        self.height = height
        self.width = int(round(height * entry["width"] / entry["height"] / 2)) * 2
        seek = start + first_index / FPS * speed
        self.proc = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-ss", f"{seek:.4f}", "-i", entry["path"],
             "-vf", f"setpts=PTS/{speed},fps={FPS},scale={self.width}:{self.height}:flags=lanczos",
             "-f", "rawvideo", "-pix_fmt", "rgba", "-"],
            stdout=subprocess.PIPE)
        self.index = first_index - 1
        self.last: Image.Image | None = None

    def frame(self, index: int) -> Image.Image:
        """Frame `index` of the clip; the last one again once the clip has ended."""
        size = self.width * self.height * 4
        while self.index < index:
            data = self.proc.stdout.read(size)
            if len(data) < size:
                break
            self.last = Image.frombuffer("RGBA", (self.width, self.height), data, "raw", "RGBA", 0, 1)
            self.index += 1
        if self.last is None:
            raise RuntimeError("clip produced no frames")
        return self.last

    def close(self) -> None:
        self.proc.stdout.close()
        self.proc.kill()
        self.proc.wait()


@dataclass
class Pose:
    cx: float
    cy: float
    height: float
    scale: float
    angle: float
    alpha: float


def ease_in_out(x: float) -> float:
    return x * x * (3 - 2 * x)


def layout_at(shot: edit.Shot, t: float) -> edit.Layout:
    """The shot's resting layout at `t`, after whatever moves it has made by then."""
    layout = shot.layout
    for move in shot.moves:
        start, end = beat_time(move.beat_in), beat_time(move.beat_out)
        progress = ease_in_out(clamp((t - start) / (end - start)))
        if progress <= 0:
            break
        target = move.layout
        layout = edit.Layout(
            lerp(layout.cx, target.cx, progress),
            lerp(layout.cy, target.cy, progress),
            layout.height * (target.height / layout.height) ** progress,
            lerp(layout.tilt, target.tilt, progress))
    return layout


def pose_at(shot: edit.Shot, t: float) -> Pose:
    """Where the shot's phone is at `t`: its resting place, moved by how it comes
    in and goes out, the beat and a slow float."""
    layout = layout_at(shot, t)
    result = Pose(layout.cx, layout.cy, layout.height, 1.0, layout.tilt, 1.0)
    t_in, t_out = beat_time(shot.beat_in), beat_time(shot.beat_out)

    coming = clamp((t - t_in) / ENTER_SECONDS)
    if coming < 1:
        apply_enter(result, shot.enter, coming)
    going = clamp((t - (t_out - EXIT_SECONDS)) / EXIT_SECONDS)
    if going > 0:
        apply_exit(result, shot.exit, going)

    if shot.pulse:
        result.scale *= 1 + 0.016 * beat_pulse(t)
    phase = layout.cx * 0.013
    result.cy += 6 * math.sin(2 * math.pi * t / 3.4 + phase)
    result.angle += 0.35 * math.sin(2 * math.pi * t / 4.6 + phase)
    return result


def apply_enter(pose: Pose, style: str, p: float) -> None:
    e = ease_out_cubic(p)
    if style == "rise":
        pose.cy += (1 - e) * 0.55 * H
        pose.scale *= 0.94 + 0.06 * e
        pose.alpha = clamp(p * 4)
    elif style == "drop":
        pose.cy -= (1 - e) * 0.7 * H
        pose.alpha = clamp(p * 4)
    elif style in ("left", "right"):
        sign = -1 if style == "left" else 1
        pose.cx += sign * (1 - e) * W * 0.95
        pose.angle += sign * (1 - e) * 9
        pose.alpha = clamp(p * 5)
    elif style == "pop":
        pose.scale *= lerp(0.55, 1.0, ease_out_back(p))
        pose.alpha = clamp(p * 5)
    elif style == "fade":
        pose.alpha = p


def apply_exit(pose: Pose, style: str, q: float) -> None:
    e = ease_in_cubic(q)
    if style == "up":
        pose.cy -= e * 0.75 * H
    elif style == "down":
        pose.cy += e * 0.75 * H
    elif style in ("left", "right"):
        sign = -1 if style == "left" else 1
        pose.cx += sign * e * W * 0.95
        pose.angle += sign * e * 8
    elif style == "shrink":
        pose.scale *= 1 - 0.3 * e
        pose.alpha = 1 - q
    elif style == "fade":
        pose.alpha = 1 - q


class ShotRenderer:
    """Draws one shot's phone, keeping its decoder open while the shot is on."""

    def __init__(self, shot: edit.Shot, t_first: float):
        self.shot = shot
        self.first_index = max(0, int(round((t_first - beat_time(shot.beat_in)) * FPS)))
        decode_height = int(round(shot.decode_height / 2)) * 2
        self.reader = ClipReader(shot.scene, shot.src, decode_height, self.first_index, shot.speed)
        self.shadow: Image.Image | None = None

    def draw(self, canvas: Image.Image, t: float) -> None:
        pose = pose_at(self.shot, t)
        if pose.alpha <= 0.002:
            return
        index = max(self.first_index, int(round((t - beat_time(self.shot.beat_in)) * FPS)))
        frame = self.reader.frame(index)
        layer = self.with_shadow(frame)
        factor = pose.scale * pose.height / frame.height
        size = (max(2, int(layer.width * factor)), max(2, int(layer.height * factor)))
        layer = layer.resize(size, Image.BILINEAR if factor < 1 else Image.BICUBIC)
        if abs(pose.angle) > 0.05:
            layer = layer.rotate(pose.angle, resample=Image.BICUBIC, expand=True)
        if pose.alpha < 0.999:
            alpha = layer.getchannel("A").point(lambda v: int(v * pose.alpha))
            layer.putalpha(alpha)
        paste_clipped(canvas, layer, int(pose.cx - layer.width / 2), int(pose.cy - layer.height / 2))

    def with_shadow(self, frame: Image.Image) -> Image.Image:
        """The frame on a padded canvas, over a soft shadow made once from its outline."""
        pad = 90
        if self.shadow is None:
            silhouette = Image.new("L", (frame.width + 2 * pad, frame.height + 2 * pad), 0)
            silhouette.paste(frame.getchannel("A"), (pad, pad + 26))
            blurred = silhouette.filter(ImageFilter.GaussianBlur(34)).point(lambda v: int(v * 0.55))
            shadow = Image.new("RGBA", silhouette.size, (0, 0, 0, 0))
            shadow.putalpha(blurred)
            self.shadow = shadow
        layer = self.shadow.copy()
        layer.alpha_composite(frame, (pad, pad))
        return layer

    def close(self) -> None:
        self.reader.close()


def paste_clipped(canvas: Image.Image, layer: Image.Image, x: int, y: int) -> None:
    """Alpha-composites `layer` at (x, y), dropping whatever falls off the canvas."""
    left, top = max(0, -x), max(0, -y)
    right, bottom = min(layer.width, canvas.width - x), min(layer.height, canvas.height - y)
    if right <= left or bottom <= top:
        return
    cropped = layer.crop((left, top, right, bottom))
    canvas.alpha_composite(cropped, (x + left, y + top))


@functools.lru_cache(maxsize=None)
def caption_image(caption: edit.Caption) -> Image.Image:
    """A caption drawn once: fitted to the width, accent words coloured, with a soft shadow."""
    size = caption.size
    lines = caption.text.split("\n")
    while size > 28 and max(line_width(strip_marks(line), size, caption.weight) for line in lines) > edit.TEXT_WIDTH:
        size -= 2
    face = font(size, caption.weight)
    line_height = int(size * 1.18)
    pad = 60
    image = Image.new("RGBA", (W, line_height * len(lines) + 2 * pad), (0, 0, 0, 0))
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    if caption.plate:
        draw_plate(image, lines, face, line_height, pad, caption.plate)
    for row, line in enumerate(lines):
        words = split_marks(line)
        total = sum(face.getlength(text) for text, _ in words)
        x = (W - total) / 2
        y = pad + row * line_height
        for text, accent in words:
            color = caption.accent if accent else caption.color
            ImageDraw.Draw(shadow).text((x, y + 4), text, font=face, fill=(0, 0, 0, 150))
            ImageDraw.Draw(image).text((x, y), text, font=face, fill=color)
            x += face.getlength(text)
    shadow = shadow.filter(ImageFilter.GaussianBlur(10))
    shadow.alpha_composite(image)
    return shadow


def draw_plate(image: Image.Image, lines: list[str], face: ImageFont.FreeTypeFont,
               line_height: int, pad: int, alpha: int) -> None:
    """A dark rounded plate behind a caption's lines, for text over a bright screen."""
    widest = max(face.getlength(strip_marks(line)) for line in lines)
    margin_x, margin_y = 40, 14
    box = ((W - widest) / 2 - margin_x, pad - margin_y + 4,
           (W + widest) / 2 + margin_x, pad + line_height * len(lines) + margin_y - 8)
    ImageDraw.Draw(image).rounded_rectangle(box, radius=(box[3] - box[1]) / 2 if len(lines) == 1 else 44,
                                            fill=(8, 10, 30, alpha))


def line_width(text: str, size: int, weight: str) -> float:
    return font(size, weight).getlength(text)


def strip_marks(line: str) -> str:
    return line.replace("*", "")


def split_marks(line: str) -> list[tuple[str, bool]]:
    """Splits `plain *accent* plain` into (text, is_accent) runs, spaces kept with their word."""
    runs: list[tuple[str, bool]] = []
    for index, part in enumerate(line.split("*")):
        if part:
            runs.append((part, index % 2 == 1))
    return runs


def draw_caption(canvas: Image.Image, caption: edit.Caption, t: float) -> None:
    t_in, t_out = beat_time(caption.beat_in), beat_time(caption.beat_out)
    if not t_in <= t < t_out:
        return
    coming = ease_out_cubic(clamp((t - t_in) / 0.45))
    going = clamp((t - (t_out - 0.28)) / 0.28)
    alpha = coming * (1 - going)
    if alpha <= 0.002:
        return
    layer = caption_image(caption)
    if alpha < 0.999:
        layer = layer.copy()
        layer.putalpha(layer.getchannel("A").point(lambda v: int(v * alpha)))
    rise = (1 - coming) * 46 - going * 22
    canvas.alpha_composite(layer, (0, int(caption.y - layer.height / 2 + rise)))


def draw_rings(canvas: Image.Image, t: float) -> None:
    """Thin rings spreading from the middle of the screen on the beats `edit.RINGS` names."""
    layer = None
    for beat, strength in edit.RINGS:
        age = t - beat_time(beat)
        if not 0 <= age < 1.0:
            continue
        if layer is None:
            layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        progress = ease_out_cubic(age)
        radius = progress * 1150
        alpha = int(255 * strength * (1 - age) ** 1.5)
        cx, cy = edit.RING_CENTER
        ImageDraw.Draw(layer).ellipse((cx - radius, cy - radius, cx + radius, cy + radius),
                                      outline=(255, 255, 255, alpha), width=5)
    if layer is not None:
        canvas.alpha_composite(layer)


@functools.lru_cache(maxsize=1)
def app_icon_image() -> Image.Image:
    """The app icon with the rounded-square mask iOS puts on it."""
    icon = Image.open(edit.ICON).convert("RGBA").resize((512, 512), Image.LANCZOS)
    mask = Image.new("L", (2048, 2048), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 2047, 2047), radius=460, fill=255)
    icon.putalpha(mask.resize((512, 512), Image.LANCZOS))
    return icon


def draw_icon(canvas: Image.Image, t: float) -> None:
    """The app icon popping in on the end card, with a soft shadow, nudged by each beat."""
    spec = edit.APP_ICON
    age = t - beat_time(spec.beat_in)
    if age < 0:
        return
    grow = ease_out_back(clamp(age / 0.65), 1.7)
    size = int(spec.size * grow * (1 + 0.025 * beat_pulse(t)))
    if size < 4:
        return
    icon = app_icon_image().resize((size, size), Image.LANCZOS)
    pad = 80
    shadow = Image.new("RGBA", (size + 2 * pad, size + 2 * pad), (0, 0, 0, 0))
    silhouette = Image.new("L", shadow.size, 0)
    silhouette.paste(icon.getchannel("A"), (pad, pad + 20))
    shadow.putalpha(silhouette.filter(ImageFilter.GaussianBlur(30)).point(lambda v: int(v * 0.6)))
    shadow.alpha_composite(icon, (pad, pad))
    shadow.putalpha(shadow.getchannel("A").point(lambda v: int(v * clamp(age / 0.2))))
    paste_clipped(canvas, shadow, int(spec.cx - shadow.width / 2), int(spec.cy - shadow.height / 2))


@functools.lru_cache(maxsize=1)
def scrim_image() -> Image.Image:
    """A dark fade down from the top edge, so captions stay readable over a phone that has grown past it."""
    rows = np.linspace(1.0, 0.0, edit.SCRIM_HEIGHT, dtype=np.float32) ** 2.2
    alpha = (rows * edit.SCRIM_STRENGTH * 255).astype(np.uint8)
    layer = np.zeros((edit.SCRIM_HEIGHT, W, 4), np.uint8)
    layer[..., 3] = alpha[:, None]
    return Image.fromarray(layer, "RGBA")


def draw_flash(canvas: Image.Image, t: float) -> None:
    level = 0.0
    for beat, strength in edit.FLASHES:
        age = t - beat_time(beat)
        if age >= 0:
            level = max(level, strength * math.exp(-age / 0.16))
    if level > 0.01:
        overlay = Image.new("RGBA", canvas.size, (255, 255, 255, int(255 * clamp(level))))
        canvas.alpha_composite(overlay)


class Scene:
    """Everything needed to draw frames of a stretch of the timeline."""

    def __init__(self, t_first: float):
        self.t_first = t_first
        self.renderers: dict[int, ShotRenderer] = {}

    def active_shots(self, t: float) -> list[tuple[int, edit.Shot]]:
        found = []
        for index, shot in enumerate(edit.SHOTS):
            if beat_time(shot.beat_in) <= t < beat_time(shot.beat_out):
                found.append((index, shot))
        return found

    def frame_at(self, t: float) -> Image.Image:
        canvas = background(t).convert("RGBA")
        for index, shot in self.active_shots(t):
            if index not in self.renderers:
                self.renderers[index] = ShotRenderer(shot, t)
            self.renderers[index].draw(canvas, t)
        draw_rings(canvas, t)
        draw_icon(canvas, t)
        canvas.alpha_composite(scrim_image())
        for caption in edit.CAPTIONS:
            draw_caption(canvas, caption, t)
        for index in [i for i in self.renderers if beat_time(edit.SHOTS[i].beat_out) <= t]:
            self.renderers.pop(index).close()
        draw_flash(canvas, t)
        return with_grain(canvas)

    def close(self) -> None:
        for renderer in self.renderers.values():
            renderer.close()
        self.renderers.clear()


def render_chunk(job: tuple[int, int, int, str]) -> str:
    """Draws frames [first, first + count) to an H.264 file and returns its path."""
    chunk, first, count, folder = job
    out = Path(folder) / f"chunk_{chunk:04d}.mp4"
    if out.exists():
        return str(out)
    partial = out.with_suffix(".part.mp4")
    encoder = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
         "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", "13",
         "-pix_fmt", "yuv420p", "-x264-params", "keyint=60:scenecut=0", str(partial)],
        stdin=subprocess.PIPE)
    scene = Scene(first / FPS)
    try:
        for index in range(first, first + count):
            encoder.stdin.write(scene.frame_at(index / FPS).tobytes())
    finally:
        scene.close()
        encoder.stdin.close()
        encoder.wait()
    partial.rename(out)
    return str(out)


def song_audio(out: Path) -> None:
    """The stretch of the song the edit was cut to, faded in and out."""
    fade_start = edit.DURATION - edit.FADE_OUT
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-ss", str(edit.SONG_START), "-t", str(edit.DURATION),
         "-i", edit.SONG, "-vn", "-af", f"afade=t=in:d=0.2,afade=t=out:st={fade_start}:d={edit.FADE_OUT}",
         "-c:a", "aac", "-b:a", "256k", str(out)], check=True)


def render(out: Path, jobs: int, fresh: bool) -> None:
    """Draws every chunk (those already in the work folder are kept, so a failed
    run resumes), then joins them with the song into `out`."""
    total = int(round(edit.DURATION * FPS))
    folder = out.with_suffix(".work")
    if fresh and folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True, exist_ok=True)
    chunks = [(i, first, min(CHUNK_FRAMES, total - first), str(folder))
              for i, first in enumerate(range(0, total, CHUNK_FRAMES))]
    with ProcessPoolExecutor(max_workers=jobs) as pool:
        paths = list(pool.map(render_chunk, chunks))
    print(f"drew {len(paths)} chunks", flush=True)
    listing = folder / "chunks.txt"
    listing.write_text("".join(f"file '{p}'\n" for p in paths))
    audio = folder / "song.m4a"
    song_audio(audio)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(listing),
         "-i", str(audio), "-c:v", "copy", "-c:a", "copy", "-movflags", "+faststart",
         "-shortest", str(out)], check=True)
    print(out)


def stills(times: list[float], folder: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    for t in times:
        scene = Scene(t)
        try:
            path = folder / f"still_{t:07.3f}.png"
            scene.frame_at(t).save(path)
            print(path)
        finally:
            scene.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("render")
    r.add_argument("--out", type=Path, default=Path("target/app-video/unrager-app.mp4"))
    r.add_argument("--jobs", type=int, default=20)
    r.add_argument("--fresh", action="store_true", help="redraw every chunk instead of resuming")
    s = sub.add_parser("stills")
    s.add_argument("times", type=float, nargs="+")
    s.add_argument("--out", type=Path, default=Path("/mnt/nvme8tb/unrager-demo/stills"))
    args = parser.parse_args()
    if args.command == "render":
        args.out.parent.mkdir(parents=True, exist_ok=True)
        render(args.out.resolve(), args.jobs, args.fresh)
    else:
        stills(args.times, args.out)


if __name__ == "__main__":
    sys.exit(main())
