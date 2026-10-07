#!/usr/bin/env python3
"""Curated screenshots for the README, taken from the real scripts in the web emulator."""
import base64
import math
import pathlib

from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
DOCS.mkdir(exist_ok=True)


def shot(page, name, scale=1):
    url = page.evaluate("sim.shot()")
    p = DOCS / f"{name}.png"
    p.write_bytes(base64.b64decode(url.split(",", 1)[1]))
    if scale > 1:
        im = Image.open(p)
        im.resize((im.width * scale, im.height * scale), Image.NEAREST).save(p)
    print("saved", p.name)


def radio(page, rid):
    page.evaluate(f"sim.radio('{rid}'); sim.pause(true); sim.app.ghost = false; sim.engine.displayDelay = false")


def race_view(page, track, gate, back, side, up, roll, pitch, speed, mode=2, lap_secs=9.4, ai=0):
    """Start a race, put the quad `back` m before `gate` heading through it, moving."""
    if ai is not None:
        page.evaluate(f"sim.test('set', 'ai', {ai})")
    page.evaluate(f"sim.test('track', {track}); sim.test('start', {mode}); sim.step(70, 50)")
    gx, gy, gz, nx, ny, nz, k, ax, ay, az = page.evaluate(f"sim.test('gate', {gate})")[:10]
    if k == 3:
        nx, nz = 0, 1
    yaw = math.degrees(math.atan2(nx, nz))
    x, y, z = ax - nx * back + nz * side, ay + up, az - nz * back - nx * side
    page.evaluate(f"sim.test('next', {gate}); sim.test('pose', {x}, {y}, {z}, {yaw}, {pitch}, {roll}); sim.test('vel', {nx * speed}, 0, {nz * speed})")
    page.evaluate(f"sim.test('state', 4); sim.sticks(0, 0, 0.05, 0); sim.test('lapclock', {int(lap_secs * 100)})")
    page.evaluate("sim.step(1, 50)")


with sync_playwright() as p:
    b = p.chromium.launch()
    page = b.new_page(viewport={"width": 1400, "height": 1000})
    page.goto((ROOT / "web" / "simulator.html").as_uri())
    page.wait_for_function("window.sim && window.sim.engine && window.sim.engine.frames > 2", timeout=20000)
    page.evaluate("sim.pause(true); sim.app.ghost = false; sim.app.delay = false")

    # TX16S: menu, a race against AI pilots, Bando, freestyle, flags, settings
    radio(page, "tx16s")
    page.evaluate("sim.test('track', 6); sim.step(140, 50)")
    shot(page, "tx16s-menu")
    page.evaluate("sim.test('set', 'ai', 3); sim.test('set', 'skill', 3); sim.test('track', 6); sim.test('start', 1); sim.sticks(0, 0, -1, 0)")
    page.evaluate("sim.step(60, 50); sim.step(52, 50)")
    ax, ay, az = page.evaluate("sim.test('ai', 2)")[:3]
    page.evaluate(f"sim.test('pose', {ax + 1.2}, {ay + 0.9}, {az - 6.5}, 0, -8, -12); sim.test('state', 4); sim.test('lapclock', 262); sim.step(1, 50)")
    shot(page, "tx16s-race")
    race_view(page, 7, 2, 18, -3, 1.2, 8, -4, 10)
    shot(page, "tx16s-bando")
    page.evaluate("sim.test('track', 7); sim.test('start', 3); sim.step(10, 50); sim.test('state', 4); sim.test('pose', 22, 16, 18, -40, 0, 0)")
    page.evaluate("sim.sticks(0, -1, 0.25, 0); sim.step(13, 50); sim.sticks(1, 0, 0.3, 0); sim.step(9, 50); sim.sticks(0, 0, 0.3, 0); sim.step(4, 50)")
    x, y, z = page.evaluate("sim.test('get')")[:3]
    page.evaluate(f"sim.test('pose', {x}, {y}, {z}, -30, -18, 8); sim.step(1, 50)")
    shot(page, "tx16s-freestyle")
    race_view(page, 4, 3, 13, 2.5, 0.5, -16, -5, 12, lap_secs=7.2)
    shot(page, "tx16s-slalom")
    page.evaluate("sim.test('state', 1); sim.step(2, 50)")
    for k in ("next", "next", "next", "next", "next", "enter", "next", "next", "next", "next", "next"):
        page.evaluate(f"sim.key('{k}'); sim.step(1, 50)")
    page.evaluate("sim.step(3, 50)")
    shot(page, "tx16s-settings")
    page.evaluate("sim.key('exit'); sim.step(2, 50)")

    # NV14 portrait: hoop forest
    radio(page, "nv14")
    race_view(page, 5, 4, 7, 0.6, 0.2, 10, -4, 11, mode=1, ai=0)
    shot(page, "nv14-race")

    # MK3: the tower and the dive gate at the Bando
    radio(page, "mk3")
    race_view(page, 7, 6, 30, 4, 2.5, -6, -6, 12)
    shot(page, "mk3-bando")

    # B&W
    for rid, sc, args in (("tx12", 4, (5, 3, 11, 0.3, 0.3, -10, -4, 10)), ("x9d", 3, (7, 2, 15, -1.5, 0.6, 6, -4, 10))):
        radio(page, rid)
        race_view(page, *args)
        shot(page, f"{rid}-race", sc)

    # FPV Sim Lite: X7 / TX12 MkI class (128x64) and X9D+ (212x64 grey)
    page.evaluate("sim.script('lite')")
    radio(page, "tx12")
    page.evaluate("sim.step(10, 50)")
    shot(page, "lite-menu", 4)
    race_view(page, 5, 2, 9, 0.3, 0.4, -8, -8, 10, mode=1, ai=None)          # Hoop Forest
    shot(page, "lite-tx12", 4)
    radio(page, "x9d")
    race_view(page, 7, 2, 15, -1.5, 0.6, 6, -20, 10, mode=1, ai=None)        # the Bando
    shot(page, "lite-x9d", 3)
    page.evaluate("sim.script('auto')")
    b.close()
print("saved", sorted(x.name for x in DOCS.glob("*.png")))
