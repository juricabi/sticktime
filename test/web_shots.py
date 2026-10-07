#!/usr/bin/env python3
"""Drive the web emulator in headless Chromium: boot every radio, step the real
scripts deterministically, save LCD screenshots and report errors + load stats."""
import base64
import json
import math
import pathlib
import sys

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "test" / "shots"
OUT.mkdir(parents=True, exist_ok=True)
PAGE = (ROOT / "web" / "simulator.html").as_uri()

RADIOS = sys.argv[1].split(",") if len(sys.argv) > 1 else ["tx16s", "tx15", "nv14", "pa01", "mk3", "x9d", "tx12"]
worst = {}


def save(page, name):
    url = page.evaluate("sim.shot()")
    (OUT / f"{name}.png").write_bytes(base64.b64decode(url.split(",", 1)[1]))


def stats(page, rid, what):
    s = page.evaluate("""() => { const e = sim.engine; const s = e.last; const est = e.estimate();
        return {err: e.error, ms: +est.ms.toFixed(1), instr: s.instr, calls: s.calls, lines: s.lines, linePx: s.linePx,
                tris: s.tris, scan: Math.round(s.scan), rects: s.rects, texts: s.texts, rejected: s.rejected || 0}; }""")
    print(f"{rid:6s} {what:10s} {s}")
    if s["ms"] > worst.get(rid, (0, ""))[0]:
        worst[rid] = (s["ms"], what)
    if s["rejected"]:
        print("   !! lines rejected by the firmware rule")
    return s


def view(page, track, gate, back, side, up, pitch, roll, mode=1, speed=0):
    """put the quad `back` m before `gate`, looking through it"""
    page.evaluate(f"sim.test('track', {track}); sim.test('start', {mode}); sim.step(70, 50)")
    g = page.evaluate(f"sim.test('gate', {gate})")
    gx, gy, gz, nx, ny, nz, k, ax, ay, az = g[:10]
    if k == 3:
        nx, nz = 0, 1
    yaw = math.degrees(math.atan2(nx, nz))
    x, y, z = ax - nx * back + nz * side, ay + up, az - nz * back - nx * side
    page.evaluate(f"sim.test('next', {gate}); sim.test('pose', {x}, {y}, {z}, {yaw}, {pitch}, {roll}); sim.test('vel', {nx * speed}, 0, {nz * speed})")
    page.evaluate("sim.test('state', 4); sim.sticks(0, 0, 0.05, 0)")
    return page.evaluate("sim.step(1, 50)")


def main():
    with sync_playwright() as p:
        b = p.chromium.launch()
        page = b.new_page(viewport={"width": 1400, "height": 1000})
        logs = []
        page.on("console", lambda m: logs.append(f"{m.type}: {m.text}"))
        page.on("pageerror", lambda e: logs.append(f"pageerror: {e}"))
        page.goto(PAGE)
        page.wait_for_function("window.sim && window.sim.engine && window.sim.engine.frames > 2", timeout=20000)
        page.evaluate("sim.pause(true); sim.app.ghost = false; sim.app.delay = false")
        for rid in RADIOS:
            page.evaluate(f"sim.radio('{rid}')")
            page.evaluate("sim.pause(true); sim.engine.displayDelay = false")
            err = page.evaluate("sim.step(30, 50)")
            if err:
                print(rid, "ERROR", json.dumps(err)[:2000]); continue
            save(page, f"{rid}_01menu")
            stats(page, rid, "menu")
            # race with AI pilots: countdown, then the start
            page.evaluate("sim.test('set', 'ai', 3); sim.test('track', 1); sim.test('start', 1); sim.sticks(0, 0, -1, 0)")
            page.evaluate("sim.step(40, 50)")
            save(page, f"{rid}_02count")
            page.evaluate("sim.step(25, 50); sim.sticks(0, 0.25, 0.1, 0)")
            err = page.evaluate("sim.step(30, 50)")
            if err: print(rid, "ERROR", err); continue
            save(page, f"{rid}_03race")
            stats(page, rid, "race")
            for name, args in (("04gate", (1, 3, 14, -1.0, 0.6, -6, -14)), ("05hoops", (5, 3, 12, 0.5, 0.2, -4, 8)),
                               ("06flags", (4, 2, 10, 1.5, 0.2, -6, 0)), ("07grandprix", (6, 4, 16, 0, 0.5, -5, -10)),
                               ("08bando", (7, 2, 14, 0, 0.5, -4, 0)), ("09ruin", (7, 3, 3, 0, 0.2, -2, 0)),
                               ("10tower", (7, 6, 26, -6, 4, -10, 20)), ("11dive", (3, 5, 0, 0, 6, -60, 0))):
                err = view(page, *args)
                if err: print(rid, name, "ERROR", err); break
                save(page, f"{rid}_{name}")
                stats(page, rid, name)
            # freestyle combo and gate rush HUDs
            page.evaluate("sim.test('track', 7); sim.test('start', 3); sim.step(10, 50); sim.test('state', 4); sim.test('pose', -20, 20, -20, 45, 0, 0)")
            page.evaluate("sim.sticks(0, 1, 0.2, 0); sim.step(12, 50); sim.sticks(1, 0, 0.2, 0); sim.step(10, 50); sim.sticks(0, 0, 0.3, 0); sim.step(3, 50)")
            save(page, f"{rid}_12freestyle")
            stats(page, rid, "freestyle")
            page.evaluate("sim.test('track', 1); sim.test('start', 4); sim.step(70, 50); sim.sticks(0, 0.2, 0.3, 0); sim.step(20, 50)")
            save(page, f"{rid}_13rush")
            stats(page, rid, "rush")
            page.evaluate("sim.key('exit'); sim.step(2, 50)")
            save(page, f"{rid}_14pause")
            # settings list (rates rows)
            for k in ("next", "next", "enter", "next", "next", "next", "next"):
                page.evaluate(f"sim.key('{k}'); sim.step(1, 50)")
            save(page, f"{rid}_15settings")
            page.evaluate("sim.test('set', 'ai', 0)")
        # FPV Sim Lite (reads its tracks from the SD card): every track, freestyle and gate rush
        if "tx12" in RADIOS or "x9d" in RADIOS:
            page.evaluate("sim.script('lite')")
            for rid in [r for r in ("tx12", "x9d") if r in RADIOS]:
                page.evaluate(f"sim.radio('{rid}')")
                page.evaluate("sim.pause(true); sim.engine.displayDelay = false")
                err = page.evaluate("sim.step(10, 50)")
                if err:
                    print(rid, "lite ERROR", json.dumps(err)[:2000]); continue
                save(page, f"lite_{rid}_01menu")
                stats(page, rid, "lite menu")
                for t, gate, back in ((1, 1, 14), (2, 3, 12), (3, 4, 12), (4, 2, 10), (5, 3, 10), (6, 4, 14), (7, 2, 14)):
                    err = view(page, t, gate, back, 0, 0.5, -6, 0)
                    if err: print(rid, "lite track", t, "ERROR", err); break
                    info = page.evaluate("sim.test('info')")
                    save(page, f"lite_{rid}_t{t}")
                    stats(page, rid, f"lite t{t}")
                    print(f"   track {t} {info[7]}: pillars {info[8]}, boxes {info[11]}")
                page.evaluate("sim.test('track', 7); sim.test('start', 3); sim.step(10, 50); sim.test('state', 4); sim.test('pose', -20, 20, -20, 45, 0, 0)")
                page.evaluate("sim.sticks(0, 1, 0.2, 0); sim.step(12, 50); sim.sticks(1, 0, 0.2, 0); sim.step(10, 50); sim.sticks(0, 0, 0.3, 0); sim.step(3, 50)")
                save(page, f"lite_{rid}_freestyle")
                stats(page, rid, "lite free")
                page.evaluate("sim.test('track', 5); sim.test('start', 4); sim.step(70, 50); sim.sticks(0, 0.2, 0.3, 0); sim.step(20, 50)")
                save(page, f"lite_{rid}_rush")
                err = stats(page, rid, "lite rush")["err"]
                if err: print(rid, "lite ERROR", err)
            page.evaluate("sim.script('auto')")
        page.screenshot(path=str(OUT / "page.png"))
        b.close()
        print("worst frame estimate per radio (ms):", {k: v for k, v in worst.items()})
        for l in logs:
            print(l)


if __name__ == "__main__":
    main()
