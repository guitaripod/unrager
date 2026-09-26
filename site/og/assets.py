#!/usr/bin/env python3
"""Render the README's images from the landing page's mocks (mocked posts, no real accounts)."""
import http.server
import pathlib
import shutil
import subprocess
import sys
import threading
from functools import partial

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
PUBLIC = ROOT / "public"
ASSETS = ROOT.parent / "assets"
PORT = 18790


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main() -> int:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), partial(Quiet, directory=str(PUBLIC)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    written = []
    with sync_playwright() as p:
        browser = p.chromium.launch()
        ctx = browser.new_context(
            viewport={"width": 1440, "height": 1000},
            device_scale_factor=2,
            reduced_motion="reduce",
            color_scheme="light",
        )
        page = ctx.new_page()
        page.goto(f"http://127.0.0.1:{PORT}/", wait_until="networkidle")
        page.add_style_tag(content="html,body{background:transparent!important}.feed{height:auto!important;mask-image:none!important}.browser,.popup-mock,.term{box-shadow:none!important}")
        page.click("#demo-reveal")
        page.wait_for_timeout(300)
        for selector, name in [(".browser", "extension.png"), (".popup-mock", "popup.png"), (".term", "terminal.png")]:
            out = ASSETS / name
            page.locator(selector).screenshot(path=str(out), omit_background=True)
            written.append(out)
        browser.close()
    server.shutdown()
    if shutil.which("oxipng"):
        subprocess.run(["oxipng", "-q", "-o", "4", "--strip", "safe", *map(str, written)], check=False)
    for out in written:
        print(f"wrote {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
