import pathlib
from playwright.sync_api import sync_playwright
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "test" / "shots"
with sync_playwright() as p:
    b = p.chromium.launch()
    for name, vp, scheme in [("desk", {"width": 1440, "height": 900}, "light"), ("desk_dark", {"width": 1440, "height": 900}, "dark"), ("phone", {"width": 390, "height": 844}, "light")]:
        page = b.new_page(viewport=vp, color_scheme=scheme)
        page.goto((ROOT / "web" / "simulator.html").as_uri())
        page.wait_for_function("window.sim && window.sim.engine && window.sim.engine.frames > 20", timeout=20000)
        page.wait_for_timeout(800)
        page.screenshot(path=str(OUT / f"page_{name}.png"), full_page=(name == "phone"))
        w = page.evaluate("document.documentElement.scrollWidth")
        print(name, "scrollWidth", w, "viewport", vp["width"])
        page.close()
    b.close()
