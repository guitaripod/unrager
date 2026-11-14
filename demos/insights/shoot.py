"""Shoots the raw pictures for the stats-on-your-posts carousel: x.com's own
web app, signed in, drawing Nora Lind's made-up profile (`xpatch`), with the
real browser extension from `browser/extension/` loaded and talking to
`mock_server`. Every capture is a clip of the live page at 4x, saved with the
rectangles of what the slides point at.

    python3 demos/insights/shoot.py OUT_DIR [--themes light,dim,dark]

Needs the X session `unrager` reads (`~/.cache/unrager/session-cache.json`)
and the running server's `/api/whoami` (to know whose answers to rewrite).
Headless Chromium keeps its shared memory in /dev/shm.
"""

from __future__ import annotations

import argparse
import asyncio
import colorsys
import hashlib
import json
import os
import re
import shutil
import sys
import urllib.request
from pathlib import Path

from PIL import Image
from playwright.async_api import async_playwright

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))

import mock_server  # noqa: E402
import world  # noqa: E402
from xpatch import Patcher, loads  # noqa: E402

EXT = REPO / "browser" / "extension"
APP_ASSETS = REPO / "demos" / "app" / "assets"
ASSETS = HERE / "assets"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
SCALE = 5
VIEW = {"width": 990, "height": 1500}
THEMES = {"light": 0, "dim": 1, "dark": 2}
HIDE_FLOATERS = """
  [data-testid="GrokDrawer"], [data-testid="chat-drawer-root"], [data-testid="DMDrawer"],
  [aria-label="Grok"][role="link"][style*="position"], [data-testid="BottomBar"] { visibility: hidden !important; }
  [data-testid="sidebarColumn"] { visibility: hidden !important; }
"""


def extension_id(path: Path) -> str:
    digest = hashlib.sha256(str(path).encode()).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in digest)


def hue_avatars() -> None:
    """The extra people's avatars: the app demo's, turned around the colour wheel."""
    (ASSETS / "avatars").mkdir(parents=True, exist_ok=True)
    for i in range(1, 17):
        src = APP_ASSETS / "avatars" / f"a{i:02d}.jpg"
        dst = ASSETS / "avatars" / f"h{i:02d}.jpg"
        if dst.exists():
            continue
        img = Image.open(src).convert("RGB")
        shift = (0.37 + i * 0.11) % 1.0
        px = img.load()
        for y in range(img.height):
            for x in range(img.width):
                r, g, b = px[x, y]
                h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
                r, g, b = colorsys.hsv_to_rgb((h + shift) % 1.0, s, v)
                px[x, y] = (int(r * 255), int(g * 255), int(b * 255))
        img.transpose(Image.Transpose.FLIP_LEFT_RIGHT).save(dst, quality=92)


def asset_for(url: str) -> Path | None:
    m = re.search(r"/profile_images/demo/(\w+?)_(?:normal|bigger|mini|reasonably_small|x96|\d+x\d+)\.jpg", url)
    if m:
        name = m.group(1)
        folder = ASSETS / "avatars" if name.startswith("h") else APP_ASSETS / "avatars"
        return folder / f"{name}.jpg"
    m = re.search(r"/profile_banners/demo/(\w+)", url)
    if m:
        return APP_ASSETS / "banners" / f"{m.group(1)}.jpg"
    m = re.search(r"/media/demo_(\w+)\.jpg", url) or re.search(r"/media/demo_(\w+)\?", url)
    if m:
        return APP_ASSETS / "photos" / f"{m.group(1)}.jpg"
    m = re.search(r"/card_img/demo/(\w+)", url)
    if m:
        return APP_ASSETS / "photos" / f"{m.group(1)}.jpg"
    return None


def whoami() -> dict:
    with urllib.request.urlopen("http://localhost:7777/api/whoami", timeout=10) as res:
        return json.load(res)


class Shoot:
    def __init__(self, out: Path, page, popup, patcher: Patcher, w: world.World, theme: str):
        self.out = out
        self.page = page
        self.popup = popup
        self.patcher = patcher
        self.world = w
        self.theme = theme
        self.meta: dict = {}

    async def wait_ready(self, post_key: str, kinds=("likes",), timeout=20000):
        pid = self.world.by_key[post_key]["id"]
        sel = " ".join([f'[data-unrager-insights="{pid}"]', f'.unrager-insights-slot[data-kind="{kinds[0]}"]'])
        await self.page.wait_for_selector(sel, timeout=timeout)
        await self.page.wait_for_timeout(1200)

    async def article_of(self, post_key: str):
        pid = self.world.by_key[post_key]["id"]
        return await self.page.evaluate_handle(
            """(pid) => { const bar = document.querySelector(`[data-unrager-insights="${pid}"]`);
                return bar && (bar.closest('article') || bar.closest('[role="link"][data-href]') || bar.parentElement.parentElement.parentElement); }""",
            pid,
        )

    async def scroll_to(self, post_key: str, top: int = 140):
        pid = self.world.by_key[post_key]["id"]
        await self.page.evaluate(
            """([pid, top]) => { const bar = document.querySelector(`[data-unrager-insights="${pid}"]`);
                const art = bar.closest('article') || bar.parentElement;
                window.scrollBy(0, art.getBoundingClientRect().top - top); }""",
            [pid, top],
        )
        await self.page.wait_for_timeout(900)

    async def rects(self, post_key: str) -> dict:
        """Where everything a slide may point at is, in page pixels."""
        pid = self.world.by_key[post_key]["id"]
        return await self.page.evaluate(
            """(pid) => {
              const box = (el) => { if (!el) return null; const r = el.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; };
              const bar = document.querySelector(`[data-unrager-insights="${pid}"]`)
                || [...document.querySelectorAll('article [role="group"]')].find(g => g.closest('article').querySelector(`a[href*="/status/${pid}"]`));
              const out = { bar: box(bar), article: box(bar && (bar.closest('article') || bar.closest('[role="link"][data-href]'))) };
              const controls = { replies: '[data-testid="reply"]', reposts: '[data-testid="retweet"]', likes: '[data-testid="like"]',
                views: 'a[href$="/analytics"]', bookmarks: '[data-testid="bookmark"]' };
              for (const [kind, sel] of Object.entries(controls)) {
                const control = bar && bar.querySelector(sel);
                out[`ctrl_${kind}`] = box(control && control.querySelector('svg'));
              }
              for (const host of document.querySelectorAll('.unrager-insights-slot')) {
                if (!bar || !(bar.contains(host) || (bar.closest('article') || bar.parentElement).contains(host))) continue;
                const kind = host.dataset.kind;
                out[`host_${kind}`] = box(host);
                for (const el of host.shadowRoot.querySelectorAll('.delta, .faces, .chip')) {
                  const key = el.classList.contains('chip') ? `chip_${el.dataset.icon}` : `${el.className}_${kind}`;
                  out[key] = box(el);
                }
              }
              const card = document.getElementById('unrager-insights-card');
              if (card && !card.hidden) {
                out.card = box(card.shadowRoot.querySelector('.card'));
                for (const [key, sel] of Object.entries({ chart: '.curve', tiles: '.tiles', tabs: '.tabs', hero: '.hero',
                  standing: '.standing', lenses: '.lenses', people: '.people', quotes: '.quotes', since: '.since', rows: '.people-row' })) {
                  out[`card_${key}`] = box(card.shadowRoot.querySelector(sel));
                }
                const follow = card.shadowRoot.querySelector('.follow');
                out.card_follow = box(follow);
              }
              return out;
            }""",
            pid,
        )

    async def grab(self, name: str, box, pad=(16, 16, 16, 16), post_key: str | None = None):
        left, top, width, height = box
        clip = {
            "x": max(0, left - pad[3]),
            "y": max(0, top - pad[0]),
            "width": width + pad[1] + pad[3],
            "height": height + pad[0] + pad[2],
        }
        path = self.out / f"{self.theme}-{name}.png"
        await self.page.screenshot(path=str(path), clip=clip, animations="disabled")
        marks = await self.rects(post_key) if post_key else {}
        self.meta[f"{self.theme}-{name}"] = {
            "clip": [clip["x"], clip["y"], clip["width"], clip["height"]],
            "scale": SCALE,
            "marks": {k: v for k, v in marks.items() if v},
        }
        print("  ", path.name, flush=True)

    async def union(self, *boxes):
        boxes = [b for b in boxes if b]
        left = min(b[0] for b in boxes)
        top = min(b[1] for b in boxes)
        right = max(b[0] + b[2] for b in boxes)
        bottom = max(b[1] + b[3] for b in boxes)
        return [left, top, right - left, bottom - top]

    async def set_insights(self, on: bool):
        await self.popup.evaluate("(off) => chrome.storage.local.set({ insightsOff: off })", not on)
        await self.page.bring_to_front()
        await self.page.wait_for_timeout(1500)

    async def card_shadow_click(self, selector: str, text: str | None = None):
        await self.page.evaluate(
            """([sel, text]) => { const c = document.getElementById('unrager-insights-card').shadowRoot;
                const el = [...c.querySelectorAll(sel)].find(e => !text || e.textContent.trim().startsWith(text));
                el.click(); }""",
            [selector, text],
        )
        await self.page.wait_for_timeout(1400)

    async def hover_host(self, post_key: str, kind: str):
        box = (await self.rects(post_key))[f"host_{kind}"]
        await self.page.mouse.move(box[0] + box[2] / 2, box[1] + box[3] / 2)

    async def click_host(self, post_key: str, kind: str):
        box = (await self.rects(post_key))[f"host_{kind}"]
        await self.page.mouse.click(box[0] + box[2] / 2, box[1] + box[3] / 2)


async def dismiss(page) -> None:
    for sel in ['button:has-text("Refuse non-essential cookies")', '[data-testid="sheetDialog"] button:has-text("Maybe Later")']:
        try:
            button = page.locator(sel).first
            if await button.count():
                await button.click(timeout=2000)
                await page.wait_for_timeout(500)
        except Exception:
            pass


async def install_routes(context, patcher: Patcher, me_paths: tuple[str, ...]) -> None:
    async def images(route):
        path = asset_for(route.request.url)
        if path and path.exists():
            await route.fulfill(path=str(path), content_type="image/jpeg")
        else:
            await route.continue_()

    async def graphql(route):
        url = route.request.url
        op = re.search(r"/graphql/[^/]+/(\w+)", url)
        op = op.group(1) if op else ""
        fetch_url = url
        if op == "UserByScreenName":
            fetch_url = url.replace(f"%22{world.ME}%22", f"%22{patcher.real_handle}%22")
        focal = None
        if op == "TweetDetail":
            m = re.search(r"focalTweetId%22%3A%22(\d+)", url)
            focal = m.group(1) if m else None
            if focal in patcher.world.by_id and patcher.template_post_id:
                fetch_url = url.replace(focal, patcher.template_post_id)
        try:
            response = await route.fetch(url=fetch_url)
        except Exception:
            await route.abort()
            return
        text = await response.text()
        body = loads(text)
        if body is not None:
            if op in ("UserTweets", "UserOriginalsTimeline"):
                body = patcher.timeline(body, page_after_first="cursor%22" in url)
            elif op == "TweetDetail" and focal in patcher.world.by_id:
                body = patcher.detail(body, focal)
            else:
                patcher.walk_users(body)
            text = json.dumps(body)
        await route.fulfill(response=response, body=patcher.text(text))

    async def document(route):
        if route.request.resource_type != "document":
            await route.continue_()
            return
        response = await route.fetch()
        await route.fulfill(response=response, body=patcher.text(await response.text()))

    await context.route(re.compile(r"https://pbs\.twimg\.com/(profile_images|profile_banners|media|card_img)/demo"), images)
    await context.route(re.compile(r"https://(api\.)?x\.com/i/api/graphql/"), graphql)
    await context.route(re.compile(r"https://(api\.)?x\.com/graphql/"), graphql)
    for path in me_paths:
        await context.route(re.compile(rf"https://x\.com{re.escape(path)}(\?.*)?$"), document)


async def run_theme(p, out: Path, theme: str, w: world.World, me: dict, session: dict, full: bool) -> dict:
    profile_dir = out / f".profile-{theme}"
    shutil.rmtree(profile_dir, ignore_errors=True)
    context = await p.chromium.launch_persistent_context(
        str(profile_dir), channel="chromium", headless=True, user_agent=UA,
        ignore_default_args=["--enable-automation", "--disable-extensions"],
        args=[f"--disable-extensions-except={EXT}", f"--load-extension={EXT}"],
        viewport=VIEW, device_scale_factor=SCALE, color_scheme="dark" if theme != "light" else "light",
    )
    cookies = [{"name": k, "value": session[k], "domain": ".x.com", "path": "/", "secure": True} for k in ("auth_token", "ct0", "twid")]
    cookies.append({"name": "night_mode", "value": str(THEMES[theme]), "domain": ".x.com", "path": "/", "secure": True})
    await context.add_cookies(cookies)
    server, port = mock_server.start(w, me["rest_id"])
    patcher = Patcher(w, me["rest_id"], me["handle"], me["name"])
    hero = w.by_key["hero"]
    await install_routes(context, patcher, (f"/{world.ME}", f"/{world.ME}/status/{hero['id']}"))
    popup = await context.new_page()
    await popup.goto(f"chrome-extension://{extension_id(EXT)}/popup.html")

    async def reseed():
        await popup.evaluate(
            """async ([server, seen]) => { await chrome.storage.session.clear();
                await chrome.storage.local.set({ server, insightsSeen: seen, insightsOff: false }); }""",
            [f"http://127.0.0.1:{port}", w.seen()],
        )

    await reseed()
    page = context.pages[0]
    await page.bring_to_front()
    await page.add_init_script(f"document.addEventListener('DOMContentLoaded', () => {{ const s = document.createElement('style'); s.textContent = {json.dumps(HIDE_FLOATERS)}; document.head.append(s); }});")
    shoot = Shoot(out, page, popup, patcher, w, theme)
    print(f"[{theme}] profile", flush=True)
    await page.goto(f"https://x.com/{world.ME}", wait_until="domcontentloaded")
    await page.wait_for_timeout(6000)
    await dismiss(page)
    await shoot.wait_ready("hero")
    await page.evaluate("document.fonts.ready")

    await shoot.scroll_to("hero", 120)
    r = await shoot.rects("hero")
    bar_box = [r["article"][0], r["bar"][1] - 6, r["article"][2], r["bar"][3] + 12]
    await shoot.grab("bar-hero", bar_box, (8, 0, 8, 0), "hero")
    await shoot.grab("post-hero", r["article"], (0, 0, 0, 0), "hero")
    if full:
        await shoot.set_insights(False)
        await shoot.grab("bar-hero-off", bar_box, (8, 0, 8, 0), "hero")
        await shoot.grab("post-hero-off", r["article"], (0, 0, 0, 0), "hero")
        await shoot.set_insights(True)
        await shoot.wait_ready("hero")

    views = r.get("host_views") or r.get("host_likes")
    await page.mouse.move(views[0] + views[2] / 2, views[1] + views[3] / 2)
    await page.wait_for_timeout(2200)
    r = await shoot.rects("hero")
    await shoot.grab("card-overview", r["card"], (0, 0, 0, 0), "hero")
    await shoot.grab("post-with-card", await shoot.union(r["article"], r["card"]), (0, 0, 24, 0), "hero")
    if full:
        chart = r["card_chart"]
        peak = w.by_key["hero"]["hourly"].index(max(w.by_key["hero"]["hourly"]))
        n = len(w.by_key["hero"]["hourly"])
        point = (chart[0] + chart[2] * (peak + 0.5) / n, chart[1] + chart[3] * 0.45)
        await page.mouse.move(views[0] + views[2] / 2, chart[1] - 30)
        await page.mouse.move(*point, steps=8)
        await page.wait_for_timeout(700)
        r = await shoot.rects("hero")
        await shoot.grab("chart-hover", r["card_chart"], (6, 8, 4, 8), "hero")
        shoot.meta[f"{theme}-chart-hover"]["hover"] = list(point)
        await shoot.grab("tiles", r["card_tiles"], (1, 1, 1, 1), "hero")

    await page.keyboard.press("Escape")
    await page.mouse.move(5, 5)
    await page.wait_for_timeout(600)
    await shoot.click_host("hero", "likes")
    await page.wait_for_timeout(2500)
    r = await shoot.rects("hero")
    await shoot.grab("card-likes", r["card"], (0, 0, 0, 0), "hero")
    if full:
        await shoot.card_shadow_click(".lens", "Follow back")
        r = await shoot.rects("hero")
        await shoot.grab("card-followback", r["card"], (0, 0, 0, 0), "hero")
        await shoot.card_shadow_click('[role="tab"]', "Reposts")
        await page.wait_for_timeout(1200)
        r = await shoot.rects("hero")
        await shoot.grab("card-reposts", r["card"], (0, 0, 0, 0), "hero")
        await shoot.card_shadow_click('[role="tab"]', "Quotes")
        await page.wait_for_timeout(1500)
        r = await shoot.rects("hero")
        await shoot.grab("card-quotes", r["card"], (0, 0, 0, 0), "hero")
        await page.keyboard.press("Escape")
        await page.mouse.move(5, 5)

        print(f"[{theme}] link post", flush=True)
        await shoot.scroll_to("link", 120)
        await shoot.wait_ready("link", ("views",))
        r = await shoot.rects("link")
        await shoot.grab("bar-link", [r["article"][0], r["bar"][1] - 6, r["article"][2], r["bar"][3] + 12], (8, 0, 8, 0), "link")
        await shoot.grab("post-link", r["article"], (0, 0, 0, 0), "link")
        await shoot.hover_host("link", "views")
        await page.wait_for_timeout(2200)
        r = await shoot.rects("link")
        await shoot.grab("card-overview-link", r["card"], (0, 0, 0, 0), "link")
        await page.keyboard.press("Escape")
        await page.mouse.move(5, 5)

        print(f"[{theme}] profile column", flush=True)
        await page.evaluate("window.scrollTo(0, 0)")
        await page.wait_for_timeout(1200)
        column = await page.evaluate("""() => { const c = document.querySelector('[data-testid="primaryColumn"]');
            const r = c.getBoundingClientRect(); return [r.left, 0, r.width, window.innerHeight]; }""")
        await shoot.grab("profile-column", column, (0, 0, 0, 0))

        print(f"[{theme}] post page", flush=True)
        await reseed()
        await page.bring_to_front()
        await page.goto(f"https://x.com/{world.ME}/status/{hero['id']}", wait_until="domcontentloaded")
        await page.wait_for_timeout(6000)
        await dismiss(page)
        await shoot.wait_ready("hero")
        r = await shoot.rects("hero")
        await shoot.grab("focal", r["article"] or r["bar"], (0, 0, 0, 0), "hero")

    await context.close()
    server.shutdown()
    return shoot.meta


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--themes", default="light,dim,dark")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    hue_avatars()
    session = json.load(open(os.path.expanduser("~/.cache/unrager/session-cache.json")))
    me = whoami()
    w = world.World()
    meta = {}
    async with async_playwright() as p:
        for theme in args.themes.split(","):
            meta.update(await run_theme(p, args.out, theme, w, me, session, full=(theme == "light")))
    (args.out / "meta.json").write_text(json.dumps(meta, indent=1))
    for profile in args.out.glob(".profile-*"):
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    asyncio.run(main())
