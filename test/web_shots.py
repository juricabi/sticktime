#!/usr/bin/env python3
"""Drive the web emulator in headless Chromium: boot every radio, step the real
scripts deterministically, save LCD screenshots and report errors + load stats."""
import base64
import json
import pathlib
import sys

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "test" / "shots"
OUT.mkdir(parents=True, exist_ok=True)
PAGE = (ROOT / "web" / "simulator.html").as_uri()

RADIOS = sys.argv[1].split(",") if len(sys.argv) > 1 else ["tx16s", "tx15", "nv14", "pa01", "mk3", "x9d", "tx12"]


def save(page, name):
    url = page.evaluate("sim.shot()")
    (OUT / f"{name}.png").write_bytes(base64.b64decode(url.split(",", 1)[1]))


def stats(page):
    return page.evaluate("""() => { const e = sim.engine; const s = e.last; const est = e.estimate();
        return {err: e.error, ms: +est.ms.toFixed(1), instr: s.instr, calls: s.calls, lines: s.lines, linePx: s.linePx,
                tris: s.tris, scan: Math.round(s.scan), rects: s.rects, texts: s.texts, rejected: s.rejected || 0}; }""")


def main():
    with sync_playwright() as p:
        b = p.chromium.launch()
        page = b.new_page(viewport={"width": 1400, "height": 1000})
        logs = []
        page.on("console", lambda m: logs.append(f"{m.type}: {m.text}"))
        page.on("pageerror", lambda e: logs.append(f"pageerror: {e}"))
        page.goto(PAGE)
        page.wait_for_function("window.sim && window.sim.engine && window.sim.engine.frames > 2", timeout=20000)
        page.evaluate("sim.pause(true); sim.app.ghost = false")
        for rid in RADIOS:
            page.evaluate(f"sim.radio('{rid}')")
            page.evaluate("sim.pause(true)")
            err = page.evaluate("sim.step(30, 50)")
            if err:
                print(rid, "ERROR", json.dumps(err)[:2000]); continue
            save(page, f"{rid}_1menu")
            print(rid, "menu", stats(page))
            # race: countdown then fly a bit
            page.evaluate("sim.test('start', 1)")
            page.evaluate("sim.sticks(0, 0, -1, 0)")
            page.evaluate("sim.step(40, 50)")
            save(page, f"{rid}_2count")
            page.evaluate("sim.step(25, 50)")
            page.evaluate("sim.sticks(0, 0.25, 0.1, 0)")
            err = page.evaluate("sim.step(30, 50)")
            if err: print(rid, "ERROR", err); continue
            save(page, f"{rid}_3fly")
            print(rid, "fly ", stats(page), page.evaluate("sim.test('get')")[:3])
            # poses: approach gate 2 slightly from the side, then banked + pitched view
            g = page.evaluate("sim.test('gate', 2)")
            gx, gy, gz, nx, ny, nz = g[:6]
            page.evaluate(f"sim.test('pose', {gx - nx * 12 + 3}, {gy + 0.6}, {gz - nz * 12}, {__import__('math').degrees(__import__('math').atan2(nx, nz))}, -8, 25)")
            page.evaluate("sim.test('state', 4)")
            page.evaluate("sim.sticks(0, 0, 0.0, 0)")
            page.evaluate("sim.step(1, 50)")
            save(page, f"{rid}_4gate")
            print(rid, "gate", stats(page))
            page.evaluate(f"sim.test('pose', {gx - nx * 2.5}, {gy + 0.2}, {gz - nz * 2.5}, {__import__('math').degrees(__import__('math').atan2(nx, nz))}, 0, -50)")
            page.evaluate("sim.step(1, 50)")
            save(page, f"{rid}_5close")
            print(rid, "close", stats(page))
            page.evaluate("sim.test('pose', 20, 25, -40, 30, -35, 120)")
            page.evaluate("sim.step(1, 50)")
            save(page, f"{rid}_6inverted")
            print(rid, "inv ", stats(page))
            page.evaluate("sim.key('exit')")
            page.evaluate("sim.step(2, 50)")
            save(page, f"{rid}_7pause")
        page.screenshot(path=str(OUT / "page.png"))
        b.close()
        for l in logs:
            print(l)


if __name__ == "__main__":
    main()
