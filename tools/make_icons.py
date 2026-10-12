#!/usr/bin/env python3
"""The icon's PNGs from docs/icon.svg (run after changing it, then tools/bundle_web.py).

docs/icon-32.png   - browser tab icon for browsers without SVG icons (rounded, transparent corners)
docs/icon-180.png  - phone home screen icon (square: the phone rounds it itself)
"""
import base64
import pathlib

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"


def main():
    svg = (DOCS / "icon.svg").read_text(encoding="utf-8")
    square = svg.replace('<rect width="64" height="64" rx="14"/>', '<rect width="64" height="64"/>')
    assert square != svg
    with sync_playwright() as p:
        b = p.chromium.launch()
        for name, size, s in (("icon-32.png", 32, svg), ("icon-180.png", 180, square)):
            page = b.new_page(viewport={"width": size, "height": size})
            url = "data:image/svg+xml;base64," + base64.b64encode(s.encode()).decode()
            page.set_content(f'<body style="margin:0"><img src="{url}" width="{size}" height="{size}" '
                             'style="display:block">')
            page.screenshot(path=str(DOCS / name), omit_background=True)
            print("saved", name)
        b.close()


if __name__ == "__main__":
    main()
