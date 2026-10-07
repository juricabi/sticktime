#!/usr/bin/env python3
"""Build the color and B&W EdgeTX scripts from the single source in src/.

Lines between `--#if COLOR` / `--#if BW` and `--#endif` are kept only in the
matching variant. @PLACEHOLDERS@ are substituted per variant.

Color radios get one file, StickTime.lua. B&W radios get a small loader,
StickTimeBW.lua, plus the game in StickTimeBW/core.lua and, when the 32-bit
EdgeTX-config Lua is available (tools/build_etxlua.sh), a precompiled
StickTimeBW/core.luac for EdgeTX 2.11+ so the radio never has to compile it.
StickTime Lite (StickTimeLite.lua + StickTimeLite/) has its own source.
"""
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "src" / "sticktime.lua"
OUT = ROOT / "sdcard" / "SCRIPTS" / "TOOLS"

VARIANTS = {
    "COLOR": {
        "file": "StickTime.lua",
        "INSTALL": "copy this file to /SCRIPTS/TOOLS/ on the radio SD card and",
        "TOOLNAME": "StickTime",
        "TITLE": "StickTime",
        "VARIANT": "Color version - every EdgeTX color radio (480x272, 480x320, 320x480, 320x240, 800x480)",
        "TILT": "25",
        "FOV": "110",
        "TREES": "18",
        "DATAFILE": "StickTime.dat",
        "OLDDATA": "FPVSim.dat",            # the save of FPV Sim (the old name): read when there is no new one
        "DEG": "°",
        "DPS": "°/s",
        "LATK": "0.011",
        "REFW": "480",
    },
    "BW": {
        "file": "StickTimeBW/core.lua",
        "loader": "StickTimeBW.lua",
        "INSTALL": "copy StickTimeBW.lua and the StickTimeBW folder to /SCRIPTS/TOOLS/ and",
        "TOOLNAME": "StickTime BW",
        "TITLE": "StickTime BW",
        "VARIANT": "Black & white version - 128x64 and 212x64 radios with an STM32F4 (TX12 MkII, Zorro, Boxer,\n  Pocket, MT12, GX12, X9D+ 2019, X9E, T14, T20 ...)",
        "TILT": "20",
        "FOV": "100",
        "TREES": "8",
        "DATAFILE": "StickTimeBW.dat",
        "OLDDATA": "FPVSimBW.dat",
        "DIR": "StickTimeBW",
        "DEG": "",
        "DPS": "",
        "LATK": "0.003",
        "REFW": "128",
    },
    # the small edition for B&W radios with little memory (STM32F2): its own source
    "LITE": {
        "src": "sticktime_lite.lua",
        "file": "StickTimeLite/core.lua",
        "loader": "StickTimeLite.lua",
        "test": "test/build/sticktime_lite_test.lua",   # with the STICKTIME_TEST hooks (--#if TEST)
        "strip": True,
        "TOOLNAME": "StickTime Lite",
        "TITLE": "StickTime Lite",
        "DIR": "StickTimeLite",
    },
}


def build(variant: str, cfg: dict, strip: bool) -> str:
    out = []
    keep = True
    src = ROOT / "src" / cfg.get("src", "sticktime.lua")
    for n, line in enumerate(src.read_text(encoding="utf-8").splitlines(), 1):
        s = line.strip()
        m = re.match(r"^--#if\s+(\w+)$", s)
        if m:
            keep = m.group(1) == variant
            continue
        if s == "--#endif":
            keep = True
            continue
        if keep:
            out.append(line)
    text = fold(placeholders("\n".join(out) + "\n", cfg))
    left = re.findall(r"@[A-Z]+@", text)
    if left:
        sys.exit(f"unreplaced placeholders in {variant}: {sorted(set(left))}")
    if strip:
        # drop comment-only lines and indentation (smaller file for B&W radios)
        lines = []
        for i, line in enumerate(text.splitlines()):
            s = line.strip()
            if i > 0 and (not s or (s.startswith("--") and not s.startswith("--[["))):
                continue
            lines.append(s if i > 0 else line)
        text = "\n".join(lines) + "\n"
    return text


def fold(text: str) -> str:
    """Lines marked --#fold declare constants (local A, B = 1, 2): drop the line and write the
    values where the names are used, outside strings. On radios with little memory every local
    that functions use costs an upvalue per function; a literal costs nothing extra."""
    names, out = {}, []
    for line in text.splitlines():
        m = re.match(r"^\s*local\s+([\w\s,]+?)\s*=\s*([-\d.,\s]+?)\s*--#fold", line)
        if m:
            ks = [k.strip() for k in m.group(1).split(",")]
            vs = [v.strip() for v in m.group(2).split(",")]
            assert len(ks) == len(vs), line
            names.update(zip(ks, vs))
            continue
        out.append(line)
    if not names:
        return text
    pat = re.compile(r"\b(" + "|".join(sorted(names, key=len, reverse=True)) + r")\b")
    res = []
    for line in out:
        parts = re.split(r'("(?:[^"\\]|\\.)*")', line)
        for i in range(0, len(parts), 2):
            parts[i] = pat.sub(lambda mm: names[mm.group(1)], parts[i])
        res.append("".join(parts))
    return "\n".join(res) + "\n"


def placeholders(text: str, cfg: dict) -> str:
    for k, v in cfg.items():
        if isinstance(v, str):
            text = text.replace("@" + k + "@", v)
    return text


def precompile(src: pathlib.Path):
    """Lua 5.3 bytecode in EdgeTX's format (32-bit ints and floats), stripped. Made by EdgeTX's
    own Lua (tools/build_etxhost.sh) when it is built, else by the 32-bit EdgeTX-config Lua."""
    out = src.with_suffix(".luac")
    host, m32 = ROOT / ".tools" / "etxhost", ROOT / ".tools" / "etxlua53_m32"
    if host.exists():
        code = ROOT / ".tools" / "dump.lua"
        code.write_text("local f = assert(etx.loadfile(arg[1])) etx.writefile(arg[2], string.dump(f, true))\n")
        subprocess.run([str(host), str(code), str(src), str(out)], check=True, env={**os.environ, "ETX_MODEL": "host"})
    elif m32.exists():
        code = f"local f = assert(loadfile({str(src)!r})) local o = assert(io.open({str(out)!r}, 'wb')) o:write(string.dump(f, true)) o:close()"
        subprocess.run([str(m32), "-e", code], check=True)
    else:
        print("  (no .tools/etxhost or .tools/etxlua53_m32: skipping the precompiled .luac)")
        return
    # same time or newer than the source: EdgeTX then loads the binary ("bt" mode)
    st = src.stat()
    os.utime(out, (st.st_atime, st.st_mtime + 2))
    print(f"{out.relative_to(ROOT)}: {out.stat().st_size} bytes (EdgeTX 2.11+ bytecode)")


def lite_tracks(cfg: dict):
    """src/sticktime_lite_tracks.txt -> the names for the Lite's script, and StickTimeLite/t<n>.txt files
    (seed, trees, gates, "/", structures) that the Lite reads when a track is picked."""
    names = []
    for line in (ROOT / "src" / "sticktime_lite_tracks.txt").read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        name, seed, trees, gates, boxes = [f.strip() for f in line.split("|")]
        names.append(name)
        data = " ".join(f"{seed} {trees} {gates}".split())
        if boxes:
            data += " / " + " ".join(boxes.split())
        # the Lite reads at most 700 bytes of a track file (io.read(f, 700): one buffer that size)
        assert len(data) < 700, f"Lite track {name}: {len(data)} bytes, the Lite reads at most 699"
        (OUT / "StickTimeLite" / f"t{len(names)}.txt").write_text(data + "\n", encoding="utf-8")
    cfg["TRACKNAMES"] = ", ".join(f'"{n}"' for n in names)
    cfg["NTRACKS"] = str(len(names))
    print(f"sdcard/SCRIPTS/TOOLS/StickTimeLite/t1-{len(names)}.txt: {len(names)} tracks")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "StickTimeLite").mkdir(exist_ok=True)
    lite_tracks(VARIANTS["LITE"])
    for variant, cfg in VARIANTS.items():
        text = build(variant, cfg, strip=cfg.get("strip", False))
        path = OUT / cfg["file"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        print(f"{path.relative_to(ROOT)}: {len(text.encode())} bytes, {text.count(chr(10))} lines")
        if "test" in cfg:
            tp = ROOT / cfg["test"]
            tp.parent.mkdir(parents=True, exist_ok=True)
            tp.write_text(build("TEST", cfg, strip=True), encoding="utf-8")
            precompile(tp)
        if "loader" in cfg:
            lt = placeholders((ROOT / "src" / "bwloader.lua").read_text(encoding="utf-8"), cfg)
            lp = OUT / cfg["loader"]
            lp.write_text(lt, encoding="utf-8")
            print(f"{lp.relative_to(ROOT)}: {len(lt.encode())} bytes (loader)")
            # what the loader shows on a color radio instead of the game
            ct = placeholders((ROOT / "src" / "bwcolor.lua").read_text(encoding="utf-8"), cfg)
            (OUT / cfg["DIR"] / "color.lua").write_text(ct, encoding="utf-8")
            precompile(path)


if __name__ == "__main__":
    main()
