#!/usr/bin/env python3
"""The track editor of the web emulator, in headless Chromium and offline: start from the Grand
Prix, fly it from slot 1 (the game must list it as track 9 and build it), the file it saves (the
format src/sticktime.lua reads, plain decimals, at most 999 bytes, the id from its numbers), that
file read back (CR LF too) and a broken one refused, the checks that stop a track the game can't
take, keys typed in the editor that must never reach the game (and keys outside it that must),
StickTime Lite, a wall with a gap, artifact.html (fengari from its CDN address, served here from
web/vendor), and screenshots at desktop and phone width: test/shots/editor_*.png."""
import pathlib
import re
import sys
import tempfile

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "test" / "shots"
OUT.mkdir(parents=True, exist_ok=True)
SIM = (ROOT / "web" / "simulator.html").as_uri()
ART = (ROOT / "web" / "artifact.html").as_uri()
FENGARI = (ROOT / "web" / "vendor" / "fengari-web.js").read_text(encoding="utf-8")
SLOT = "/SCRIPTS/TOOLS/StickTimeTracks/c"
fails = []


def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        fails.append(what)


def fnv1a(s):
    h = 0x811C9DC5
    for c in s.encode():
        h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF
    return h


# a plain decimal: no exponent, at most 2 places, no trailing zeros
NUM = re.compile(r"^-?(0|[1-9]\d*)(\.\d?[1-9])?$")


def check_file(text, gates, boxes, what):
    """the format the game reads: the name, then 1 <id> <seed> <trees> <gates...> [/ <boxes...>]"""
    check(len(text.encode()) <= 999, f"{what}: {len(text.encode())} bytes (999 at most)")
    check(text.endswith("\n") and text.count("\n") == 2 and "\r" not in text, f"{what}: a name line and a numbers line, LF")
    name, line = text.split("\n")[:2]
    check(1 <= len(name) <= 16 and name == name.strip() and "/" not in name and all(32 <= ord(c) < 127 for c in name),
          f"{what}: name {name!r}")
    tok = line.split(" ")
    check(tok[0] == "1", f"{what}: format 1")
    nums = line[len("1 " + tok[1] + " "):]
    check(tok[1].isdigit() and 1 <= int(tok[1]) <= 999999 and int(tok[1]) == fnv1a(nums) % 999999 + 1,
          f"{what}: id {tok[1]} = FNV-1a of the numbers part mod 999999 + 1")
    check("e" not in nums.lower(), f"{what}: no 'e' in the numbers")
    g, _, b = nums.partition(" / ")
    gt, bt = g.split(" "), (b.split(" ") if b else [])
    check(all(NUM.match(t) for t in gt + bt), f"{what}: plain decimals, 0.01 m at most")
    check(1 <= int(gt[0]) <= 99 and 0 <= int(gt[1]) <= 30, f"{what}: seed {gt[0]}, trees {gt[1]}")
    check(len(gt) - 2 == gates * 5 and len(bt) == boxes * 7, f"{what}: {gates} gates, {boxes} structures")
    return name, nums


def wait_sim(page):
    page.wait_for_function("window.sim && window.sim.engine && window.sim.engine.frames > 2 && window.sim.editor", timeout=30000)


def click_map(page, x, z, **kw):
    """click a point of the track (positions read just before: the page may have scrolled)"""
    page.locator("#edMap").scroll_into_view_if_needed()
    px, py = page.evaluate(f"sim.editor.at({x}, {z})")
    page.mouse.click(px, py, **kw)


def shot_clip(page, path):
    """the editor card, from a full-page screenshot taken at the top of the page (where the sticky
    header sits above the card, not over it)"""
    r = page.evaluate("(() => { const b = document.getElementById('editor').getBoundingClientRect();"
                      " return { x: b.left + scrollX, y: b.top + scrollY, width: b.width, height: b.height }; })()")
    page.evaluate("scrollTo(0, 0)")
    page.wait_for_timeout(100)
    page.screenshot(path=str(path), full_page=True, clip=r)


def open_file(page, path):
    """Open file, and wait for the editor to say what it made of it (FileReader is asynchronous)"""
    page.evaluate("document.getElementById('edStatus').textContent = ''")
    page.set_input_files("#edOpen", str(path))
    page.wait_for_function(f"document.getElementById('edStatus').textContent.includes({path.name!r})", timeout=5000)
    return page.inner_text("#edStatus")


def offline(ctx, cdn=False):
    """no network: only fengari's CDN address answers (artifact.html), from web/vendor"""
    def route(r):
        if cdn and "fengari-web" in r.request.url:
            r.fulfill(body=FENGARI, content_type="application/javascript")
        else:
            r.abort()
    ctx.route("http*://**", route)


def main():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="sticktime-editor-"))
    errors = []
    with sync_playwright() as p:
        br = p.chromium.launch()
        ctx = br.new_context(viewport={"width": 1400, "height": 1000}, accept_downloads=True)
        offline(ctx)
        page = ctx.new_page()
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(SIM)
        wait_sim(page)

        # ---- the Grand Prix as a custom track
        page.click("#tracksBtn")
        check(page.is_visible("#editor") and page.get_attribute("#tracksBtn", "aria-expanded") == "true", "Tracks opens the editor")
        page.select_option("#edTemplate", label="Grand Prix")
        gp = page.evaluate("sim.editor.track()")
        check(page.input_value("#edName") == "My Grand Prix" and len(gp["gates"]) == 12, "the Grand Prix template: 12 gates")
        check(page.evaluate("sim.editor.problems()") == [] and page.is_enabled("#edFly") and page.is_enabled("#edSave"),
              "nothing in the way: Fly it and Save file on")
        page.select_option("#edSlot", "1")
        with page.expect_download() as d:
            page.click("#edSave")
        check(d.value.suggested_filename == "c1.txt", "Save file downloads c1.txt")
        text = pathlib.Path(d.value.path()).read_bytes().decode("ascii")
        name, nums = check_file(text, 12, 0, "the Grand Prix's c1.txt")
        check(name == "My Grand Prix" and nums.startswith("71 9 0 0 5 0 0 0 40 1 0 0 10 80 2 20 6 "),
              "its numbers are the Grand Prix's (seed 71, arch, gate, high gate...)")
        check(page.evaluate("sim.editor.file()") == text, "the download is the editor's file")

        # ---- Fly it: slot 1 is track 9, in Practice
        page.click("#edFly")
        check(page.is_hidden("#editor"), "Fly it closes the editor")
        info = page.evaluate("sim.test('info')")
        check(info[0] == 9 and info[10] == "My Grand Prix", f"the game lists track 9 as {info[10]!r}")
        get = page.evaluate("sim.test('get')")
        check(info[2] == 2 and get[18] == 12 and get[15] in (3, 4), "Practice on track 9 with its 12 gates")
        g3, e3 = page.evaluate("sim.test('gate', 3)"), gp["gates"][2]
        check(abs(g3[0] - e3["x"]) < 1e-9 and abs(g3[2] - e3["z"]) < 1e-9 and g3[6] == e3["t"], "gate 3 stands where the editor put it")
        check(page.evaluate(f"sim.app.sd.get('{SLOT}1.txt')") == text, "the emulator's SD card holds the file")
        check(SLOT + "1.txt" in (page.evaluate("localStorage.getItem('fpvsim.sd')") or ""), "kept with the SD card in localStorage")
        page.wait_for_timeout(1500)
        check(not page.evaluate("sim.engine.error") and page.evaluate("sim.test('get')")[15] in (3, 4, 5), "the game flies it")

        # ---- after a reload: the slot and the work in progress
        page.reload()
        wait_sim(page)
        check(page.evaluate("sim.test('info')")[0] == 9, "after a reload the game still lists track 9")
        page.click("#tracksBtn")
        check(page.input_value("#edName") == "My Grand Prix", "the work in progress is remembered (fpvsim.editor)")
        check("My Grand Prix" in page.inner_text("#edSlot"), "the slot list shows the track in c1")

        # ---- Open file: CR LF, and a broken file
        crlf = tmp / "c3.txt"
        crlf.write_bytes(text.replace("\n", "\r\n").encode())
        page.select_option("#edTemplate", label="Meadow")
        status = open_file(page, crlf)
        t = page.evaluate("sim.editor.track()")
        check(t["name"] == "My Grand Prix" and len(t["gates"]) == 12, f"a CR LF file opens: {status!r}")
        check(page.evaluate("sim.editor.file()") == text, "opened and saved again: the same file, the same id")
        check(page.input_value("#edSlot") == "3", "c3.txt goes to slot 3")
        bad = tmp / "bad.txt"
        bad.write_text("Broken\n1 5 7 9 0 0 1 0\n", encoding="ascii")
        status = open_file(page, bad)
        check("open bad.txt" in status and "5 numbers each" in status, f"a broken file is refused: {status!r}")
        check(page.evaluate("sim.editor.track()")["name"] == "My Grand Prix", "and the track stays as it was")

        # ---- the checks
        page.select_option("#edTemplate", label="Bando")
        check(page.evaluate("sim.editor.problems()") == [], "the Bando passes the checks (16 structures, walls touching)")
        check(page.is_disabled("#edAddBox") and page.is_disabled("#edAddWall"), "no more structures than 16")
        click_map(page, -36, 50)                                 # structure 16, onto the blue container
        page.fill('#edSel [data-f="x"]', "-30")
        page.press('#edSel [data-f="x"]', "Tab")
        page.fill('#edSel [data-f="z"]', "20")
        page.press('#edSel [data-f="z"]', "Tab")
        probs = page.evaluate("sim.editor.problems()")
        check("Structures 15 and 16 overlap." in probs, f"an overlap is found: {probs}")
        check(page.is_disabled("#edFly") and page.is_disabled("#edSave"), "Fly it and Save file off while it is wrong")
        page.click("#edUndo")
        page.click("#edUndo")
        check(page.evaluate("sim.editor.problems()") == [] and page.is_enabled("#edFly"), "Undo puts it right")
        click_map(page, 0, 0)                                    # gate 1
        page.select_option('#edSel [data-f="t"]', "3")
        check(any("dive gate" in m for m in page.evaluate("sim.editor.problems()")), "gate 1 can't be a dive gate")
        page.keyboard.press("Control+z")
        page.fill("#edName", "")
        check("Give the track a name." in page.evaluate("sim.editor.problems()"), "a track needs a name")
        page.fill("#edName", "Bad/Name")
        check(any('"/"' in m for m in page.evaluate("sim.editor.problems()")), "no '/' in the name")
        page.fill("#edName", "My Bando")
        page.press("#edName", "Tab")
        check(page.evaluate("sim.editor.problems()") == [], "fixed again")

        # ---- keys: in the editor they edit and never reach the game; outside it they do again
        page.evaluate("sim.engine.__mark = 1")
        click_map(page, 0, 0)                                    # gate 1, the map has the keyboard
        yaw = page.evaluate("sim.editor.track().gates[0].yaw")
        page.keyboard.press("r")
        check(page.evaluate("sim.engine.__mark") == 1, "R in the editor doesn't restart the game")
        check(page.evaluate("sim.editor.track().gates[0].yaw") == (yaw + 15) % 360, "R in the editor turns the gate")
        thr = page.evaluate("sim.engine.sticks.thr")
        page.keyboard.down("w")
        page.wait_for_timeout(400)
        page.keyboard.up("w")
        check(page.evaluate("sim.engine.sticks.thr") == thr, "W in the editor leaves the throttle alone")
        page.keyboard.press("Escape")
        page.keyboard.press("Backspace")
        page.wait_for_timeout(200)
        check(not page.evaluate("sim.engine.exited") and page.evaluate("sim.engine.__mark") == 1,
              "Escape and Backspace in the editor don't reach the game")
        page.click("#edName")
        page.keyboard.type("rw")
        check(page.evaluate("sim.engine.__mark") == 1, "typing a name doesn't reach the game")
        page.keyboard.press("Control+z")
        page.click("#edClose")
        page.keyboard.press("r")
        check(page.evaluate("sim.engine.__mark") is None, "R outside the editor restarts the game, as before")

        # ---- a wall with a gap, flown from slot 3
        page.click("#tracksBtn")
        page.select_option("#edTemplate", label="Meadow")
        page.click("#edAddWall")
        sel = page.evaluate("sim.editor.selected()")
        t = page.evaluate("sim.editor.track()")
        check(len(sel) == 4 and len(t["boxes"]) == 3 and sum(g["t"] == 8 for g in t["gates"]) == 1, "Wall with gap: a gap gate and 3 structures, selected")
        check(page.evaluate("sim.editor.problems()") == [], "the gap sits in its opening: no problem")
        page.click("#edRotR")
        t2 = page.evaluate("sim.editor.track()")
        check([(b["hx"], b["hz"]) for b in t2["boxes"]] == [(b["hz"], b["hx"]) for b in t["boxes"]] and page.evaluate("sim.editor.problems()") == [],
              "it turns 90° as a whole")
        page.select_option("#edSlot", "3")
        page.click("#edFly")
        info = page.evaluate("sim.test('info')")
        check(info[10] == "My Meadow" and info[9] == 3 and page.evaluate("sim.test('get')")[18] == 8, "track 11: Meadow, its wall and its gap")

        # ---- StickTime Lite reads no custom tracks: the editor says so, Fly it goes back to Auto
        page.evaluate("sim.script('lite')")
        page.click("#tracksBtn")
        check(page.is_visible("#edLite") and "Lite" in page.inner_text("#edLite"), "the editor says the Lite doesn't read them")
        page.select_option("#edTemplate", label="Bando")
        page.select_option("#edSlot", "2")
        page.click("#edFly")
        info = page.evaluate("sim.test('info')")
        check(page.evaluate("sim.app.script") == "auto" and info[10] == "My Bando" and info[9] == 16,
              "Fly it switches the Lite to Auto: track 10, the Bando's 16 structures")

        # ---- StickTime BW (a B&W radio): the same files
        page.evaluate("sim.radio('tx12')")
        page.click("#tracksBtn")
        page.select_option("#edTemplate", label="Hoop Forest")
        page.select_option("#edSlot", "4")
        page.click("#edFly")
        info = page.evaluate("sim.test('info')")
        check(page.evaluate("sim.app.radio.color") is False and info[0] == 12 and info[10] == "My Hoop Forest"
              and page.evaluate("sim.test('get')")[18] == 9, "StickTime BW on a TX12: Hoop Forest flown as track 12")
        page.evaluate("sim.radio('tx16s')")

        # ---- screenshots: desktop (light and dark), phone width
        page.click("#tracksBtn")
        page.select_option("#edTemplate", label="Bando")
        click_map(page, 0, 34)                                   # a wall of the Bando: its group
        check(len(page.evaluate("sim.editor.selected()")) == 4, "a click on a gap in a wall selects the wall (4 items)")
        page.mouse.move(0, 0)
        shot_clip(page, OUT / "editor_desktop.png")
        print("wrote test/shots/editor_desktop.png")
        page.emulate_media(color_scheme="dark")
        page.check("#edTrees")
        shot_clip(page, OUT / "editor_desktop_dark.png")
        print("wrote test/shots/editor_desktop_dark.png")
        page.uncheck("#edTrees")
        ctx.close()

        ctx = br.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2, is_mobile=True, has_touch=True)
        offline(ctx)
        page = ctx.new_page()
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(SIM)
        wait_sim(page)
        page.tap("#tracksBtn")
        page.select_option("#edTemplate", label="Grand Prix")
        check(page.evaluate("document.documentElement.scrollWidth <= innerWidth"), "phone width: nothing sticks out sideways")
        px, py = page.evaluate("sim.editor.at(10, 80)")
        page.touchscreen.tap(px, py)
        check(len(page.evaluate("sim.editor.selected()")) == 1, "a tap selects a gate")
        shot_clip(page, OUT / "editor_phone.png")
        print("wrote test/shots/editor_phone.png")
        ctx.close()

        # ---- artifact.html (fengari from the CDN address)
        ctx = br.new_context(viewport={"width": 1280, "height": 900})
        offline(ctx, cdn=True)
        page = ctx.new_page()
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(ART)
        wait_sim(page)
        page.click("#tracksBtn")
        page.select_option("#edTemplate", label="Pro Track")
        page.select_option("#edSlot", "8")
        page.click("#edFly")
        info = page.evaluate("sim.test('info')")
        check(info[0] == 16 and info[10] == "My Pro Track", "artifact.html: Pro Track flown as track 16")
        ctx.close()
        br.close()
    for e in errors:
        print("page error:", e)
    check(not errors, "no script errors on the page")
    print("ALL OK" if not fails else f"{len(fails)} FAILED")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
