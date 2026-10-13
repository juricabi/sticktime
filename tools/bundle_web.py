#!/usr/bin/env python3
"""Bundle the browser emulator into single HTML files.

web/simulator.html  - complete offline page (fengari inlined), open it directly
web/artifact.html   - same page as body content, fengari from jsDelivr (for hosting)
"""
import base64
import json
import pathlib
import re

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


def main():
    lua_color = read(ROOT / "sdcard/SCRIPTS/TOOLS/StickTime.lua")
    lua_bw = read(ROOT / "sdcard/SCRIPTS/TOOLS/StickTimeBW/core.lua")
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
    for s in (lua_color, lua_bw, lua_lite, lua_bwcolor, lua_litecolor, lite_tracks):
        assert "</script" not in s.lower()
    parts = {
        "STYLE": read(SRC / "style.css"),
        "BWFONTS": read(SRC / "bwfonts.js"),
        "ENGINE": read(SRC / "engine.js"),
        "APP": read(SRC / "app.js"),
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
    art = tpl.replace("{{FENGARI_TAG}}", cdn)
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
            + meta + "</head>\n<body>\n" + body.replace("{{FENGARI_TAG}}", inline) + "\n</body>\n</html>\n")
    (W / "simulator.html").write_text(full, encoding="utf-8")
    for f in ("artifact.html", "simulator.html"):
        print(f, (W / f).stat().st_size // 1024, "KB")


if __name__ == "__main__":
    main()
