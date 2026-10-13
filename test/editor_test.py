#!/usr/bin/env python3
"""The track editor of the web emulator, in headless Chromium and offline: start from the Grand
Prix, fly it from slot 1 (the game must list it as track 9 and build it), the file it saves (the
format src/sticktime.lua reads, plain decimals, at most 999 bytes, the id from its numbers), that
file read back (CR LF too) and a broken one refused, the checks that stop a track the game can't
take, keys typed in the editor that must never reach the game (and keys outside it that must),
StickTime Lite, a wall with a gap, artifact.html (fengari from its CDN address, served here from
web/vendor), and screenshots at desktop and phone width: test/shots/editor_*.png.

The radio's SD card (File System Access): the page is served at https://sticktime.test/ (a
file:// page has no private file system), a folder there stands for the card and replaces the
folder picker, so the editor's own reads and writes run: Send to radio, the overwrite question,
From radio (list, open, copy both ways), the card remembered across a reload, a picked SCRIPTS/
TOOLS or StickTimeTracks folder, a folder that isn't a card, and the line shown where the browser
can't do it (no picker, a SecurityError, the page in another site's frame)."""
import hashlib
import json
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


def shot_clip(page, path, card="editor"):
    """a panel (Tracks: the editor, Install: radioPanel), with the sticky header let go of for the
    shot (so that it doesn't cover the panel's top)"""
    page.evaluate("document.querySelector('header.top').style.position = 'static'")
    page.locator("#" + card).screenshot(path=str(path))
    page.evaluate("document.querySelector('header.top').style.position = ''")
    print("wrote test/shots/" + path.name)


def radio_panel(page):
    """the Install panel open (the Tracks one closes)"""
    if page.is_hidden("#radioPanel"):
        page.click("#radioBtn")
    radio_done(page)


def editor(page):
    """the Tracks panel open (the Install one closes)"""
    if page.is_hidden("#editor"):
        page.click("#tracksBtn")


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


SITE = "https://sticktime.test/"
PARENT = "https://another.test/"
NO_RADIO = ("This browser can't write to the radio's SD card: use Save file and copy it to "
            "/SCRIPTS/TOOLS/StickTimeTracks/ on the radio.")
NOT_CARD = "This doesn't look like the radio's SD card: no SCRIPTS folder. Pick the drive the radio shows up as."
# the card: RADIO-SD/SCRIPTS/TOOLS with StickTime.lua in it, a Documents folder beside it, and
# the folder picker answering with window.__pick
CARD = """async () => {
  const root = await navigator.storage.getDirectory();
  for (const n of ['RADIO-SD', 'Documents']) { try { await root.removeEntry(n, { recursive: true }); } catch (e) { } }
  const card = await root.getDirectoryHandle('RADIO-SD', { create: true });
  const tools = await (await card.getDirectoryHandle('SCRIPTS', { create: true })).getDirectoryHandle('TOOLS', { create: true });
  const w = await (await tools.getFileHandle('StickTime.lua', { create: true })).createWritable();
  await w.write('-- the game\\n'); await w.close();
  await root.getDirectoryHandle('Documents', { create: true });
  window.__pick = card;
  window.showDirectoryPicker = async (opts) => { window.__opts = opts; return window.__pick; };
}"""
PICK = """async (path) => { let d = await navigator.storage.getDirectory();
  for (const p of path.split('/')) d = await d.getDirectoryHandle(p); window.__pick = d; }"""
# a file on the card, or null
CARD_FILE = """async (path) => { try { let d = await navigator.storage.getDirectory(); const p = path.split('/');
  for (const s of p.slice(0, -1)) d = await d.getDirectoryHandle(s);
  return await (await (await d.getFileHandle(p[p.length - 1])).getFile()).text(); } catch (e) { return null; } }"""
CARD_WRITE = """async ([path, text]) => { let d = await navigator.storage.getDirectory(); const p = path.split('/');
  for (const s of p.slice(0, -1)) d = await d.getDirectoryHandle(s, { create: true });
  const w = await (await d.getFileHandle(p[p.length - 1], { create: true })).createWritable(); await w.write(text); await w.close(); }"""
TRACKS = "RADIO-SD/SCRIPTS/TOOLS/StickTimeTracks/c"


sys.path.insert(0, str(ROOT / "tools"))
import sd_manifest  # noqa: E402  (the site's sdcard/: the game's files and manifest.json)

GAME_FILES = sd_manifest.files()
MANIFEST = sd_manifest.manifest(GAME_FILES)
import bundle_web  # noqa: E402  (the built-in tracks, as the editor's templates have them)

TEMPLATES = {t["name"]: t for t in json.loads(bundle_web.track_data())["tracks"]}
GP = TEMPLATES["Grand Prix"]
NGP = len(GP["gates"])


def dec(v):
    """a number as the editor writes it (to the cm, no trailing zeros); fine for values without
    half cents, as the Grand Prix has"""
    s = f"{round(v * 100) / 100:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def numbers_of(t):
    """the numbers line after the id, for a built-in track without structures"""
    return " ".join([str(t["seed"]), str(t["trees"])] +
                    [f"{dec(x)} {dec(z)} {k} {round(yaw) % 360} {dec(h)}" for x, z, k, yaw, h in t["gates"]])


def served(ctx):
    """simulator.html and artifact.html at https://sticktime.test/ with the game's SD card files
    beside them in sdcard/ (as the Pages workflow publishes them), a page at https://another.test/
    that frames artifact.html, fengari at its CDN address; nothing else answers"""
    pages = {SITE + "simulator.html": (ROOT / "web" / "simulator.html").read_bytes(),
             SITE + "artifact.html": (ROOT / "web" / "artifact.html").read_bytes(),
             PARENT: (f'<!doctype html><iframe src="{SITE}artifact.html" width="1300" height="900"></iframe>').encode(),
             SITE + "sdcard/manifest.json": json.dumps(MANIFEST).encode()}
    for k, v in GAME_FILES.items():
        pages[SITE + "sdcard/SCRIPTS/TOOLS/" + k] = v

    def route(r):
        u = r.request.url
        if u in pages:
            r.fulfill(body=pages[u], content_type="text/html; charset=utf-8" if u.endswith(".html") or u == PARENT else "application/octet-stream")
        elif "fengari-web" in u:
            r.fulfill(body=FENGARI, content_type="application/javascript")
        else:
            r.abort()
    ctx.route("**/*", route)


def radio_done(page):
    page.wait_for_function("!sim.editor.radio().busy", timeout=10000)
    return page.evaluate("sim.editor.radio()")


def radio_tests(br, errors):
    ctx = br.new_context(viewport={"width": 1400, "height": 1000}, accept_downloads=True)
    served(ctx)
    page = ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(SITE + "simulator.html")
    wait_sim(page)
    page.evaluate(CARD)
    radio_panel(page)
    note = page.inner_text("#edRadioNote")
    check(page.is_visible("#edConnect") and page.is_hidden("#editor") and "USB Storage" in note and "Eject" in note,
          "radio: the Radio SD panel: Connect radio… and what to do on the radio")
    check("Connect the radio's SD card" in page.inner_text("#rpTracksWait") and "Connect the radio's SD card" in page.inner_text("#rpInstWait"),
          "radio: tracks and install wait for the card")

    # a folder that isn't the card
    page.evaluate(PICK, "Documents")
    page.click("#edConnect")
    r = radio_done(page)
    check(page.inner_text("#rpStatus") == NOT_CARD and r["state"] == "off", "radio: a folder without SCRIPTS is refused, plainly")
    # the card
    page.evaluate(PICK, "RADIO-SD")
    page.click("#edConnect")
    r = radio_done(page)
    check(r["state"] == "on" and r["at"] == "card" and page.inner_text("#edRadioState") == "RADIO-SD connected",
          f"radio: the card connected: {page.inner_text('#edRadioState')!r}")
    check(page.evaluate("window.__opts") == {"mode": "readwrite", "id": "sticktime-radio"}, "radio: the picker asked for read and write")
    check(page.inner_text("#edRadioSlots").count("empty") == 8 and page.is_visible("#edEditions"),
          "radio: the panel lists the card's 8 slots and the editions at once")

    # the Tracks panel: Send to radio over the same connection
    page.click("#tracksBtn")
    check(page.is_hidden("#radioPanel") and page.get_attribute("#radioBtn", "aria-expanded") == "false"
          and page.get_attribute("#tracksBtn", "aria-expanded") == "true" and page.inner_text("#edSend") == "Send to radio"
          and page.inner_text("#edRadioLineText") == "Radio SD: RADIO-SD connected.", "radio: Tracks closes Install, and shares the connection")
    page.select_option("#edTemplate", label="Grand Prix")
    page.select_option("#edSlot", "1")
    with page.expect_download() as d:
        page.click("#edSave")
    saved = pathlib.Path(d.value.path()).read_bytes().decode("ascii")
    check(page.evaluate(CARD_FILE, TRACKS + "1.txt") is None, "radio: no StickTimeTracks folder yet")
    page.click("#edSend")
    radio_done(page)
    check(page.evaluate(CARD_FILE, TRACKS + "1.txt") == saved, "radio: c1.txt on the card is Save file's text (StickTimeTracks made)")
    check(page.inner_text("#edStatus") == "Sent to the radio as track 9 (c1.txt). On the radio: restart StickTime, the track is in the Track list.",
          "radio: it says where the track went")
    shot_clip(page, OUT / "editor_connected.png")

    # another track for slot 1: asked first, with the names
    page.select_option("#edTemplate", label="Bando")
    asked = []
    page.once("dialog", lambda dl: (asked.append(dl.message), dl.dismiss()))
    page.click("#edSend")
    radio_done(page)
    check(asked and '"My Grand Prix"' in asked[0] and '"My Bando"' in asked[0], f"radio: overwriting another track asks: {asked}")
    check(page.evaluate(CARD_FILE, TRACKS + "1.txt") == saved, "radio: No leaves the card's c1.txt alone")
    page.once("dialog", lambda dl: dl.accept())
    page.click("#edSend")
    radio_done(page)
    bando = page.evaluate("sim.editor.file()")
    check(page.evaluate(CARD_FILE, TRACKS + "1.txt") == bando, "radio: Yes replaces it")
    page.select_option("#edTemplate", label="Meadow")
    meadow = page.evaluate("sim.editor.file()")

    # the radio's tracks (the editor's link to the panel), one opened in the editor (CR LF on the card)
    page.evaluate(CARD_WRITE, [TRACKS + "3.txt", saved.replace("\n", "\r\n")])
    page.click("#edRadioLink")
    radio_done(page)
    rows = page.inner_text("#edRadioSlots")
    check(page.is_hidden("#editor") and "c1 · track 9 · My Bando" in rows and "c3 · track 11 · My Grand Prix" in rows and rows.count("empty") == 6,
          "radio: the panel lists the card's slots by name")
    page.click('[data-ropen="3"]')
    check(page.is_visible("#editor") and page.is_hidden("#radioPanel") and page.input_value("#edName") == "My Grand Prix"
          and page.input_value("#edSlot") == "3" and page.evaluate("sim.editor.file()") == saved, "radio: Open in editor: the editor on slot 3")
    # both ways
    radio_panel(page)
    page.click("#edRadioToEmu")
    radio_done(page)
    check(page.evaluate(f"sim.app.sd.get('{SLOT}1.txt')") == bando and page.evaluate(f"sim.app.sd.get('{SLOT}3.txt')") == saved.replace("\n", "\r\n"),
          "radio: the radio's tracks copied into the emulator's slots")
    check(page.inner_text("#rpStatus").startswith("Copied c1 and c3 from the radio"), f"radio: {page.inner_text('#rpStatus')!r}")
    page.evaluate("(t) => sim.writeSD('/SCRIPTS/TOOLS/StickTimeTracks/c5.txt', t)", meadow)
    page.click("#edEmuToRadio")
    radio_done(page)
    check(page.evaluate(CARD_FILE, TRACKS + "5.txt") == meadow and page.evaluate(CARD_FILE, TRACKS + "1.txt") == bando,
          "radio: the emulator's tracks sent to the card")
    check(page.inner_text("#rpStatus").startswith("Sent c5 to the radio."), f"radio: only what changed is written: {page.inner_text('#rpStatus')!r}")
    page.mouse.move(0, 0)
    shot_clip(page, OUT / "radio_tracks.png", "radioPanel")

    # the card remembered on the next visit; Disconnect forgets it
    page.reload()
    wait_sim(page)
    page.wait_for_function("sim.editor.radio().state === 'on'", timeout=10000)
    radio_panel(page)
    check(page.inner_text("#edRadioState") == "RADIO-SD connected", "radio: a later visit is connected again (IndexedDB)")
    page.click("#edForget")
    page.reload()
    wait_sim(page)
    page.wait_for_timeout(500)
    check(page.evaluate("sim.editor.radio().state") == "off", "radio: Disconnect forgets the card")

    # not connected: the editor's button connects first
    page.evaluate("() => { window.showDirectoryPicker = async () => window.__pick; }")
    page.evaluate(PICK, "RADIO-SD")
    editor(page)
    check(page.inner_text("#edSend") == "Connect radio…", "radio: not connected, the editor's button says Connect radio…")
    page.click("#edSend")
    radio_done(page)
    check(page.inner_text("#edSend") == "Send to radio" and page.inner_text("#edStatus").startswith("Radio SD: RADIO-SD connected."),
          "radio: ... and connects")

    # SCRIPTS/TOOLS or StickTimeTracks picked instead of the drive
    page.select_option("#edTemplate", label="Slalom")
    for path, slot in (("RADIO-SD/SCRIPTS/TOOLS", "2"), ("RADIO-SD/SCRIPTS/TOOLS/StickTimeTracks", "4")):
        page.evaluate(PICK, path)
        radio_panel(page)
        if page.is_visible("#edForget"):
            page.click("#edForget")
        page.click("#edConnect")
        radio_done(page)
        editor(page)
        page.select_option("#edSlot", slot)
        page.click("#edSend")
        radio_done(page)
        check(page.evaluate(CARD_FILE, TRACKS + slot + ".txt") == page.evaluate("sim.editor.file()"),
              f"radio: {path.split('/')[-1]} picked: c{slot}.txt still lands in StickTimeTracks")
    radio_panel(page)
    check("Connect the card's drive" in page.inner_text("#rpInstWait"), "radio: StickTimeTracks picked: no install from there")

    # a picker that may not open here (another site's frame: SecurityError)
    page.click("#edForget")
    page.evaluate("() => { window.showDirectoryPicker = async () => { throw new DOMException('no pickers in this frame', 'SecurityError'); }; }")
    page.click("#edConnect")
    radio_done(page)
    check(page.is_hidden("#edRadio") and page.inner_text("#edRadioNote") == NO_RADIO and page.is_hidden("#rpTracksSec"),
          "radio: a SecurityError gives the Save file line")
    editor(page)
    check(page.is_hidden("#edSend"), "radio: ... and the editor has no Send to radio")
    ctx.close()

    # no picker at all (Firefox, Safari, phones): the line, and the rest still works
    ctx = br.new_context(viewport={"width": 1400, "height": 1000})
    served(ctx)
    ctx.add_init_script("delete window.showDirectoryPicker")
    page = ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(SITE + "simulator.html")
    wait_sim(page)
    radio_panel(page)
    check(page.is_hidden("#edRadio") and page.is_visible("#edRadioNote") and page.inner_text("#edRadioNote") == NO_RADIO
          and page.is_hidden("#rpInstSec") and page.is_hidden("#rpTracksSec"), "radio: without the picker, one line: use Save file")
    editor(page)
    check(page.is_hidden("#edSend") and page.is_hidden("#edRadioLine"), "radio: ... the editor without Send to radio")
    page.select_option("#edTemplate", label="Grand Prix")
    page.click("#edFly")
    check(page.evaluate("sim.test('info')")[10] == "My Grand Prix", "radio: ... and Fly it still works")
    # artifact.html in another site's frame
    page.goto(PARENT)
    frame = None
    for _ in range(100):
        frame = next((f for f in page.frames if f.url.startswith(SITE)), None)
        if frame:
            break
        page.wait_for_timeout(100)
    frame.wait_for_function("window.sim && window.sim.editor", timeout=30000)
    check(frame.evaluate("sim.editor.radio().ok") is False and frame.evaluate("document.getElementById('edRadioNote').textContent") == NO_RADIO,
          "radio: artifact.html in another site's frame gives the Save file line")
    ctx.close()


# a card from scratch: {path: text, or a list of byte values}; the stand-in picker answers with it
MAKE_CARD = """async ([name, files]) => {
  const root = await navigator.storage.getDirectory();
  try { await root.removeEntry(name, { recursive: true }); } catch (e) { }
  const card = await root.getDirectoryHandle(name, { create: true });
  for (const [path, data] of Object.entries(files)) {
    let d = card; const p = path.split('/');
    for (const s of p.slice(0, -1)) d = await d.getDirectoryHandle(s, { create: true });
    const w = await (await d.getFileHandle(p[p.length - 1], { create: true })).createWritable();
    await w.write(typeof data === 'string' ? data : new Uint8Array(data)); await w.close();
  }
  window.__pick = card;
  window.showDirectoryPicker = async () => window.__pick;
}"""
CARD_HASH = """async (path) => { try { let d = await navigator.storage.getDirectory(); const p = path.split('/');
  for (const s of p.slice(0, -1)) d = await d.getDirectoryHandle(s);
  const b = await (await (await d.getFileHandle(p[p.length - 1])).getFile()).arrayBuffer();
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', b)), (x) => x.toString(16).padStart(2, '0')).join('');
  } catch (e) { return null; } }"""
CARD_LS = """async (path) => { let d = await navigator.storage.getDirectory();
  for (const s of path.split('/')) d = await d.getDirectoryHandle(s);
  const out = []; for await (const h of d.values()) out.push(h.name); return out.sort(); }"""
PICKED = "[...document.querySelectorAll('#edEditions [data-ed]')].filter((i) => i.checked).map((i) => i.dataset.ed)"
sha = lambda b: hashlib.sha256(b if isinstance(b, bytes) else b.encode()).hexdigest()  # noqa: E731


def connect_card(page, name, files):
    """a card made and connected in the Radio SD panel, which reads it (its tracks, the game on it)"""
    page.evaluate(MAKE_CARD, [name, files])
    radio_panel(page)
    if page.is_visible("#edForget"):
        page.click("#edForget")
    page.click("#edConnect")
    return radio_done(page)


def install_tests(br, errors):
    ctx = br.new_context(viewport={"width": 1400, "height": 1000})
    served(ctx)
    page = ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(SITE + "simulator.html")
    wait_sim(page)
    version, T = MANIFEST["version"], "CARD/SCRIPTS/TOOLS/"

    # the edition to start with: what RADIO/radio.yml says the radio is, else nothing
    for board, want in (("tx16s", ["color"]), ("x7", ["lite"]), ("tx12mk2", ["bw"]), ("mystery9", [])):
        connect_card(page, "CARD", {"SCRIPTS/TOOLS/StickTime.dat": "my settings\n", "RADIO/radio.yml": f"semver: 2.11.3\nboard: {board}\n"})
        check(page.evaluate(PICKED) == want and page.inner_text("#edEditions").count("not installed") == 3,
              f"install: board {board} in radio.yml: {want or 'nothing'} picked, nothing installed yet")
    check("which this page doesn't know" in page.inner_text("#edInstallHint"), "install: an unknown board: the player picks")

    # a fresh install of all three editions (the card from radio.yml: a TX16S)
    user = {"SCRIPTS/TOOLS/StickTime.dat": "my settings\n", "SCRIPTS/TOOLS/FPVSim.dat": "FPVSIM old\n", "RADIO/radio.yml": "board: tx16s\n"}
    connect_card(page, "CARD", user)
    check(f"StickTime {version} from this site" in page.inner_text("#edInstallHead"), "install: the site's version shown")
    page.check('#edEditions [data-ed="bw"]')
    page.check('#edEditions [data-ed="lite"]')
    page.click("#edInstallGo")
    radio_done(page)
    check(page.inner_text("#rpStatus") == f"StickTime {version} is on the radio: Color, B&W and Lite. Eject the drive before unplugging it.",
          f"install: {page.inner_text('#rpStatus')!r}")
    wrong = [k for k, v in GAME_FILES.items() if page.evaluate(CARD_HASH, T + k) != sha(v)]
    check(not wrong, f"install: every file of the release on the card as published ({len(GAME_FILES)} files){wrong}")
    for luac in ("StickTimeBW/game.luac", "StickTimeLite/game.luac"):
        check(page.evaluate(CARD_HASH, T + luac) == sha((ROOT / "sdcard/SCRIPTS/TOOLS" / luac).read_bytes()), f"install: {luac} byte for byte the repo's")
    check(all(page.evaluate(CARD_HASH, "CARD/" + k) == sha(v) for k, v in user.items()), "install: the saves and radio.yml untouched")
    check(page.inner_text("#edEditions").count("up to date") == 3, "install: all three up to date afterwards")
    check(not any(n.endswith(".new") for d in ("", "StickTimeBW", "StickTimeLite") for n in page.evaluate(CARD_LS, (T + d).rstrip("/"))),
          "install: no temporary files left")
    page.click("#edInstallGo")
    radio_done(page)
    check(page.inner_text("#rpStatus").startswith(f"StickTime {version} was already on the radio"), "install: again: nothing to write")

    # an update over an old version: stale files go, the player's files stay byte for byte
    old_luac = [27, 76, 117, 97, 83, 0, 25, 147, 13, 10, 26, 10, 4, 4, 4, 0, 1, 2, 3]
    mine = {"SCRIPTS/TOOLS/StickTimeBW.dat": "FPVSIM2 lay=2 track=9 l9=4321\n", "SCRIPTS/TOOLS/StickTimeLite/data.txt": "lite save 1 2 3\n",
            "SCRIPTS/TOOLS/StickTimeTracks/c1.txt": "My Loop\n1 4242 7 9 0 0 1 0 0 0 40 1 0 0\n",
            "SCRIPTS/TOOLS/StickTimeGhosts/c3.txt": "ghost 1 2 3\n", "SCRIPTS/TOOLS/FPVSimBW.dat": "old\n"}
    old = dict(mine, **{"SCRIPTS/TOOLS/StickTimeBW.lua": "local toolName = \"TNS|StickTime BW|TNE\"\n--[[\n  StickTime BW v1.6.5  -  loader\n]]\n",
                        "SCRIPTS/TOOLS/StickTimeBW/core.lua": "-- old core\n", "SCRIPTS/TOOLS/StickTimeBW/core.luac": old_luac,
                        "SCRIPTS/TOOLS/StickTimeBW/game.luac": old_luac,
                        "SCRIPTS/TOOLS/StickTimeLite.lua": "--[[\n  StickTime Lite v1.6.5  -  loader\n]]\n",
                        "SCRIPTS/TOOLS/StickTimeLite/t9.txt": "1 9 0 0 1 0 0\n"})
    connect_card(page, "CARD", old)
    states = page.inner_text("#edEditions")
    check(page.evaluate(PICKED) == ["bw", "lite"] and "will be updated (1.6.5 on the card), 1 old file removed" in states,
          f"install: B&W and Lite found and picked, older: {states!r}")
    check("c1 · track 9 · My Loop" in page.inner_text("#edRadioSlots"), "install: the panel lists the card's tracks beside it")
    page.mouse.move(0, 0)
    shot_clip(page, OUT / "radio_panel_light.png", "radioPanel")
    page.emulate_media(color_scheme="dark")
    shot_clip(page, OUT / "radio_panel_dark.png", "radioPanel")
    page.emulate_media(color_scheme="light")
    page.click("#edInstallGo")
    radio_done(page)
    bw, lite = page.evaluate(CARD_LS, T + "StickTimeBW"), page.evaluate(CARD_LS, T + "StickTimeLite")
    check("core.luac" not in bw and "t9.txt" not in lite, "install: the stale core.luac and t9.txt removed")
    check(bw == sorted(k.split("/")[1] for k in GAME_FILES if k.startswith("StickTimeBW/")), f"install: StickTimeBW/ is the release's: {bw}")
    check(all(page.evaluate(CARD_HASH, "CARD/" + k) == sha(v) for k, v in mine.items()),
          "install: saves, StickTimeLite/data.txt, tracks and ghosts kept byte for byte")
    check(page.evaluate(CARD_HASH, T + "StickTimeBW/game.luac") == sha(GAME_FILES["StickTimeBW/game.luac"]), "install: the new game.luac")
    check(page.evaluate(CARD_HASH, T + "StickTime.lua") is None and page.inner_text("#edEditions").count("up to date") == 2,
          "install: Color not picked, not put on the card; B&W and Lite up to date")

    # a newer version on the card: asked first
    connect_card(page, "CARD", {"SCRIPTS/TOOLS/StickTime.lua": "--[[\n  StickTime v9.9.9  -  from the future\n]]\n"})
    check("newer on the card (9.9.9)" in page.inner_text("#edEditions") and page.evaluate(PICKED) == ["color"], "install: a newer version on the card is shown")
    asked = []
    page.once("dialog", lambda dl: (asked.append(dl.message), dl.dismiss()))
    page.click("#edInstallGo")
    radio_done(page)
    check(asked and "9.9.9" in asked[0] and page.inner_text("#rpStatus") == "Nothing changed on the radio."
          and page.evaluate(CARD_HASH, T + "StickTime.lua") == sha("--[[\n  StickTime v9.9.9  -  from the future\n]]\n"),
          f"install: asked before replacing a newer one, and No changes nothing: {asked}")
    ctx.close()

    # no install where the site's files aren't beside the page: artifact.html, file:// pages
    ctx = br.new_context(viewport={"width": 1400, "height": 1000})
    served(ctx)
    page = ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(SITE + "artifact.html")
    wait_sim(page)
    connect_card(page, "CARD", {"SCRIPTS/TOOLS/StickTime.dat": "x\n"})
    check(page.evaluate("sim.editor.radio().state") == "on" and page.is_hidden("#edInstallPanel") and page.is_hidden("#rpInstWait")
          and page.is_visible("#edInstallNote") and "latest release" in page.inner_text("#edInstallNote"),
          "install: artifact.html hides it and points to the release zip")
    ctx.close()
    ctx = br.new_context()
    offline(ctx)
    page = ctx.new_page()
    page.goto(SIM)
    wait_sim(page)
    check(page.evaluate("sim.editor.radio().game") == "", "install: a file:// page has no site files to install from")
    ctx.close()


def toolbar_shots(br, errors):
    """the header's controls in one row at 1400 and 1280 px, two tidy rows at 1100, stacked at 390;
    the Tracks and Install icons up close (1x, 2x, dark)"""
    for w, rows in ((1400, 1), (1280, 1), (1100, 2), (390, None)):
        ctx = br.new_context(viewport={"width": w, "height": 900})
        offline(ctx)
        page = ctx.new_page()
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(SIM)
        wait_sim(page)
        tops = page.evaluate("[...new Set([...document.querySelectorAll('.controls > .ctl-group')].map((g) => Math.round(g.getBoundingClientRect().top)))].length")
        wide = page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        labels = (page.inner_text("#tracksBtn").strip(), page.inner_text("#radioBtn").strip())
        ok = wide and labels == ("Tracks", "Install") and (rows is None or tops == rows)
        check(ok, f"toolbar at {w} px: " + (f"{rows} row{'s' if rows > 1 else ''} of controls ({tops})" if rows else "nothing sticks out sideways")
              + f", Tracks and Install side by side {labels}")
        page.locator("header.top").screenshot(path=str(OUT / f"toolbar_{w}.png"))
        print(f"wrote test/shots/toolbar_{w}.png")
        ctx.close()
    for scale, scheme in ((1, "light"), (2, "light"), (2, "dark")):
        ctx = br.new_context(viewport={"width": 1400, "height": 900}, device_scale_factor=scale, color_scheme=scheme)
        offline(ctx)
        page = ctx.new_page()
        page.goto(SIM)
        wait_sim(page)
        a, b = page.locator("#tracksBtn").bounding_box(), page.locator("#radioBtn").bounding_box()
        name = f"icons_{scale}x_{scheme}.png"
        page.screenshot(path=str(OUT / name), clip={"x": a["x"] - 4, "y": a["y"] - 4, "width": b["x"] + b["width"] - a["x"] + 8, "height": a["height"] + 8})
        print("wrote test/shots/" + name)
        ctx.close()


def panel_tests(br, errors):
    """Tracks and Install: two panels in the same place, one open at a time, each with its Close;
    the open one's button pressed; keys in them never reach the game"""
    ctx = br.new_context(viewport={"width": 1400, "height": 1000})
    offline(ctx)
    page = ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(SIM)
    wait_sim(page)
    expanded = lambda: (page.get_attribute("#tracksBtn", "aria-expanded"), page.get_attribute("#radioBtn", "aria-expanded"))  # noqa: E731
    page.click("#radioBtn")
    check(page.is_visible("#radioPanel") and page.is_hidden("#editor") and expanded() == ("false", "true")
          and page.text_content("#rpTitle").startswith("Radio & install"), "panels: Install opens its own panel, its button pressed")
    page.click("#tracksBtn")
    check(page.is_visible("#editor") and page.is_hidden("#radioPanel") and expanded() == ("true", "false")
          and page.text_content("#edTitle").startswith("Track editor"), "panels: Tracks opens the editor and closes Install")
    page.click("#edRadioLink")
    check(page.is_visible("#radioPanel") and page.is_hidden("#editor"), "panels: the editor's link line opens Install")
    page.evaluate("sim.engine.__mark = 1")
    page.focus("#rpClose")
    page.keyboard.press("r")
    page.keyboard.press("Enter")
    check(page.is_hidden("#radioPanel") and expanded() == ("false", "false") and page.evaluate("sim.engine.__mark") == 1
          and page.evaluate("document.activeElement.id") == "radioBtn", "panels: Close (with Enter) closes it; the keys don't reach the game")
    page.click("#tracksBtn")
    page.click("#tracksBtn")
    check(page.is_hidden("#editor") and expanded() == ("false", "false"), "panels: a second click on Tracks closes it")
    ctx.close()


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
        check(page.input_value("#edName") == "My Grand Prix" and len(gp["gates"]) == NGP, f"the Grand Prix template: {NGP} gates")
        check(page.evaluate("sim.editor.problems()") == [] and page.is_enabled("#edFly") and page.is_enabled("#edSave"),
              "nothing in the way: Fly it and Save file on")
        page.select_option("#edSlot", "1")
        with page.expect_download() as d:
            page.click("#edSave")
        check(d.value.suggested_filename == "c1.txt", "Save file downloads c1.txt")
        text = pathlib.Path(d.value.path()).read_bytes().decode("ascii")
        name, nums = check_file(text, NGP, 0, "the Grand Prix's c1.txt")
        check(name == "My Grand Prix" and nums == numbers_of(GP), "its numbers are the Grand Prix's: seed, trees, every gate as in TRACKS")
        check(page.evaluate("sim.editor.file()") == text, "the download is the editor's file")

        # ---- Fly it: slot 1 is track 9, in Practice
        page.click("#edFly")
        check(page.is_hidden("#editor"), "Fly it closes the editor")
        info = page.evaluate("sim.test('info')")
        check(info[0] == 9 and info[10] == "My Grand Prix", f"the game lists track 9 as {info[10]!r}")
        get = page.evaluate("sim.test('get')")
        check(info[2] == 2 and get[18] == NGP and get[15] in (3, 4), f"Practice on track 9 with its {NGP} gates")
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
        check(t["name"] == "My Grand Prix" and len(t["gates"]) == NGP, f"a CR LF file opens: {status!r}")
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
        check(info[10] == "My Meadow" and info[9] == 3 and page.evaluate("sim.test('get')")[18] == len(TEMPLATES["Meadow"]["gates"]) + 1,
              "track 11: Meadow, its wall and its gap")

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
              and page.evaluate("sim.test('get')")[18] == len(TEMPLATES["Hoop Forest"]["gates"]), "StickTime BW on a TX12: Hoop Forest flown as track 12")
        page.evaluate("sim.radio('tx16s')")

        # ---- screenshots: desktop (light and dark), phone width
        page.click("#tracksBtn")
        page.select_option("#edTemplate", label="Bando")
        click_map(page, 0, 34)                                   # a wall of the Bando: its group
        check(len(page.evaluate("sim.editor.selected()")) == 4, "a click on a gap in a wall selects the wall (4 items)")
        page.mouse.move(0, 0)
        shot_clip(page, OUT / "editor_desktop.png")
        page.emulate_media(color_scheme="dark")
        page.check("#edTrees")
        shot_clip(page, OUT / "editor_desktop_dark.png")
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
        px, py = page.evaluate("([x, z]) => sim.editor.at(x, z)", GP["gates"][2][:2])   # gate 3
        page.touchscreen.tap(px, py)
        check(len(page.evaluate("sim.editor.selected()")) == 1, "a tap selects a gate")
        shot_clip(page, OUT / "editor_phone.png")
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

        # ---- the radio's SD card
        radio_tests(br, errors)
        install_tests(br, errors)
        toolbar_shots(br, errors)
        panel_tests(br, errors)
        br.close()
    for e in errors:
        print("page error:", e)
    check(not errors, "no script errors on the page")
    print("ALL OK" if not fails else f"{len(fails)} FAILED")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
