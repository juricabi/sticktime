#!/usr/bin/env python3
"""Build the color and B&W EdgeTX scripts from the single source in src/.

Lines between `--#if COLOR` / `--#if BW` and `--#endif` are kept only in the
matching variant. @PLACEHOLDERS@ are substituted per variant.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "src" / "fpvsim.lua"
OUT = ROOT / "sdcard" / "SCRIPTS" / "TOOLS"

VARIANTS = {
    "COLOR": {
        "file": "FPVSim.lua",
        "TOOLNAME": "FPV Sim",
        "TITLE": "FPV Sim",
        "VARIANT": "Color version - every EdgeTX color radio (480x272, 480x320, 320x480, 320x240, 800x480)",
        "TILT": "25",
        "FOV": "110",
        "TREES": "18",
        "DATAFILE": "FPVSim.dat",
        "DEG": "°",
        "REFW": "480",
    },
    "BW": {
        "file": "FPVSimBW.lua",
        "TOOLNAME": "FPV Sim BW",
        "TITLE": "FPV Sim BW",
        "VARIANT": "Black & white version - EdgeTX 128x64 and 212x64 radios",
        "TILT": "20",
        "FOV": "100",
        "TREES": "8",
        "DATAFILE": "FPVSimBW.dat",
        "DEG": "",
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
    text = "\n".join(out) + "\n"
    for k, v in cfg.items():
        text = text.replace("@" + k + "@", v)
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


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for variant, cfg in VARIANTS.items():
        text = build(variant, cfg, strip=False)
        path = OUT / cfg["file"]
        path.write_text(text, encoding="utf-8")
        print(f"{path.relative_to(ROOT)}: {len(text.encode())} bytes, {text.count(chr(10))} lines")


if __name__ == "__main__":
    main()
