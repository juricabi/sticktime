#!/usr/bin/env python3
"""Bundle the browser emulator into single HTML files.

web/simulator.html  - complete offline page (fengari inlined), open it directly
web/artifact.html   - same page as body content, fengari from jsDelivr (for hosting)
"""
import base64
import json
import pathlib
import re

import gallery

ROOT = pathlib.Path(__file__).resolve().parents[1]
W = ROOT / "web"
SRC = W / "src"


def read(p):
    return pathlib.Path(p).read_text(encoding="utf-8")


def b64(p):
    return base64.b64encode(pathlib.Path(p).read_bytes()).decode()


def b64_text(p):
    """A text file (the SVG icon) as in the repo, with LF line ends: the same bundle from any
    checkout (git on Windows may give the working copy CRLF)"""
    return base64.b64encode(pathlib.Path(p).read_bytes().replace(b"\r\n", b"\n")).decode()


LUA_TOKEN = re.compile(r'\s+|--[^\n]*|"(?:[^"\\]|\\.)*"|-?(?:\d+\.?\d*|\.\d+)|[{},]|nil\b|[A-Za-z_]\w*|.')


def lua_table(text):
    """The first Lua table constructor in text (positional entries of strings, numbers, nil and
    tables, as the TRACKS table uses) as Python lists"""
    toks = [t for t in LUA_TOKEN.findall(text) if t.strip() and not t.startswith("--")]
    pos = 0

    def value():
        nonlocal pos
        t = toks[pos]
        pos += 1
        if t == "{":
            out = []
            while toks[pos] != "}":
                out.append(value())
                if toks[pos] == ",":
                    pos += 1
            pos += 1
            return out
        if t.startswith('"'):
            return json.loads(t)
        if t == "nil":
            return None
        try:
            return float(t) if "." in t else int(t)
        except ValueError:
            raise SystemExit(f"bundle_web.py: can't read {t!r} in the TRACKS table of src/sticktime.lua")

    assert toks[0] == "{"
    return value()


LUA_STRING = r'"(?:[^"\\]|\\.)*"'


def deco_table(src):
    """buildTrack's DECO: the built-in tracks' scenery, one string each (string literals joined by
    '..'), as the game reads it: props / rails / decals"""
    start = src.index("local DECO = {") + len("local DECO = {")
    body, depth, i = [], 1, start
    while depth:                                       # (to its closing brace, past strings)
        m = re.compile(LUA_STRING).match(src, i)
        if m:
            body.append(m.group(0))
            i = m.end()
            continue
        c = src[i]
        if c == "-" and src.startswith("--", i):
            i = src.index("\n", i)
            continue
        depth += c == "{"
        depth -= c == "}"
        body.append(c)
        i += 1
    entries = re.findall(rf"({LUA_STRING}(?:\s*\.\.\s*{LUA_STRING})*)\s*,", "".join(body[:-1]) + ",")
    return ["".join(json.loads(s) for s in re.findall(LUA_STRING, e)) for e in entries]


def scenery(s, name):
    """a scenery string (props / rails / decals) as the editor's lists, checked as the game's
    section() takes them: whole groups (4, 6, 6 numbers), known kinds"""
    parts = s.split("/")
    assert len(parts) <= 3, f"DECO of {name}: props / rails / decals"
    parts += [""] * (3 - len(parts))
    out = {}
    for key, part, m, k, km in (("props", parts[0], 4, 2, 10), ("rails", parts[1], 6, 4, 5), ("decals", parts[2], 6, 5, 6)):
        v = [float(t) if "." in t else int(t) for t in part.split()]
        assert len(v) % m == 0, f"DECO of {name}: {key} in groups of {m}"
        groups = [v[i:i + m] for i in range(0, len(v), m)]
        assert all(g[k] in range(1, km + 1) for g in groups), f"DECO of {name}: {key}' kinds 1 to {km}"
        out[key] = groups
    return out


def track_data():
    """What the track editor (web/src/editor.js) needs from the game: the built-in tracks
    (src/sticktime.lua's TRACKS, with their structures' kinds, and DECO, their scenery) as
    templates, the gate sizes and default heights, the props' heights and radii and the rails'
    heights, so the map draws what the game builds"""
    src = read(ROOT / "src/sticktime.lua")
    table = lua_table(src[src.index("local TRACKS = {") + len("local TRACKS = "):])
    deco = deco_table(src)
    assert len(deco) == len(table), f"DECO has {len(deco)} entries for {len(table)} tracks"
    tracks = []
    for t, d in zip(table, deco):
        name, seed, gates = t[0], t[1], t[2]
        boxes = t[3] if len(t) > 3 and t[3] else []
        mult = t[4] if len(t) > 4 else 1
        assert len(gates) % 5 == 0 and len(boxes) % 7 == 0, f"track {name}: gates of 5, structures of 7 numbers"
        tracks.append({"name": name, "seed": seed, "trees": round(mult * 9),
                       "gates": [gates[i:i + 5] for i in range(0, len(gates), 5)],
                       "boxes": [boxes[i:i + 7] for i in range(0, len(boxes), 7)], **scenery(d, name)})
    assert len(tracks) == 8, "the editor's templates expect the 8 built-in tracks"

    def nums(pattern):
        m = re.search(pattern, src)
        assert m, f"src/sticktime.lua: no match for {pattern}"
        return [float(v) for v in m.group(1).split(",")]
    gt, flagh = nums(r"local GT, FLAGH = ([\d.]+\s*,\s*[\d.]+)")
    # trees on a track with trees = 9, color edition (build.py's @TREES@)
    trees = int(re.search(r'"COLOR": \{.*?"TREES": "(\d+)"', read(ROOT / "build.py"), re.S).group(1))
    data = {"tracks": tracks, "GT": gt, "FLAGH": flagh, "TREES": trees,
            "GHW": nums(r"local GHW = \{([^}]*)\}"), "GHH": nums(r"local GHH = \{([^}]*)\}"),
            "GCY": nums(r"local GCY = \{([^}]*)\}"),
            "PH": nums(r"local PH = \{([^}]*)\}"), "PR": nums(r"local PR = \{([^}]*)\}"), "RH": nums(r"local RH = \{([^}]*)\}")}
    assert len(data["GHW"]) == len(data["GHH"]) == len(data["GCY"]) == 8
    assert len(data["PH"]) == len(data["PR"]) == 10 and len(data["RH"]) == 5
    return json.dumps(data, separators=(",", ":"))


def main():
    lua_color = read(ROOT / "sdcard/SCRIPTS/TOOLS/StickTime.lua")
    # StickTime BW with its test hooks (the shipped core.lua has none), so the emulator can be automated
    lua_bw = read(ROOT / "test/build/sticktime_bw_test.lua")
    # the Lite with its test hooks (inert on a radio), so the emulator can be automated
    lua_lite = read(ROOT / "test/build/sticktime_lite_test.lua")
    # on color screens the B&W loaders run color.lua, which loads the same core
    lua_bwcolor = read(ROOT / "sdcard/SCRIPTS/TOOLS/StickTimeBW/color.lua")
    lua_litecolor = read(ROOT / "sdcard/SCRIPTS/TOOLS/StickTimeLite/color.lua")
    # the Lite reads its tracks and quad classes from the SD card: StickTimeLite/t1.txt ..., q1.txt ...
    tdir = ROOT / "sdcard/SCRIPTS/TOOLS/StickTimeLite"
    tracks = {"/SCRIPTS/TOOLS/StickTimeLite/" + p.name: read(p)
              for p in sorted(list(tdir.glob("t*.txt")) + list(tdir.glob("q*.txt")))}
    assert tracks, "no StickTime Lite track files (run build.py)"
    lite_tracks = json.dumps(tracks, indent=0)
    # the icon (docs/icon.svg; its PNGs from tools/make_icons.py)
    icon_svg = "data:image/svg+xml;base64," + b64_text(ROOT / "docs/icon.svg")
    icon_png = "data:image/png;base64," + b64(ROOT / "docs/icon-32.png")
    # the track editor and the built-in tracks it starts from
    editor, tracks_json = read(SRC / "editor.js"), track_data()
    # the gallery's tracks (tracks/, tools/gallery.py); the site has them beside the page too
    shared, probs = gallery.gallery()
    assert not probs, "tracks/: " + "; ".join(probs)
    # (in a script element: no "<" for the HTML parser, no "{{" for the placeholders here)
    shared_json = json.dumps({"tracks": shared}, separators=(",", ":")).replace("<", "\\u003c").replace("{{", "{\\u007b")
    for s in (lua_color, lua_bw, lua_lite, lua_bwcolor, lua_litecolor, lite_tracks, editor, tracks_json, shared_json):
        assert "</script" not in s.lower()
    parts = {
        "STYLE": read(SRC / "style.css"),
        "BWFONTS": read(SRC / "bwfonts.js"),
        "ENGINE": read(SRC / "engine.js"),
        "APP": read(SRC / "app.js"),
        "TRACK_DATA": tracks_json,
        "GALLERY": shared_json,
        "EDITOR": editor,
        "LUA_COLOR": lua_color,
        "LUA_BW": lua_bw,
        "LUA_LITE": lua_lite,
        "LUA_BWCOLOR": lua_bwcolor,
        "LUA_LITECOLOR": lua_litecolor,
        "LITE_TRACKS": lite_tracks,
        "ROBOTO400": b64(W / "vendor/roboto-latin-400-normal.woff2"),
        "ROBOTO700": b64(W / "vendor/roboto-latin-700-normal.woff2"),
        "ICON": icon_svg,
    }
    tpl = read(SRC / "index.html")
    for k, v in parts.items():
        tpl = tpl.replace("{{" + k + "}}", v)
    cdn = '<script src="https://cdn.jsdelivr.net/npm/fengari-web@0.1.4/dist/fengari-web.js"></script>'
    inline = "<script>\n/* fengari-web 0.1.4 (MIT) - https://fengari.io */\n" + read(W / "vendor/fengari-web.js") + "\n</script>"
    # the game's SD card files beside the page (the site has them: .github/workflows/pages.yml,
    # tools/sd_manifest.py); a hosted artifact.html has not, so it can't install the game (and its
    # gallery is the one built in, without tracks/index.json)
    art = tpl.replace("{{FENGARI_TAG}}", cdn).replace("{{GAME_FILES}}", "").replace("{{GALLERY_FILES}}", "")
    (W / "artifact.html").write_text(art, encoding="utf-8")
    # the offline page is also the GitHub Pages site (.github/workflows/pages.yml): search and
    # link-preview metadata in its head
    site = "https://juricabi.github.io/sticktime/"
    desc = ("Play StickTime in your browser: a real 3D FPV quad simulator that runs on EdgeTX radios as a Lua "
            "tool. Race AI pilots, fly freestyle around a bando, chase gates. The emulator runs the same "
            "scripts as the radio, on any color or black & white screen.")
    meta = ("<title>StickTime: 3D FPV simulator for EdgeTX radios</title>\n"
            f"<meta name=\"description\" content=\"{desc}\">\n"
            f"<link rel=\"canonical\" href=\"{site}\">\n"
            "<meta property=\"og:type\" content=\"website\">\n"
            "<meta property=\"og:title\" content=\"StickTime: 3D FPV simulator for EdgeTX radios\">\n"
            f"<meta property=\"og:description\" content=\"{desc}\">\n"
            f"<meta property=\"og:url\" content=\"{site}\">\n"
            f"<meta property=\"og:image\" content=\"{site}social-preview.png\">\n"
            "<meta name=\"twitter:card\" content=\"summary_large_image\">\n"
            f"<link rel=\"icon\" href=\"{icon_png}\" sizes=\"32x32\">\n"
            f"<link rel=\"icon\" href=\"{icon_svg}\" type=\"image/svg+xml\">\n"
            # docs/icon-180.png on the site (.github/workflows/pages.yml)
            "<link rel=\"apple-touch-icon\" href=\"apple-touch-icon.png\">\n")
    # the head has the title: the template's own (artifact.html's) would be a second one
    body = re.sub(r"<title>.*?</title>\n?", "", tpl, count=1)
    full = ("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n"
            + meta + "</head>\n<body>\n" + body.replace("{{FENGARI_TAG}}", inline).replace("{{GAME_FILES}}", "sdcard/")
            .replace("{{GALLERY_FILES}}", "tracks/") + "\n</body>\n</html>\n")
    (W / "simulator.html").write_text(full, encoding="utf-8")
    for f in ("artifact.html", "simulator.html"):
        print(f, (W / f).stat().st_size // 1024, "KB")


if __name__ == "__main__":
    main()
