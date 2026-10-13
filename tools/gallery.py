#!/usr/bin/env python3
"""The track gallery: tracks/ in the repo, one track per pair of files,

    tracks/<name>.txt    the track, exactly as the emulator's track editor saves it (c1.txt ...)
    tracks/<name>.json   who made it and what it is: {"by": "...", "about": "...", "source": "https://..."}

checked here as the editor and the game read them. The emulator shows them under Tracks > Gallery:
web/simulator.html has them built in (tools/bundle_web.py), and the hosted site also publishes
tracks/index.json (.github/workflows/pages.yml), so a track merged into the repo shows up there
without a new build of the page.

    python tools/gallery.py            check every track (exit status 1 on a problem)
    python tools/gallery.py <dir>      check, then write <dir>/index.json"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
DIR = ROOT / "tracks"
FILE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
# a number as the editor writes it: plain decimal, at most 2 places, no trailing zeros
NUM = re.compile(r"^-?(0|[1-9]\d*)(\.\d?[1-9])?$")
KEYS = {"by": 60, "about": 300, "source": 300}


def fnv1a(s):
    h = 0x811C9DC5
    for c in s.encode():
        h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF
    return h


def track_problems(text):
    """what is wrong with a track file, as the editor's Save file writes it: the name (16 plain
    characters), then 1 <id> <seed> <trees> <gates: x z type yaw height> [/ <structures: x z half-x
    half-z bottom top kind>], the id the FNV-1a of the numbers after it, at most 999 bytes"""
    p = []
    if len(text.encode()) > 999:
        p.append(f"{len(text.encode())} bytes: 999 at most")
    lines = text.split("\n")
    if "\r" in text or len(lines) != 3 or lines[2] != "":
        return p + ["a name line and a numbers line, as the editor's Save file writes them"]
    name, line = lines[0], lines[1]
    if not (1 <= len(name) <= 16) or name != name.strip() or re.search(r"[^\x20-\x7e]|/", name):
        p.append(f"the name {name!r}: 1 to 16 plain letters, digits and punctuation, without '/'")
    tok = line.split(" ")
    if len(tok) < 4 or tok[0] != "1" or not tok[1].isdigit():
        return p + ["the numbers line starts with the format (1), the id, the tree seed and the trees"]
    nums = line[len(tok[0]) + len(tok[1]) + 2:]
    if int(tok[1]) != fnv1a(nums) % 999999 + 1:
        p.append(f"the id {tok[1]} isn't the one the editor gives these numbers ({fnv1a(nums) % 999999 + 1}): "
                 "save the track from the editor again")
    g, sep, b = nums.partition(" / ")
    gt, bt = g.split(" "), (b.split(" ") if sep else [])
    bad = [t for t in gt + bt if not NUM.match(t)]
    if bad:
        return p + [f"{bad[0]!r} is not a number as the editor writes it (plain, at most 2 decimals)"]
    v = [float(t) for t in gt]
    if not (1 <= v[0] <= 99 and v[0] == int(v[0])) or not (0 <= v[1] <= 30 and v[1] == int(v[1])):
        p.append(f"tree seed {gt[0]} (1 to 99) and trees {gt[1]} (0 to 30)")
    G, B = v[2:], [float(t) for t in bt]
    if len(G) % 5 or len(B) % 7:
        return p + ["gates are 5 numbers each, structures 7"]
    ng, nb = len(G) // 5, len(B) // 7
    if not 2 <= ng <= 24:
        p.append(f"{ng} gates: 2 to 24")
    if nb > 16:
        p.append(f"{nb} structures: 16 at most")
    for i in range(ng):
        x, z, k, yaw, h = G[i * 5:i * 5 + 5]
        if not (abs(x) <= 999 and abs(z) <= 999 and k in range(1, 9) and yaw in range(360) and 0 <= h <= 100):
            p.append(f"gate {i + 1}: x and z within 999 m, type 1 to 8, yaw 0 to 359, height 0 to 100")
        if i == 0 and k == 3:
            p.append("gate 1 can't be a dive gate")
    for i in range(nb):
        x, z, hx, hz, y0, y1, k = B[i * 7:i * 7 + 7]
        if not (abs(x) <= 999 and abs(z) <= 999 and 0.05 <= hx <= 200 and 0.05 <= hz <= 200 and 0 <= y0 < y1 <= 300 and k in (1, 2, 3)):
            p.append(f"structure {i + 1}: within 999 m, half sizes 0.05 to 200, bottom below top, kind 1 to 3")
    return p


def info_problems(info):
    if not isinstance(info, dict):
        return ["the .json holds one object: {\"by\": ..., \"about\": ..., \"source\": ...}"]
    p = [f"{k!r}: the keys are by, about and source" for k in info if k not in KEYS]
    for k, n in KEYS.items():
        v = info.get(k)
        if v is None and k == "by":
            p.append("'by' says who made it")
        elif v is not None and (not isinstance(v, str) or not v.strip() or len(v) > n or re.search(r"[\x00-\x1f]", v)):
            p.append(f"{k!r}: one line of text, {n} characters at most")
    s = info.get("source")
    if isinstance(s, str) and not re.match(r"^https://[^\s\"'<>]+$", s):
        p.append("'source' is an https:// link")
    return p


def gallery(d=DIR):
    """(tracks, problems): the tracks in file order, each {file, name, by, about, source, text}"""
    tracks, probs = [], []
    files = sorted(d.glob("*")) if d.is_dir() else []
    for f in files:
        if f.name.lower() == "readme.md":
            continue
        if f.suffix not in (".txt", ".json"):
            probs.append(f"{f.name}: the gallery takes <name>.txt and <name>.json")
        elif not FILE.match(f.stem) or len(f.stem) > 40:
            probs.append(f"{f.name}: a name of lowercase letters, digits and dashes (40 at most), like my-track.txt")
        elif not f.with_suffix(".json" if f.suffix == ".txt" else ".txt").exists():
            probs.append(f"{f.name}: no {f.stem}{'.json' if f.suffix == '.txt' else '.txt'} beside it")
    for f in files:
        if f.suffix != ".txt" or not FILE.match(f.stem) or not f.with_suffix(".json").exists():
            continue
        try:
            # (a checkout on Windows may have CR LF line ends: the repo has LF, as Save file writes)
            text = f.read_bytes().replace(b"\r\n", b"\n").decode("utf-8")
        except UnicodeDecodeError:
            probs.append(f"{f.name}: not plain text")
            continue
        try:
            info = json.loads(f.with_suffix(".json").read_text(encoding="utf-8"))
        except (UnicodeDecodeError, ValueError) as e:
            probs.append(f"{f.stem}.json: not JSON ({e})")
            continue
        p = track_problems(text) + info_problems(info)
        probs += [f"{f.name}: {m}" for m in p]
        if not p:
            t = {"file": f.name, "name": text.split("\n")[0], "by": info["by"].strip()}
            for k in ("about", "source"):
                if info.get(k):
                    t[k] = info[k].strip()
            t["text"] = text
            tracks.append(t)
    seen = {}
    for t in tracks:
        other = seen.setdefault(t["name"].lower(), t["file"])
        if other != t["file"]:
            probs.append(f"{t['file']}: {other} has the name {t['name']!r} too (the game's track menu shows the names)")
        nums = t["text"].split("\n")[1].split(" ", 2)[2]
        same = next((u["file"] for u in tracks if u is not t and u["text"].split("\n")[1].split(" ", 2)[2] == nums), None)
        if same and same < t["file"]:
            probs.append(f"{t['file']}: the same track as {same}")
    return tracks, probs


def index(tracks):
    return json.dumps({"tracks": tracks}, indent=1, ensure_ascii=False) + "\n"


def main():
    tracks, probs = gallery()
    for m in probs:
        print("tracks/" + m)
    if probs:
        sys.exit(1)
    if len(sys.argv) > 1:
        out = pathlib.Path(sys.argv[1])
        out.mkdir(parents=True, exist_ok=True)
        (out / "index.json").write_text(index(tracks), encoding="utf-8", newline="\n")
        print(f"wrote {out / 'index.json'}: {len(tracks)} tracks")
    else:
        print(f"tracks/: {len(tracks)} tracks, all fine")


if __name__ == "__main__":
    main()
