#!/usr/bin/env python3
"""Render site/og/template.html to site/public/og.png at 1200x630."""
import pathlib
import sys
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent
TEMPLATE = ROOT / "template.html"
OUT = ROOT.parent / "public" / "og.png"

def main() -> int:
    if not TEMPLATE.exists():
        print(f"missing template: {TEMPLATE}", file=sys.stderr)
        return 1
    with sync_playwright() as p:
        browser = p.chromium.launch()
        ctx = browser.new_context(viewport={"width": 1200, "height": 630},
                                  device_scale_factor=2)
        page = ctx.new_page()
        page.goto(TEMPLATE.as_uri(), wait_until="networkidle")
        OUT.parent.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(OUT), clip={"x": 0, "y": 0, "width": 1200, "height": 630})
        browser.close()
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
