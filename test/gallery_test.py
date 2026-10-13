#!/usr/bin/env python3
"""The track gallery: tracks/ in the repo (tools/gallery.py) and Tracks > Gallery in the web
emulator, in headless Chromium.

Every track in tracks/ passes the checker, opens from the gallery as it is (the file unchanged, so
its id too) with nothing for the editor's Check to say, and the game builds it: Fly it lists it as
track 9 under its name and starts Practice on it. The page's own list (file://, offline) is the one
built into it; on the site (https://sticktime.test/, as the Pages workflow publishes it) the page
asks for tracks/index.json, so a track merged after the page was built shows up, and a broken
index.json leaves the built-in list. The checker refuses what the game or the editor couldn't
take. Screenshots: test/shots/gallery_desktop.png, gallery_phone.png.

    python test/gallery_test.py           everything
    python test/gallery_test.py --tracks  only tracks/ (what a pull request with a track runs)"""
import json
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import gallery  # noqa: E402

OUT = ROOT / "test" / "shots"
SIM = (ROOT / "web" / "simulator.html").as_uri()
SITE = "https://sticktime.test/"
fails = []


def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        fails.append(what)


def checker_tests():
    """the checker on good and broken files"""
    good = (ROOT / "tracks" / "multigp-2020-gq.txt").read_bytes().replace(b"\r\n", b"\n").decode()
    check(gallery.track_problems(good) == [], "checker: a track as Save file writes it passes")
    name, line = good.split("\n")[:2]
    bad = {
        "the id": name + "\n1 12345 " + line.split(" ", 2)[2] + "\n",
        "a name too long": "A name far too long here\n" + line + "\n",
        "a '/' in the name": "Up/Down\n" + line + "\n",
        "an exponent": name + "\n" + line.replace(" 25.5 ", " 2.55e1 ", 1) + "\n",
        "three decimals": name + "\n" + line.replace(" 25.5 ", " 25.505 ", 1) + "\n",
        "no numbers line": name + "\n",
        "gate type 9": name + "\n" + line.replace(" 1 0 0 ", " 9 0 0 ", 1) + "\n",
        "one gate": name + "\n1 1 20 0 0 0 1 0 0\n",
    }
    for what, text in bad.items():
        check(gallery.track_problems(text) != [], f"checker: refuses {what}")
    check(gallery.info_problems({"by": "Me"}) == [], "checker: 'by' alone is enough")
    for what, info in {"no by": {"about": "x"}, "another key": {"by": "Me", "url": "x"}, "an http source": {"by": "Me", "source": "http://x.org"},
                       "a long by": {"by": "x" * 61}, "a line break": {"by": "Me", "about": "a\nb"}, "a list": ["Me"]}.items():
        check(gallery.info_problems(info) != [], f"checker: refuses {what}")
    with tempfile.TemporaryDirectory() as tmp:
        d = pathlib.Path(tmp)
        (d / "ok-track.txt").write_bytes(good.replace("\n", "\r\n").encode())       # a Windows checkout
        (d / "ok-track.json").write_text('{"by": "Me", "about": "A test.", "source": "https://example.org/x"}')
        tracks, probs = gallery.gallery(d)
        check(len(tracks) == 1 and not probs and tracks[0]["text"] == good and tracks[0]["name"] == name,
              f"checker: CR LF line ends read as the repo has them: {probs}")
        (d / "Bad Name.txt").write_text(good)
        (d / "lonely.txt").write_text(good.replace(name, "Lonely"))
        (d / "same-name.txt").write_bytes(good.encode())
        (d / "same-name.json").write_text('{"by": "Someone"}')
        (d / "notes.md").write_text("x")
        _, probs = gallery.gallery(d)
        text = " | ".join(probs)
        for what in ("Bad Name.txt: a name of lowercase", "lonely.txt: no lonely.json", "notes.md: the gallery takes",
                     "same-name.txt: ok-track.txt has the name", "same-name.txt: the same track as ok-track.txt"):
            check(what in text, f"checker: {what}...")


def wait_sim(page):
    page.wait_for_function("window.sim && window.sim.engine && window.sim.engine.frames > 2 && window.sim.editor", timeout=30000)


def cards(page):
    return page.eval_on_selector_all("#edCards .ed-card strong", "els => els.map(e => e.textContent)")


def open_mine(page):
    """Tracks > My tracks, the radio's slots read"""
    if page.is_hidden("#editor"):
        page.click("#tracksBtn")
    if page.is_hidden("#edMine"):
        page.click("#edMineBtn")
    page.wait_for_function("!sim.editor.radio().busy", timeout=10000)


def open_gallery(page):
    if page.is_hidden("#editor"):
        page.click("#tracksBtn")
    if page.is_hidden("#edGallery"):
        page.click("#edGalBtn")


def served(ctx, index):
    """simulator.html at https://sticktime.test/ with tracks/index.json beside it (or a 404)"""
    sim = (ROOT / "web" / "simulator.html").read_bytes()

    def route(r):
        u = r.request.url
        if u == SITE + "simulator.html":
            r.fulfill(body=sim, content_type="text/html; charset=utf-8")
        elif u.split("?")[0] == SITE + "tracks/index.json" and index is not None:
            r.fulfill(body=index, content_type="application/json")
        elif u.startswith(SITE):
            r.fulfill(status=404, body="not found")
        else:
            r.abort()
    ctx.route("**/*", route)


SLOT = "/SCRIPTS/TOOLS/StickTimeTracks/c"


def slot_text(page, n):
    return page.evaluate(f"sim.app.sd.get('{SLOT}{n}.txt') ?? null")


def card_line(page, i, cls):
    return page.evaluate(f"(document.querySelectorAll('#edCards .ed-card')[{i}].querySelector('.{cls}') || {{}}).textContent || ''")


def tracks_tests(br, errors, tracks):
    """every track of tracks/, from the site's index.json: opened, checked, flown, each into an
    empty slot while there is one (then the editor's slot, asked first); the cards say which slots
    have them; flown again from the slot that has it"""
    ctx = br.new_context(viewport={"width": 1400, "height": 1000})
    served(ctx, gallery.index(tracks).encode())
    page = ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    asked = []
    page.on("dialog", lambda dl: (asked.append(dl.message), dl.accept()))
    page.goto(SITE + "simulator.html")
    wait_sim(page)
    open_gallery(page)
    names = [t["name"] for t in tracks]
    page.wait_for_function(f"document.querySelectorAll('#edCards .ed-card').length === {len(names)}", timeout=10000)
    check(cards(page) == names, f"site: the gallery lists tracks/ ({len(names)} tracks) in file order")
    held = {}
    for i, t in enumerate(tracks):
        open_gallery(page)
        page.click(f"[data-gopen='{i}']")
        r = page.evaluate("({ file: sim.editor.file(), probs: sim.editor.problems(), name: document.getElementById('edName').value })")
        check(r["file"] == t["text"] and r["name"] == t["name"] and not r["probs"] and page.is_hidden("#edGallery") and page.is_visible("#edMap"),
              f"{t['file']}: opens as it is, Check OK {r['probs'] if r['probs'] else ''}")
        n = len(asked)
        page.click("#edFly")
        slot = int(page.input_value("#edSlot"))
        info = page.evaluate("sim.test('info')")
        want = i + 1 if i < 8 else slot
        replaced = asked[n:]
        check(slot == want and info[10] == t["name"] and slot_text(page, slot) == t["text"] and page.inner_text("#edStatus").startswith("Flying " + t["name"])
              and (len(replaced) == (1 if i >= 8 else 0)),
              f"{t['file']}: Fly it: in c{slot} (track {8 + slot}), the game builds \"{info[10]}\" and flies it" + (f"; asked {replaced}" if i >= 8 else ""))
        held[slot] = i
    check(all("from the gallery" not in a for a in asked), "site: opening a gallery track over another gallery track asks nothing")
    open_gallery(page)
    ok = all(card_line(page, i, "ed-in") == f"In c{n} in the emulator" for n, i in held.items())
    check(ok and all(card_line(page, i, "ed-in") == "" for i in range(len(tracks)) if i not in held.values()),
          "site: each card says which slot has its track")
    n = len(asked)
    open_gallery(page)
    page.click("[data-gopen='2']")
    page.click("#edFly")
    check(int(page.input_value("#edSlot")) == 3 and len(asked) == n and page.evaluate("sim.test('info')")[10] == tracks[2]["name"],
          "site: opened again: on the slot that has it, flown with nothing asked")

    # another version of a gallery track in a slot (the same name, a gate moved): Update
    old = tracks[3]["text"].replace(" 1 0 0 ", " 1 5 0 ", 1)
    assert old != tracks[3]["text"]
    page.evaluate(f"sim.writeSD('{SLOT}4.txt', {json.dumps(old)})")
    page.evaluate("sim.boot()")                                    # the game in its menu
    open_mine(page)
    check(page.is_visible("#edGalSync") and page.inner_text("#edUpdList").startswith('"' + tracks[3]["name"] + '": an older version in c4 in the emulator')
          and page.is_visible("[data-gsync='3']"), f"site: My tracks shows the older version in c4: {page.inner_text('#edUpdList')!r}")
    n = len(asked)
    page.click("[data-gsync='3']")
    check(len(asked) == n + 1 and tracks[3]["name"] in asked[-1] and "c4 in the emulator" in asked[-1] and "start over" in asked[-1],
          f"site: Update asks first: {asked[n:]}")
    st = page.inner_text("#edMineStatus")
    open_gallery(page)
    check(slot_text(page, 4) == tracks[3]["text"] and page.is_hidden("#edGalSync") and card_line(page, 3, "ed-in") == "In c4 in the emulator"
          and st == "Updated c4 in the emulator.", f"site: Update puts the gallery's version in c4, the game started again: {st!r}")
    ctx.close()


MAKE_CARD = """async ([name, files]) => {
  const root = await navigator.storage.getDirectory();
  try { await root.removeEntry(name, { recursive: true }); } catch (e) { }
  const card = await root.getDirectoryHandle(name, { create: true });
  for (const [path, data] of Object.entries(files)) {
    let d = card; const p = path.split('/');
    for (const s of p.slice(0, -1)) d = await d.getDirectoryHandle(s, { create: true });
    const w = await (await d.getFileHandle(p[p.length - 1], { create: true })).createWritable();
    await w.write(data); await w.close();
  }
  window.__pick = card;
  window.showDirectoryPicker = async () => window.__pick;
}"""
CARD_FILE = """async (path) => { try { let d = await navigator.storage.getDirectory(); const p = path.split('/');
  for (const s of p.slice(0, -1)) d = await d.getDirectoryHandle(s);
  return await (await (await d.getFileHandle(p[p.length - 1])).getFile()).text(); } catch (e) { return null; } }"""


def radio_tests(br, errors, tracks):
    """the radio's slots in the cards; Update on the radio; Send to radio doesn't make a second copy"""
    ctx = br.new_context(viewport={"width": 1400, "height": 1000})
    served(ctx, gallery.index(tracks).encode())
    page = ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    asked = []
    page.on("dialog", lambda dl: (asked.append(dl.message), dl.accept()))
    page.goto(SITE + "simulator.html")
    wait_sim(page)
    T = "SCRIPTS/TOOLS/StickTimeTracks/c"
    old = tracks[0]["text"].replace(" 1 0 0 ", " 1 5 0 ", 1)
    page.evaluate(MAKE_CARD, ["RADIO", {"SCRIPTS/TOOLS/StickTime.lua": "-- the game\n", T + "5.txt": old.replace("\n", "\r\n"), T + "6.txt": tracks[1]["text"]}])
    page.click("#radioBtn")
    page.click("#edConnect")
    page.wait_for_function("sim.editor.radio().state === 'on' && !sim.editor.radio().busy", timeout=10000)
    open_mine(page)
    page.wait_for_function("document.querySelector('#edUpdList li')", timeout=10000)
    check(page.inner_text("#edUpdList").startswith('"' + tracks[0]["name"] + '": an older version in c5 on the radio'),
          f"radio: My tracks shows the radio's older version: {page.inner_text('#edUpdList')!r}")
    page.click("[data-gsync='0']")
    page.wait_for_function("!sim.editor.radio().busy", timeout=10000)
    st = page.inner_text("#edMineStatus")
    open_gallery(page)
    check(page.evaluate(CARD_FILE, "RADIO/" + T + "5.txt") == tracks[0]["text"] and "c5 on the radio" in asked[-1]
          and st.startswith("Updated c5 on the radio") and card_line(page, 0, "ed-in") == "In c5 on the radio" and card_line(page, 1, "ed-in") == "In c6 on the radio",
          f"radio: Update writes the gallery's version to c5 on the card; the cards say where they are: {st!r}")
    # the slot list has the radio's slots beside the emulator's
    opts = page.eval_on_selector_all("#edSlot option", "els => els.map(e => e.textContent)")
    check(opts[5] == f"c6 · track 14 · {tracks[1]['name']} (radio only)" and opts[4] == f"c5 · track 13 · {tracks[0]['name']} (radio only)"
          and opts[6] == "c7 · track 15 · empty", f"radio: the slot list shows the radio's slots too: {opts[4:7]}")
    # a track the radio has: opened on its slot
    page.click("[data-gopen='1']")
    check(int(page.input_value("#edSlot")) == 6 and "it is in c6 (track 14) on the radio." in page.inner_text("#edStatus"),
          f"radio: a gallery track the radio has in c6 opens on c6: {page.inner_text('#edStatus')!r}")
    page.click("#edFly")
    page.click("#tracksBtn")
    opts = page.eval_on_selector_all("#edSlot option", "els => els.map(e => e.textContent)")
    check(opts[5] == f"c6 · track 14 · {tracks[1]['name']} (emulator and radio)" and page.inner_text("#edEmuHas") == "c6: this track"
          and page.inner_text("#edRadioLineText") == "c6: this track · RADIO", f"radio: flown in c6 here too: {opts[5]!r}")
    # the slots that differ: a line to My tracks, where ← copies the radio's c5 to the emulator
    check(page.is_visible("#edSyncLine") and page.inner_text("#edSyncText") == "The emulator and the radio hold different tracks in c5."
          and page.is_visible("#edSyncMine"), f"radio: the editor says where the slots differ: {page.inner_text('#edSyncText')!r}")
    page.click("#edSyncMine")
    page.wait_for_function("!sim.editor.radio().busy", timeout=10000)
    page.click('[data-scopy="e5"]')
    st = page.inner_text("#edMineStatus")
    page.click("#edMineBtn")
    check(slot_text(page, 5) == tracks[0]["text"] and page.is_hidden("#edSyncLine") and st.startswith("Copied c5 from the radio to the emulator"),
          f"radio: ← (My tracks): c5 copied, nothing differs ({st!r})")
    # Send to radio of a track the radio has in another slot: no second copy
    page.select_option("#edSlot", "2")
    page.click("#edSend")
    page.wait_for_function("!sim.editor.radio().busy", timeout=10000)
    check(page.evaluate(CARD_FILE, f"RADIO/{T}2.txt") is None and page.inner_text("#edStatus").startswith("The radio has this track already, in c6"),
          f"radio: Send to radio to c2 of a track the radio has in c6: nothing sent ({page.inner_text('#edStatus')!r})")
    # the slot list picks where the track goes and never changes it; Open (Your tracks) opens a slot's
    before = page.evaluate("sim.editor.file()")
    page.select_option("#edSlot", "5")
    check(page.evaluate("sim.editor.file()") == before and page.inner_text("#edEmuHas") == f'c5: "{tracks[0]["name"]}"'
          and page.inner_text("#edRadioLineText") == f'c5: "{tracks[0]["name"]}" · RADIO',
          f"radio: picking c5 keeps the track; the rows say what c5 holds ({page.inner_text('#edEmuHas')!r})")
    open_gallery(page)
    mine_rows = page.eval_on_selector_all("#edOpenList li", "els => els.map(e => e.textContent.replace(/\\s+/g, ' ').trim())")  # (c5 name where Open)
    check(any(r.startswith("c5 " + tracks[0]["name"] + " emulator and radio") for r in mine_rows), f"radio: Open lists the slots' tracks: {mine_rows}")
    page.click('[data-sopen="e5"]')
    check(page.evaluate("sim.editor.file()") == tracks[0]["text"] and int(page.input_value("#edSlot")) == 5 and page.inner_text("#edEmuHas") == "c5: this track",
          "radio: Open (Your tracks, c5) puts its track in the editor")
    page.select_option("#edSlot", "2")
    # a file opened that the radio has: on its slot
    page.click("#edGalBtn")
    page.click("button[aria-label='Open a copy of Meadow']")
    with tempfile.TemporaryDirectory() as tmp:
        f = pathlib.Path(tmp) / "some-name.txt"
        f.write_text(old.replace("\n", "\r\n"), newline="")
        page.evaluate("document.getElementById('edStatus').textContent = ''")
        page.set_input_files("#edOpen", str(f))
        page.wait_for_function("document.getElementById('edStatus').textContent.includes('some-name.txt')", timeout=5000)
    # (c5 on the radio has the gallery's version by now: this older one is in no slot)
    check(int(page.input_value("#edSlot")) == 2, f"radio: a file in no slot stays on the slot picked (c{page.input_value('#edSlot')})")
    with tempfile.TemporaryDirectory() as tmp:
        f = pathlib.Path(tmp) / "some-name.txt"
        f.write_text(tracks[0]["text"], newline="")
        page.evaluate("document.getElementById('edStatus').textContent = ''")
        page.set_input_files("#edOpen", str(f))
        page.wait_for_function("document.getElementById('edStatus').textContent.includes('some-name.txt')", timeout=5000)
    check(int(page.input_value("#edSlot")) == 5, f"radio: a file the radio has in c5 opens on c5 (c{page.input_value('#edSlot')})")
    open_gallery(page)
    page.click("[data-gopen='2']")
    slot = int(page.input_value("#edSlot"))
    page.click("#edSend")
    page.wait_for_function("!sim.editor.radio().busy", timeout=10000)
    open_gallery(page)
    check(page.evaluate(CARD_FILE, f"RADIO/{T}{slot}.txt") == tracks[2]["text"] and card_line(page, 2, "ed-in") == f"In c{slot} on the radio",
          f"radio: Send to radio, and the card says c{slot} on the radio at once")
    ctx.close()


def page_tests(br, errors, tracks):
    """the built-in list, the site's list with a newer track, a broken index.json, keys, shots"""
    built = json.loads(gallery.index(tracks))["tracks"]
    # offline: the page's own list
    ctx = br.new_context(viewport={"width": 1400, "height": 1000})
    ctx.route("http*://**", lambda r: r.abort())
    page = ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(SIM)
    wait_sim(page)
    page.click("#tracksBtn")
    check(page.is_hidden("#edGallery") and page.get_attribute("#edGalBtn", "aria-expanded") == "false", "page: the editor opens on the map")
    page.click("#edGalBtn")
    check(page.is_visible("#edGallery") and page.is_hidden("#edMap") and page.get_attribute("#edGalBtn", "aria-expanded") == "true",
          "page: Gallery shows the gallery in place of the map")
    bundled = page.evaluate("GALLERY.tracks.map(t => t.name)")
    check(cards(page) == bundled and bundled == [t["name"] for t in built], f"page (file://): the built-in list, as tracks/ has it ({len(bundled)})")
    links = page.eval_on_selector_all("#edCards a", "els => els.map(e => [e.href, e.target, e.rel])")
    check(len(links) == sum(1 for t in built if t.get("source")) and all(h.startswith("https://") and tg == "_blank" and "noopener" in r for h, tg, r in links),
          "page: source links open apart (https only)")
    blank = page.evaluate("""() => [...document.querySelectorAll('#edCards canvas')].filter(c => {
      const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let lit = 0;
      for (let i = 0; i < d.length; i += 4) if (d[i] > 200 && d[i + 1] > 200) lit++;
      return lit < 20; }).length""")
    check(blank == 0, f"page: every card has its map drawn ({blank} blank)")
    # the map's keys don't reach the hidden map, Escape goes back to it; the game's keys stay off
    page.evaluate("document.getElementById('edGalBtn').focus()")
    before = page.evaluate("sim.editor.file()")
    page.keyboard.press("Delete")
    page.keyboard.press("r")
    check(page.evaluate("sim.editor.file()") == before, "page: the map's keys do nothing with the gallery shown")
    page.keyboard.press("Escape")
    check(page.is_hidden("#edGallery") and page.is_visible("#edMap") and page.is_visible("#editor"), "page: Escape goes back to the map")
    # Open: new tracks (Blank and the built-in ones), your slots, the gallery, in one place
    page.click("#edGalBtn")
    new = page.eval_on_selector_all("#edNewCards button", "els => els.map(e => e.getAttribute('aria-label'))")
    order = page.eval_on_selector_all("#edGallery h4", "els => els.map(e => e.firstChild.textContent.trim())")
    check(new[0] == "Open a blank track" and new[1:] == ["Open a copy of " + t for t in ("Meadow", "Figure 8", "Dive Tower", "Slalom", "Hoop Forest", "Grand Prix", "Bando", "Pro Track")]
          and order == ["Your tracks", "New track", "Gallery"] and page.inner_text("#edOpenList").startswith("No tracks in your slots yet.")
          and page.is_visible("#edGallery .ed-phead .file-btn"), f"page: Open: your tracks, new tracks, the gallery; a file at the top: {order}")
    page.click("button[aria-label='Open a copy of Slalom']")
    check(page.is_hidden("#edGallery") and page.input_value("#edName") == "My Slalom" and page.inner_text("#edEditing") == "Editing a local copy of My Slalom (kept in this browser as you edit): in no slot yet",
          f"page: Start from Slalom: a copy in the editor, in no slot yet ({page.inner_text('#edEditing')!r})")
    page.click("#edGalBtn")
    page.click("[data-gopen='1']")
    check(page.evaluate("sim.editor.file()") == built[1]["text"] and page.input_value("#edName") == bundled[1],
          "page: a gallery track: opened as it is (not a copy)")
    page.click("#edGalBtn")
    OUT.mkdir(parents=True, exist_ok=True)
    page.evaluate("document.querySelector('header.top').style.position = 'static'")
    page.locator("#editor").screenshot(path=str(OUT / "gallery_desktop.png"))
    print("wrote test/shots/gallery_desktop.png")
    # a track of your own isn't lost to a gallery track without a question
    page.click("#edGalBtn")
    page.click("#edGalBtn")
    page.click("button[aria-label='Open a copy of Meadow']")
    page.locator("#edName").fill("Mine")
    page.locator("#edName").press("Tab")
    page.click("#edGalBtn")
    asked = []
    page.once("dialog", lambda dl: (asked.append(dl.message), dl.dismiss()))
    page.click("[data-gopen='0']")
    check(len(asked) == 1 and '"Mine"' in asked[0] and page.input_value("#edName") == "Mine" and page.is_visible("#edGallery"),
          f"page: a track of your own asks first, No keeps it: {asked}")
    ctx.close()

    # the site: index.json has a track the page hasn't (merged after the build)
    extra = dict(built[0])
    extra.update(file="zz-new-track.txt", name="A New One", by="Someone", about="Added later.", source="https://example.org/t")
    extra["text"] = built[0]["text"].replace(built[0]["name"], "A New One", 1)
    ctx = br.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2)
    served(ctx, json.dumps({"tracks": built + [extra, {"name": "Broken", "text": "Broken\n1 2 x\n"}]}).encode())
    page = ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(SITE + "simulator.html")
    wait_sim(page)
    open_gallery(page)
    page.wait_for_function(f"document.querySelectorAll('#edCards .ed-card').length === {len(built) + 1}", timeout=10000)
    check(cards(page)[-1] == "A New One" and "Broken" not in cards(page), "site: index.json's newer track is listed, a broken entry left out")
    page.evaluate("document.querySelector('header.top').style.position = 'static'")
    page.locator("#edGallery").screenshot(path=str(OUT / "gallery_phone.png"))
    print("wrote test/shots/gallery_phone.png")
    w = page.evaluate("document.documentElement.scrollWidth")
    check(w <= 390, f"site: no sideways scroll at phone width ({w} px)")
    ctx.close()

    # the site without a good index.json: the built-in list
    for what, body in (("missing", None), ("broken", b"{not json")):
        ctx = br.new_context(viewport={"width": 1200, "height": 900})
        served(ctx, body)
        page = ctx.new_page()
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(SITE + "simulator.html")
        wait_sim(page)
        open_gallery(page)
        page.wait_for_timeout(300)
        check(cards(page) == bundled, f"site: index.json {what}: the built-in list")
        ctx.close()


def main():
    from playwright.sync_api import sync_playwright
    only = "--tracks" in sys.argv
    tracks, probs = gallery.gallery()
    for m in probs:
        print("tracks/" + m)
    check(not probs, f"tracks/: {len(tracks)} tracks pass the checker")
    if not only:
        checker_tests()
    errors = []
    with sync_playwright() as p:
        br = p.chromium.launch()
        tracks_tests(br, errors, tracks)
        if not only:
            radio_tests(br, errors, tracks)
            page_tests(br, errors, tracks)
        br.close()
    for e in errors:
        print("page error:", e)
    check(not errors, "no script errors on the page")
    print("ALL OK" if not fails else f"{len(fails)} FAILED")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
