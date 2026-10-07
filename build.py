#!/usr/bin/env python3
"""Build the color and B&W EdgeTX scripts from the single source in src/.

Lines between `--#if COLOR` / `--#if BW` and `--#endif` are kept only in the
matching variant. @PLACEHOLDERS@ are substituted per variant.

Color radios get one file, FPVSim.lua. B&W radios get a small loader,
FPVSimBW.lua, plus the game in FPVSimBW/core.lua and, when the 32-bit
EdgeTX-config Lua is available (tools/build_etxlua.sh), a precompiled
FPVSimBW/core.luac for EdgeTX 2.11+ so the radio never has to compile it.
"""
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "src" / "fpvsim.lua"
OUT = ROOT / "sdcard" / "SCRIPTS" / "TOOLS"

VARIANTS = {
    "COLOR": {
        "file": "FPVSim.lua",
        "INSTALL": "copy this file to /SCRIPTS/TOOLS/ on the radio SD card and",
        "TOOLNAME": "FPV Sim",
        "TITLE": "FPV Sim",
        "VARIANT": "Color version - every EdgeTX color radio (480x272, 480x320, 320x480, 320x240, 800x480)",
        "TILT": "25",
        "FOV": "110",
        "TREES": "18",
        "DATAFILE": "FPVSim.dat",
        "DEG": "°",
        "DPS": "°/s",
        "LAT": "0.055",
        "REFW": "480",
    },
    "BW": {
        "file": "FPVSimBW/core.lua",
        "loader": "FPVSimBW.lua",
        "INSTALL": "copy FPVSimBW.lua and the FPVSimBW folder to /SCRIPTS/TOOLS/ and",
        "TOOLNAME": "FPV Sim BW",
        "TITLE": "FPV Sim BW",
        "VARIANT": "Black & white version - 128x64 and 212x64 radios with an STM32F4 (TX12 MkII, Zorro, Boxer,\n  Pocket, MT12, GX12, X9D+ 2019, X9E, T14, T20 ...)",
        "TILT": "20",
        "FOV": "100",
        "TREES": "8",
        "DATAFILE": "FPVSimBW.dat",
        "DEG": "",
        "DPS": "",
        "LAT": "0.015",
        "REFW": "128",
    },
}


def build(variant: str, cfg: dict, strip: bool) -> str:
    out = []
    keep = True
    for n, line in enumerate(SRC.read_text(encoding="utf-8").splitlines(), 1):
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
    text = placeholders("\n".join(out) + "\n", cfg)
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


def placeholders(text: str, cfg: dict) -> str:
    for k, v in cfg.items():
        if isinstance(v, str):
            text = text.replace("@" + k + "@", v)
    return text


def precompile(src: pathlib.Path):
    """Lua 5.3 bytecode in EdgeTX's format (32-bit ints and floats), stripped."""
    lua = ROOT / ".tools" / "etxlua53_m32"
    if not lua.exists():
        print("  (no .tools/etxlua53_m32: skipping the precompiled .luac)")
        return
    out = src.with_suffix(".luac")
    code = f"local f = assert(loadfile({str(src)!r})) local o = assert(io.open({str(out)!r}, 'wb')) o:write(string.dump(f, true)) o:close()"
    subprocess.run([str(lua), "-e", code], check=True)
    # same time or newer than the source: EdgeTX then loads the binary ("bt" mode)
    st = src.stat()
    os.utime(out, (st.st_atime, st.st_mtime + 2))
    print(f"{out.relative_to(ROOT)}: {out.stat().st_size} bytes (EdgeTX 2.11+ bytecode)")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for variant, cfg in VARIANTS.items():
        text = build(variant, cfg, strip=False)
        path = OUT / cfg["file"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        print(f"{path.relative_to(ROOT)}: {len(text.encode())} bytes, {text.count(chr(10))} lines")
        if "loader" in cfg:
            lt = placeholders((ROOT / "src" / "bwloader.lua").read_text(encoding="utf-8"), cfg)
            lp = OUT / cfg["loader"]
            lp.write_text(lt, encoding="utf-8")
            print(f"{lp.relative_to(ROOT)}: {len(lt.encode())} bytes (loader)")
            precompile(path)


if __name__ == "__main__":
    main()
