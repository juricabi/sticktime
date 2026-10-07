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


def race_view(page, track, gate, back, side, up, roll, pitch, speed, mode=2, lap_secs=9.4):
    """Start a race, put the quad `back` m before `gate` heading through it, moving."""
    page.evaluate(f"sim.test('track', {track}); sim.test('start', {mode}); sim.step(110, 50)")
    gx, gy, gz, nx, ny, nz, k = page.evaluate(f"sim.test('gate', {gate})")
    yaw = math.degrees(math.atan2(nx, nz)) if k != 3 else 0
    # lateral axis of the gate (right = (nz, -nx))
    x, y, z = gx - nx * back + nz * side, gy + up, gz - nz * back - nx * side
    page.evaluate(f"sim.test('next', {gate}); sim.test('pose', {x}, {y}, {z}, {yaw}, {pitch}, {roll}); sim.test('vel', {nx * speed}, 0, {nz * speed})")
    page.evaluate(f"sim.test('state', 4); sim.sticks(0, 0, 0.05, 0); sim.test('lapclock', {int(lap_secs * 100)})")
    page.evaluate("sim.step(1, 50)")


with sync_playwright() as p:
    b = p.chromium.launch()
    page = b.new_page(viewport={"width": 1400, "height": 1000})
    page.goto((ROOT / "web" / "simulator.html").as_uri())
    page.wait_for_function("window.sim && window.sim.engine && window.sim.engine.frames > 2", timeout=20000)
    page.evaluate("sim.pause(true); sim.app.ghost = false")

    page.evaluate("sim.radio('tx16s'); sim.pause(true)")
    page.evaluate("sim.step(140, 50)")
    shot(page, "tx16s-menu")
    race_view(page, 1, 3, 16, -1.2, 0.8, -18, -6, 13, mode=2)
    shot(page, "tx16s-race")

    page.evaluate("sim.radio('nv14'); sim.pause(true)")
    race_view(page, 1, 2, 11, 1.0, 0.4, 14, -4, 12, mode=2)
    shot(page, "nv14-race")

    page.evaluate("sim.radio('mk3'); sim.pause(true)")
    gx, gy, gz, *_ = page.evaluate("sim.test('track', 3); sim.test('gate', 5)")
    page.evaluate("sim.test('start', 2); sim.step(110, 50)")
    page.evaluate(f"sim.test('next', 5); sim.test('pose', {gx + 9}, {gy + 6}, {gz}, -90, -45, 0); sim.test('state', 4); sim.step(1, 50)")
    shot(page, "mk3-dive")

    for rid, sc in (("tx12", 4), ("x9d", 3)):
        page.evaluate(f"sim.radio('{rid}'); sim.pause(true); sim.app.ghost = false")
        race_view(page, 1, 3, 14, -1.0, 0.6, -12, -5, 12, mode=2)
        shot(page, f"{rid}-race", sc)
    b.close()
print("saved", sorted(x.name for x in DOCS.glob("*.png")))
