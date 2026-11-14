"""Lays the raw captures from `shoot.py` out as the carousel's slides
(1080x1350 at 2x, so 2160x2700 PNGs) and renders them in headless Chromium.
Callouts point at what `shoot.py` recorded the position of, so they stay on
target when the captures change.

    python3 demos/insights/compose.py RAW_DIR OUT_DIR [--only 3,6]
"""

from __future__ import annotations

import argparse
import asyncio
import html
import json
from dataclasses import dataclass, field
from pathlib import Path

from playwright.async_api import async_playwright

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
FONTS = REPO / "demos" / "release" / "fonts"
ICON = REPO / "browser" / "extension" / "icons" / "128.png"
W, H = 1080, 1350
STAGE = (56, 452, 968, 838)
TEAL = "#14b8a6"
AMBER = "#f59e0b"
GREEN = "#00ba7c"
BLUE = "#1d9bf0"
PINK = "#f91880"


@dataclass
class Shot:
    name: str
    x: float
    y: float
    w: float
    crop: tuple[float, float, float, float] | None = None
    label: str | None = None
    radius: int = 26


@dataclass
class Callout:
    shot: int
    mark: str
    text: str
    color: str
    at: tuple[float, float]
    ring: bool = True
    anchor: str = "center"


@dataclass
class Slide:
    head: str
    sub: str
    shots: list[Shot] = field(default_factory=list)
    callouts: list[Callout] = field(default_factory=list)
    extra: str = ""
    dark_stage: bool = False


class Layout:
    def __init__(self, raw: Path):
        self.raw = raw
        self.meta = json.loads((raw / "meta.json").read_text())

    def clip(self, name: str) -> list[float]:
        return self.meta[name]["clip"]

    def area(self, shot: Shot) -> tuple[float, float, float, float]:
        """The part of the capture a shot shows, in page pixels."""
        x, y, w, h = self.clip(shot.name)
        if shot.crop:
            cx, cy, cw, ch = shot.crop
            return (cx, cy, cw, ch)
        return (x, y, w, h)

    def scale(self, shot: Shot) -> float:
        return shot.w / self.area(shot)[2]

    def height(self, shot: Shot) -> float:
        return self.area(shot)[3] * self.scale(shot)

    def to_slide(self, shot: Shot, box) -> tuple[float, float, float, float]:
        ax, ay, _, _ = self.area(shot)
        s = self.scale(shot)
        return (shot.x + (box[0] - ax) * s, shot.y + (box[1] - ay) * s, box[2] * s, box[3] * s)

    def mark(self, shot: Shot, key: str):
        return self.meta[shot.name]["marks"].get(key)


def fit(layout: Layout, name: str, max_w: float, max_h: float, crop=None, cx=None, top=None, label=None) -> Shot:
    """A shot as large as fits in `max_w` by `max_h`, centred on `cx`."""
    probe = Shot(name, 0, 0, 100, crop)
    area = layout.area(probe)
    scale = min(max_w / area[2], max_h / area[3])
    w = area[2] * scale
    h = area[3] * scale
    x = (cx if cx is not None else W / 2) - w / 2
    y = top if top is not None else STAGE[1] + (STAGE[3] - h) / 2
    return Shot(name, x, y, w, crop, label)


def bar_crop(layout: Layout, name: str, left_pad=10, right_pad=14, top_pad=16, bottom_pad=16):
    bar = layout.meta[name]["marks"]["bar"]
    return (bar[0] - left_pad, bar[1] - top_pad, bar[2] + left_pad + right_pad, bar[3] + top_pad + bottom_pad)


CSS = f"""
@font-face {{ font-family: Inter; src: url("file://{FONTS}/inter-var.woff2") format("woff2"); font-weight: 100 900; }}
@font-face {{ font-family: Mono; src: url("file://{FONTS}/jetbrains-mono-var.woff2") format("woff2"); font-weight: 100 800; }}
* {{ box-sizing: border-box; margin: 0; }}
html, body {{ width: {W}px; height: {H}px; background: #080b10; }}
.slide {{ position: relative; width: {W}px; height: {H}px; overflow: hidden; font-family: Inter, sans-serif; color: #f2f5f8;
  background: radial-gradient(circle at 50% 50%, transparent 60%, rgba(0,0,0,0.35)),
              radial-gradient(1100px 760px at 50% 78%, rgba(29,155,240,0.20), transparent 70%),
              radial-gradient(700px 520px at 92% 8%, rgba(20,184,166,0.10), transparent 70%),
              linear-gradient(180deg, #0a0e14 0%, #070a0f 100%); }}
header {{ position: absolute; left: 56px; right: 56px; top: 54px; display: flex; align-items: center; gap: 14px; }}
header img {{ width: 40px; height: 40px; border-radius: 10px; }}
.brand {{ font-weight: 700; font-size: 25px; letter-spacing: -0.2px; }}
.kick {{ font-weight: 600; font-size: 19px; letter-spacing: 2.4px; text-transform: uppercase; color: {BLUE}; margin-left: 6px; }}
.count {{ margin-left: auto; font: 500 21px Mono, monospace; color: #6b7685; }}
h1 {{ position: absolute; left: 56px; right: 56px; top: 132px; font-weight: 800; font-size: 76px; line-height: 1.04; letter-spacing: -2.2px; }}
h1 em {{ font-style: normal; color: {BLUE}; }}
.sub {{ position: absolute; left: 58px; right: 70px; font-size: 31px; line-height: 1.36; color: #a3adbb; letter-spacing: -0.2px; }}
.shot {{ position: absolute; overflow: hidden; box-shadow: 0 34px 90px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.10); }}
.shot img {{ position: absolute; display: block; }}
.tag {{ position: absolute; font: 700 18px Inter; letter-spacing: 2px; text-transform: uppercase; color: #8b96a5; }}
.tag.on {{ color: {BLUE}; }}
svg.over {{ position: absolute; inset: 0; width: {W}px; height: {H}px; overflow: visible; }}
.call {{ position: absolute; display: flex; align-items: center; gap: 10px; font-weight: 650; font-size: 26px; line-height: 1.15;
  padding: 10px 18px 10px 14px; border-radius: 999px; background: rgba(12,16,22,0.92); white-space: nowrap;
  box-shadow: 0 10px 30px rgba(0,0,0,0.45), 0 0 0 1.5px var(--c); color: #f2f5f8; }}
.call i {{ width: 14px; height: 14px; border-radius: 50%; background: var(--c); box-shadow: 0 0 14px var(--c); flex: none; }}
.call small {{ display: block; font-weight: 500; font-size: 20px; color: #a3adbb; }}
.legend {{ position: absolute; display: flex; gap: 34px; font-size: 27px; color: #c6ced8; }}
.legend span {{ display: inline-flex; align-items: center; gap: 12px; }}
.legend b {{ width: 30px; height: 30px; border-radius: 50%; border: 5px solid var(--c); background: #1b2230; }}
code, .cmd {{ font-family: Mono, monospace; }}
"""


def shot_html(layout: Layout, raw: Path, shot: Shot) -> str:
    x, y, w, h = layout.clip(shot.name)
    ax, ay, aw, ah = layout.area(shot)
    s = layout.scale(shot)
    img = f"file://{raw / (shot.name + '.png')}"
    out = (
        f'<div class="shot" style="left:{shot.x:.1f}px;top:{shot.y:.1f}px;width:{aw * s:.1f}px;height:{ah * s:.1f}px;border-radius:{shot.radius}px">'
        f'<img src="{img}" style="left:{(x - ax) * s:.2f}px;top:{(y - ay) * s:.2f}px;width:{w * s:.2f}px;height:{h * s:.2f}px"></div>'
    )
    if shot.label:
        on = " on" if "unrager" in shot.label.lower() else ""
        out += f'<div class="tag{on}" style="left:{shot.x + 4:.1f}px;top:{shot.y - 34:.1f}px">{html.escape(shot.label)}</div>'
    return out


def callouts_html(layout: Layout, slide: Slide) -> str:
    svg = []
    labels = []
    for c in slide.callouts:
        shot = slide.shots[c.shot]
        box = layout.mark(shot, c.mark)
        if not box:
            print(f"   missing mark {c.mark} in {shot.name}")
            continue
        sx, sy, sw, sh = layout.to_slide(shot, box)
        mx, my = sx + sw / 2, sy + sh / 2
        lx, ly = c.at
        if c.ring:
            pad = 13
            svg.append(
                f'<rect x="{sx - pad:.1f}" y="{sy - pad:.1f}" width="{sw + 2 * pad:.1f}" height="{sh + 2 * pad:.1f}" rx="{min(sh + 2 * pad, 40) / 2:.1f}" '
                f'fill="none" stroke="{c.color}" stroke-width="3.5" />'
            )
            target_y = sy - pad if ly < sy else sy + sh + pad
        else:
            target_y = my
        svg.append(
            f'<path d="M{lx:.1f} {ly:.1f} L{mx:.1f} {target_y:.1f}" stroke="{c.color}" stroke-width="3" fill="none" stroke-linecap="round" opacity="0.95"/>'
            f'<circle cx="{mx:.1f}" cy="{target_y:.1f}" r="5" fill="{c.color}"/>'
        )
        text = c.text.split("\n")
        body = html.escape(text[0]) + ("".join(f"<small>{html.escape(t)}</small>" for t in text[1:]))
        shift = {"center": "-50%", "left": "0%", "right": "-100%"}[c.anchor]
        labels.append(
            f'<div class="call" style="--c:{c.color};left:{lx:.1f}px;top:{ly:.1f}px;transform:translate({shift},-50%)"><i></i><span>{body}</span></div>'
        )
    return f'<svg class="over">{"".join(svg)}</svg>' + "".join(labels)


def page(layout: Layout, raw: Path, slide: Slide, index: int, total: int) -> str:
    sub_top = 132 + 80 * (slide.head.count("<br>") + 1) + 26
    shots = "".join(shot_html(layout, raw, s) for s in slide.shots)
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head><body>
<div class="slide">
  <header><img src="file://{ICON}"><span class="brand">unrager</span><span class="kick">Stats on your posts</span>
    <span class="count">{index:02d} / {total:02d}</span></header>
  <h1>{slide.head}</h1>
  <p class="sub" style="top:{sub_top}px">{slide.sub}</p>
  {shots}
  {callouts_html(layout, slide)}
  {slide.extra}
</div></body></html>"""


CURSOR = (
    '<svg style="position:absolute;left:{x:.1f}px;top:{y:.1f}px;width:34px;height:46px;overflow:visible;filter:drop-shadow(0 4px 8px rgba(0,0,0,.45))" viewBox="0 0 17 23">'
    '<path d="M1 1 L1 18.5 L5.4 14.6 L8.3 21.4 L11.4 20 L8.6 13.4 L14.6 13.2 Z" fill="#fff" stroke="#111" stroke-width="1.3" stroke-linejoin="round"/></svg>'
)


def cursor_at(layout: Layout, shot: Shot, mark: str, fx=0.5, fy=0.55) -> str:
    box = layout.mark(shot, mark)
    if not box:
        return ""
    x, y, w, h = layout.to_slide(shot, box)
    return CURSOR.format(x=x + w * fx, y=y + h * fy)


def span(L: Layout, name: str, first: str, last: str, pad_x=14, top=16, bottom=16, extra_top=0, pad_left=None):
    """The stretch of a post's bar from one control to the end of another's
    additions, as a crop."""
    marks = L.meta[name]["marks"]
    bar = marks["bar"]
    a = marks.get(first) or bar
    b = marks.get(last) or bar
    left = a[0] - (pad_x if pad_left is None else pad_left)
    right = b[0] + b[2] + pad_x
    return (left, bar[1] - top - extra_top, right - left, bar[3] + top + bottom + extra_top)


def guides(L: Layout, shots: list[Shot], kinds=("replies", "reposts", "likes", "views", "bookmarks")) -> str:
    """Dashed lines through each of X's icons, across every shot, to show
    nothing moved."""
    lines = []
    top = shots[0].y - 18
    bottom = shots[-1].y + L.height(shots[-1]) + 18
    for kind in kinds:
        box = L.mark(shots[0], f"ctrl_{kind}")
        if not box:
            continue
        x, _, w, _ = L.to_slide(shots[0], box)
        cx = x + w / 2
        lines.append(f'<line x1="{cx:.1f}" y1="{top:.1f}" x2="{cx:.1f}" y2="{bottom:.1f}" stroke="{BLUE}" stroke-width="2.5" stroke-dasharray="7 9" opacity="0.75"/>')
    return f'<svg class="over" style="z-index:2">{"".join(lines)}</svg>'


def card_shot(L: Layout, name: str, w: float, cx: float, top: float) -> Shot:
    shot = fit(L, name, w, 10_000, cx=cx, top=top)
    shot.radius = round(16 * L.scale(shot))
    return shot


def slides(L: Layout) -> list[Slide]:
    out: list[Slide] = []
    left = 56

    post = Shot("light-post-hero", 56, 440, 968)
    card = card_shot(L, "light-card-overview", 440, W - 56 - 220 - 30, post.y + L.height(post) - 10)
    out.append(Slide(
        "Your posts, <em>at a glance.</em>",
        "Who liked it, link clicks, new followers: in X's own action bar, without a click. Hover for the rest.",
        [post, card],
        extra=cursor_at(L, post, "chip_follows", 0.3, 0.6),
    ))

    off = Shot("light-post-hero-off", 56, 560, 968, label="X as it is")
    on = Shot("light-post-hero", 56, 560 + L.height(off) + 110, 968, label="X with unrager")
    out.append(Slide(
        "Nothing on the<br>page <em>moves.</em>",
        "Everything sits in the gaps X's bar already leaves. What doesn't fit is simply left out.",
        [off, on],
        extra=guides(L, [off, on]) + f'<div class="legend" style="left:58px;top:{on.y + L.height(on) + 64:.0f}px;color:#8b96a5;font-size:26px">Same post, same bar, same height.</div>',
    ))

    hero_crop = span(L, "light-bar-hero", "ctrl_reposts", "host_likes", top=12, bottom=12)
    a = fit(L, "light-bar-hero", 968, 330, crop=hero_crop, top=790)
    out.append(Slide(
        "See <em>who</em> liked it.",
        "The latest people to like and repost a post sit beside those counts, ringed by how they know you.",
        [a],
        [
            Callout(0, "faces_reposts", "Field Notes & Lena Park\nLena follows you", AMBER, (330, 660)),
            Callout(0, "faces_likes", "Mira Koski\nmutual", TEAL, (830, 660)),
        ],
        extra=f'<div class="legend" style="left:58px;top:{a.y + L.height(a) + 90:.0f}px"><span style="--c:{TEAL}"><b></b>mutual</span><span style="--c:{AMBER}"><b></b>follows you</span><span style="--c:#6b7685"><b></b>you follow / neither</span></div>',
    ))

    crop = span(L, "light-bar-hero", "ctrl_replies", "host_likes", top=12, bottom=12)
    bar = Shot("light-bar-hero", 56, 820, 968, crop)
    out.append(Slide(
        "What changed since<br>you <em>last looked.</em>",
        "Every count that rose since you last saw the post gets a green +N. No more comparing numbers in your head.",
        [bar],
        [
            Callout(0, "delta_replies", "+2 replies", GREEN, (250, 710)),
            Callout(0, "delta_reposts", "+2 reposts", GREEN, (560, bar.y + L.height(bar) + 110)),
            Callout(0, "delta_likes", "+17 likes", GREEN, (820, 710)),
        ],
        extra='<div class="legend" style="left:58px;top:1240px;color:#8b96a5;font-size:26px">Views only get one for a real jump, since they climb all the time.</div>',
    ))

    link = fit(L, "light-bar-link", 968, 210, crop=span(L, "light-bar-link", "ctrl_likes", "ctrl_bookmarks", top=12, bottom=12, pad_left=6), top=720)
    hero = fit(L, "light-bar-hero", 968, 210, crop=span(L, "light-bar-hero", "ctrl_likes", "ctrl_bookmarks", top=12, bottom=12, pad_left=6), top=1070)
    out.append(Slide(
        "Link clicks and<br>new followers.",
        "The numbers X keeps two clicks deep, beside the views. A green dot: it rose since your last look.",
        [link, hero],
        [
            Callout(0, "chip_link", "214 people clicked the link\n+54 since you looked", BLUE, (560, 650)),
            Callout(1, "chip_follows", "9 new followers\nfrom this post", GREEN, (620, 1000)),
        ],
    ))

    card = card_shot(L, "light-card-overview", 576, W - 56 - 288, 466)
    out.append(Slide(
        "Hover for the <em>whole story.</em>",
        "X's analytics for the post, in a card right over it.",
        [card],
        [
            Callout(0, "card_hero", "Impressions,\nshare engaged", BLUE, (left + 140, 640)),
            Callout(0, "card_since", "Rise since\nyour last look", GREEN, (left + 140, 790)),
            Callout(0, "card_chart", "Hour by hour", BLUE, (left + 130, 930)),
            Callout(0, "card_tiles", "Every figure\nX counts", BLUE, (left + 130, 1090)),
            Callout(0, "card_rows", "Who liked\nand reposted", PINK, (left + 140, 1250)),
        ],
    ))

    chart = fit(L, "light-chart-hover", 968, 560, top=640)
    out.append(Slide(
        "Every hour of its<br><em>first two days.</em>",
        "Point at a bar to read the hour. One line says how fast the reach came.",
        [chart],
        extra=_hover_cursor(L, chart),
    ))

    tiles = fit(L, "light-tiles", 968, 560, top=620)
    tiles.radius = round(12 * L.scale(tiles))
    out.append(Slide(
        "Everything X keeps<br>behind <em>Analytics.</em>",
        "Engagements, detail expands, profile visits, link clicks, new follows and bookmarks, each with what it gained since your last look.",
        [tiles],
    ))

    card = card_shot(L, "light-card-likes", 580, W - 56 - 290, 470)
    out.append(Slide(
        "Everyone who <em>liked it.</em>",
        "How each of them stands with you, and filters to find who matters.",
        [card],
        [
            Callout(0, "card_standing", "Mutual, follows you,\nyou follow", TEAL, (left, 600), anchor="left"),
            Callout(0, "card_lenses", "Filters", BLUE, (left, 790), anchor="left"),
            Callout(0, "card_follow", "Follow back\nin one click", PINK, (left, 960), anchor="left"),
        ],
    ))

    card = card_shot(L, "light-card-followback", 580, W / 2, 470)
    out.append(Slide(
        "Follow back in<br><em>one click.</em>",
        "People who follow you and liked your post, but you don't follow yet.",
        [card],
    ))

    card = card_shot(L, "light-card-reposts", 580, W / 2, 470)
    out.append(Slide(
        "Who <em>reposted</em> it.",
        "The Reposted by list X keeps a few taps away, with the same rings and filters.",
        [card],
    ))

    card = card_shot(L, "light-card-quotes", 680, W / 2, 470)
    out.append(Slide(
        "What they said<br>when they <em>quoted</em> it.",
        "Every quote of your post, newest first. Click one to open it.",
        [card],
    ))

    focal = fit(L, "light-focal", 968, 760, top=560)
    out.append(Slide(
        "On a post's own<br>page, <em>too.</em>",
        "Home, your profile, threads and a post's page, in both of X's web apps.",
        [focal],
    ))

    shots = []
    y = 470
    for name, label in (("light-post-hero", "Light"), ("dim-post-hero", "Dim"), ("dark-post-hero", "Lights out")):
        if name not in L.meta:
            continue
        s = Shot(name, 56, y + 40, 968, label=label)
        shots.append(s)
        y += L.height(s) + 70
    out.append(Slide(
        "Light, dim or<br><em>lights out.</em>",
        "",
        shots,
    ))

    diagram = f"""
    <div style="position:absolute;left:56px;right:56px;top:470px;display:grid;gap:26px">
      {''.join(f'''<div style="display:flex;align-items:center;gap:28px;padding:32px 36px;border-radius:24px;background:rgba(255,255,255,0.045);box-shadow:0 0 0 1px rgba(255,255,255,0.09)">
        <div style="width:70px;height:70px;border-radius:20px;display:grid;place-items:center;font:800 34px Inter;background:{c};color:#080b10;flex:none">{n}</div>
        <div><div style="font:700 36px Inter;letter-spacing:-0.5px">{t}</div><div style="font:400 27px Inter;color:#a3adbb;margin-top:8px;line-height:1.35">{d}</div></div></div>'''
        for n, c, t, d in [
            ("1", BLUE, "x.com, as you use it now", "The unrager browser extension draws into X's own page."),
            ("2", TEAL, "unrager, on your computer", "The extension asks it, and only it, over localhost."),
            ("3", AMBER, "X, as you", "unrager reads your posts' analytics and likers with your own login, and leaves most of X's request budget alone."),
        ])}
      <div style="font:500 30px Inter;color:#c6ced8;margin-top:22px;line-height:1.45">No server of mine in between. No account, no tracking.<br>Free and open source.</div>
    </div>"""
    out.append(Slide("Runs on <em>your</em><br>computer.", "", extra=diagram))

    cta = f"""
    <div style="position:absolute;left:56px;right:56px;top:430px;display:flex;flex-direction:column;align-items:center;text-align:center">
      <img src="file://{ICON}" style="width:210px;height:210px;border-radius:46px;box-shadow:0 30px 90px rgba(29,155,240,0.35)">
      <div style="font:800 68px Inter;letter-spacing:-1.8px;margin-top:50px;line-height:1.08">Keep x.com.<br><span style="color:{BLUE}">Lose the rage.</span></div>
      <div style="font:400 31px Inter;color:#a3adbb;margin-top:30px;max-width:880px;line-height:1.42">unrager hides rage bait from your timeline with a model on your own computer, and shows the stats on your own posts.</div>
      <div style="margin-top:50px;padding:24px 38px;border-radius:18px;background:rgba(255,255,255,0.05);box-shadow:0 0 0 1px rgba(255,255,255,0.14);font:600 40px Mono;color:#f2f5f8">midgarcorp.cc/unrager</div>
    </div>"""
    out.append(Slide("Get <em>unrager.</em>", "", extra=cta))
    return out


def _hover_cursor(L: Layout, chart: Shot) -> str:
    """The pointer over the chart's highlighted hour."""
    meta = L.meta[chart.name]
    hover = meta.get("hover")
    if not hover:
        return ""
    x, y = hover
    ax, ay, _, _ = L.area(chart)
    s = L.scale(chart)
    return CURSOR.format(x=chart.x + (x - ax) * s, y=chart.y + (y - ay) * s)


async def render(raw: Path, out: Path, only: set[int] | None) -> None:
    layout = Layout(raw)
    deck = slides(layout)
    out.mkdir(parents=True, exist_ok=True)
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--allow-file-access-from-files"])
        ctx = await browser.new_context(viewport={"width": W, "height": H}, device_scale_factor=2)
        page_ = await ctx.new_page()
        for i, slide in enumerate(deck, 1):
            if only and i not in only:
                continue
            doc = out / f"slide-{i:02d}.html"
            doc.write_text(page(layout, raw, slide, i, len(deck)))
            await page_.goto(f"file://{doc}")
            await page_.evaluate("document.fonts.ready")
            await page_.wait_for_timeout(250)
            await page_.screenshot(path=str(out / f"slide-{i:02d}.png"))
            doc.unlink()
            print(f"   slide {i:02d}", flush=True)
        await browser.close()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("raw", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    only = {int(n) for n in args.only.split(",") if n} or None
    asyncio.run(render(args.raw.resolve(), args.out.resolve(), only))


if __name__ == "__main__":
    main()
