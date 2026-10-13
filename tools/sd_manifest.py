#!/usr/bin/env python3
"""The game's SD card files for the hosted emulator, which can install them on a radio.

    python3 tools/sd_manifest.py OUT       (the Pages workflow: OUT = _site/sdcard)

copies sdcard/SCRIPTS/TOOLS/ (what build.py writes) to OUT/SCRIPTS/TOOLS/ and writes
OUT/manifest.json: the game's version, every file with its size and SHA-256 and the edition it
belongs to (color: StickTime.lua; bw: StickTimeBW.lua and its folder; lite: StickTimeLite.lua and
its folder; shared: the StickTimeTracks and StickTimeGhosts folders' READMEs), and the files in
the edition folders that are the player's own (kept when a folder is made to match the release).
Text files go out with LF line ends, as in the repo and the release zip, whatever the checkout
has; binary files (game.luac) byte for byte.
"""
import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOLS = ROOT / "sdcard" / "SCRIPTS" / "TOOLS"
EDITIONS = {
    "color": {"label": "Color", "loader": "StickTime.lua", "folder": None},
    "bw": {"label": "B&W", "loader": "StickTimeBW.lua", "folder": "StickTimeBW"},
    "lite": {"label": "Lite", "loader": "StickTimeLite.lua", "folder": "StickTimeLite"},
}
# the player's own files inside the edition folders: the Lite's save
KEEP = ["StickTimeLite/data.txt"]


def edition(path):
    for name, e in EDITIONS.items():
        if path == e["loader"] or (e["folder"] and path.startswith(e["folder"] + "/")):
            return name
    return "shared"


def files():
    """{path under SCRIPTS/TOOLS: bytes as published}"""
    out = {}
    for p in sorted(TOOLS.rglob("*")):
        if not p.is_file():
            continue
        data = p.read_bytes()
        if b"\0" not in data:
            data = data.replace(b"\r\n", b"\n")
        out[p.relative_to(TOOLS).as_posix()] = data
    return out


def manifest(fs=None):
    fs = fs or files()
    head = fs["StickTime.lua"][:600].decode("utf-8", "replace")
    version = re.search(r"StickTime v(\d+(?:\.\d+)+)", head).group(1)
    for name, e in EDITIONS.items():
        assert e["loader"] in fs, f"{e['loader']} missing: run build.py"
    return {
        "version": version,
        "base": "SCRIPTS/TOOLS",
        "editions": EDITIONS,
        "keep": KEEP,
        "files": [{"path": k, "size": len(v), "sha256": hashlib.sha256(v).hexdigest(), "edition": edition(k)}
                  for k, v in fs.items()],
    }


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = pathlib.Path(sys.argv[1])
    fs = files()
    for k, v in fs.items():
        p = out / "SCRIPTS" / "TOOLS" / k
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(v)
    m = manifest(fs)
    (out / "manifest.json").write_text(json.dumps(m, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"{out}: StickTime {m['version']}, {len(fs)} files, {sum(len(v) for v in fs.values()) // 1024} KB")


if __name__ == "__main__":
    main()
