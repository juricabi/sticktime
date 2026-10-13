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

What is published is checked first (check): only the game's own files (the loaders, the B&W and
Lite folders' .lua/.luac/.txt, the two READMEs), none of them a name the player's own files have
(c1.txt..., *.dat, data.txt: the page never writes those), and the three loaders of one version.
The page checks the manifest the same way before it writes anything.
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
# the names of the player's own files anywhere (tracks and ghosts c1.txt..., saves *.dat, data.txt)
KEEP_NAME = re.compile(r"(^|/)(c\d+\.txt|[^/]*\.dat|data\.txt)$", re.I)
# what may be published: the loaders, the game's files in the edition folders, the READMEs
SHARED = ["StickTimeTracks/README.txt", "StickTimeGhosts/README.txt"]
GAME_NAME = re.compile(r"[A-Za-z0-9_-]+\.(lua|luac|txt)")


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


def version(fs, loader):
    """the version in a loader's header (StickTime v1.7.0, StickTime BW v1.7.0...)"""
    m = re.search(r"StickTime(?: BW| Lite)? v(\d+(?:\.\d+)+)", fs[loader][:600].decode("utf-8", "replace"))
    if not m:
        raise ValueError(f"{loader}: no version in its header")
    return m.group(1)


def check(fs):
    """raises ValueError for anything the page mustn't write: the version when all is well"""
    for name, e in EDITIONS.items():
        if e["loader"] not in fs:
            raise ValueError(f"{e['loader']} missing: run build.py")
    for path in fs:
        if KEEP_NAME.search(path) or path in KEEP:
            raise ValueError(f"{path}: a name the player's own files have (the page never writes those)")
        name = edition(path)
        folder = EDITIONS[name]["folder"] if name != "shared" else None
        ok = (path in SHARED if name == "shared" else
              path == EDITIONS[name]["loader"] or (folder and GAME_NAME.fullmatch(path[len(folder) + 1:])))
        if not ok:
            raise ValueError(f"{path}: not one of the game's files (loaders, {', '.join(e['folder'] for e in EDITIONS.values() if e['folder'])}, the READMEs)")
    v = {e["loader"]: version(fs, e["loader"]) for e in EDITIONS.values()}
    if len(set(v.values())) != 1:
        raise ValueError("the loaders' versions differ: " + ", ".join(f"{k} {x}" for k, x in v.items()))
    return v["StickTime.lua"]


def manifest(fs=None):
    fs = fs or files()
    return {
        "version": check(fs),
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
    try:
        m = manifest(fs)
    except ValueError as e:
        sys.exit(f"sd_manifest: {e}")
    for k, v in fs.items():
        p = out / "SCRIPTS" / "TOOLS" / k
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(v)
    (out / "manifest.json").write_text(json.dumps(m, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"{out}: StickTime {m['version']}, {len(fs)} files, {sum(len(v) for v in fs.values()) // 1024} KB")


if __name__ == "__main__":
    main()
