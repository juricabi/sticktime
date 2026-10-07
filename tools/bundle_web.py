#!/usr/bin/env python3
"""Bundle the browser emulator into single HTML files.

web/simulator.html  - complete offline page (fengari inlined), open it directly
web/artifact.html   - same page as body content, fengari from jsDelivr (for hosting)
"""
import base64
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
W = ROOT / "web"
SRC = W / "src"


def read(p):
    return pathlib.Path(p).read_text(encoding="utf-8")


def b64(p):
    return base64.b64encode(pathlib.Path(p).read_bytes()).decode()


def main():
    lua_color = read(ROOT / "sdcard/SCRIPTS/TOOLS/StickTime.lua")
    lua_bw = read(ROOT / "sdcard/SCRIPTS/TOOLS/StickTimeBW/core.lua")
    # the Lite with its test hooks (inert on a radio), so the emulator can be automated
    lua_lite = read(ROOT / "test/build/sticktime_lite_test.lua")
    # the Lite reads its tracks from the SD card: /SCRIPTS/TOOLS/StickTimeLite/t1.txt ...
    tdir = ROOT / "sdcard/SCRIPTS/TOOLS/StickTimeLite"
    tracks = {"/SCRIPTS/TOOLS/StickTimeLite/" + p.name: read(p) for p in sorted(tdir.glob("t*.txt"))}
    assert tracks, "no StickTime Lite track files (run build.py)"
    lite_tracks = json.dumps(tracks, indent=0)
    for s in (lua_color, lua_bw, lua_lite, lite_tracks):
        assert "</script" not in s.lower()
    parts = {
        "STYLE": read(SRC / "style.css"),
        "BWFONTS": read(SRC / "bwfonts.js"),
        "ENGINE": read(SRC / "engine.js"),
        "APP": read(SRC / "app.js"),
        "LUA_COLOR": lua_color,
        "LUA_BW": lua_bw,
        "LUA_LITE": lua_lite,
        "LITE_TRACKS": lite_tracks,
        "ROBOTO400": b64(W / "vendor/roboto-latin-400-normal.woff2"),
        "ROBOTO700": b64(W / "vendor/roboto-latin-700-normal.woff2"),
    }
    tpl = read(SRC / "index.html")
    for k, v in parts.items():
        tpl = tpl.replace("{{" + k + "}}", v)
    cdn = '<script src="https://cdn.jsdelivr.net/npm/fengari-web@0.1.4/dist/fengari-web.js"></script>'
    inline = "<script>\n/* fengari-web 0.1.4 (MIT) - https://fengari.io */\n" + read(W / "vendor/fengari-web.js") + "\n</script>"
    art = tpl.replace("{{FENGARI_TAG}}", cdn)
    (W / "artifact.html").write_text(art, encoding="utf-8")
    full = ("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n"
            "</head>\n<body>\n" + tpl.replace("{{FENGARI_TAG}}", inline) + "\n</body>\n</html>\n")
    (W / "simulator.html").write_text(full, encoding="utf-8")
    for f in ("artifact.html", "simulator.html"):
        print(f, (W / f).stat().st_size // 1024, "KB")


if __name__ == "__main__":
    main()
