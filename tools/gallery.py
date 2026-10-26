#!/usr/bin/env python3
"""The track gallery: tracks/ in the repo, one track per pair of files,

    tracks/<name>.txt    the track, exactly as the emulator's track editor saves it (c1.txt ...)
    tracks/<name>.json   who made it and what it is: {"by": "...", "about": "...", "source": "https://..."}

checked here as the editor and the game read them. The emulator shows them under Tracks > Gallery:
web/simulator.html has them built in (tools/bundle_web.py), and the hosted site also publishes
tracks/index.json (.github/workflows/pages.yml), so a track merged into the repo shows up there
without a new build of the page.

    python tools/gallery.py            check every track (exit status 1 on a problem)
    python tools/gallery.py <dir>      check, then write <dir>/index.json (<dir>: the folder to write
                                       it to, as the site's build does; not tracks/ itself)"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
DIR = ROOT / "tracks"
FILE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
# names Windows can't have as a file (git there can't check the repo out with one)
WIN = re.compile(r"^(con|prn|aux|nul|com[0-9]|lpt[0-9])$")
# a number as the editor writes it: plain decimal, at most 2 places, no trailing zeros, never -0
NUM = re.compile(r"^(0|-?[1-9][0-9]*(\.[0-9]?[1-9])?|-?0\.[0-9]?[1-9])$")
KEYS = {"by": 60, "about": 300, "source": 300}
# the game's own tracks, and the names the editor gives a new track (Blank, a copy of one of them):
# the editor takes a slot's track with a gallery track's name for another version of it
BUILTIN = ("Meadow", "Figure 8", "Dive Tower", "Slalom", "Hoop Forest", "Grand Prix", "Bando", "Pro Track")
TAKEN = {n.lower() for n in BUILTIN + ("My Track",) + tuple(("My " + n)[:16] for n in BUILTIN)}


def fnv1a(s):
    h = 0x811C9DC5
    for c in s.encode():
        h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF
    return h


# format 1, for every edition: gates, structures, bytes at most; format 2, a bigger track, for the
# color edition only (StickTime BW and earlier versions list format 1 only): the editor writes it
# only for a track that doesn't fit format 1. Formats 3 and 4 (StickTime 1.10.0 on) are 1 and 2 with
# the scenery (props, rails, decals; structure kinds 4 to 9 too): gates, structures, props, rails,
# decals, bytes at most; the editor writes them only for a track with scenery, 4 when it doesn't fit 3
F1 = (24, 16, 999)
F2 = (48, 64, 5999)
F3 = (24, 16, 32, 12, 8, 1599)
F4 = (48, 64, 128, 32, 32, 9999)
MOST = {"1": F1[2], "2": F2[2], "3": F3[5], "4": F4[5]}


def track_problems(text):
    """what is wrong with a track file, as the editor's Save file writes it: the name (16 plain
    characters), then the format <id> <seed> <trees> <gates: x z type yaw height> [/ <structures: x z
    half-x half-z bottom top kind>], and in formats 3 and 4 always four '/' and then <props: x z kind
    height> / <rails: x1 z1 x2 z2 kind height> / <decals: x z half-length half-width yaw kind>; the
    id the FNV-1a of the numbers after it; the smallest format the track fits (1 or 2 without
    scenery, 3 or 4 with), at most 999, 5999, 1599 or 9999 bytes"""
    p = []
    fmt = text.split("\n")[1][:1] if len(text.split("\n")) > 1 else ""
    most = MOST.get(fmt, F1[2])
    if len(text.encode()) > most:
        p.append(f"{len(text.encode())} bytes: {most} at most")
    lines = text.split("\n")
    if "\r" in text or len(lines) != 3 or lines[2] != "":
        return p + ["a name line and a numbers line, as the editor's Save file writes them"]
    name, line = lines[0], lines[1]
    if not (1 <= len(name) <= 16) or name != name.strip() or re.search(r"[^\x20-\x7e]|/", name):
        p.append(f"the name {name!r}: 1 to 16 plain letters, digits and punctuation, without '/'")
    elif name.lower() in TAKEN:
        p.append(f"the name {name!r} is a built-in track's or the editor's name for a new track: give the track a name of its own")
    tok = line.split(" ")
    if len(tok) < 4 or tok[0] not in MOST or not re.fullmatch(r"[1-9][0-9]*", tok[1]):
        return p + ["the numbers line starts with the format (1 to 4), the id, the tree seed and the trees"]
    nums = line[len(tok[0]) + len(tok[1]) + 2:]
    if int(tok[1]) != fnv1a(nums) % 999999 + 1:
        p.append(f"the id {tok[1]} isn't the one the editor gives these numbers ({fnv1a(nums) % 999999 + 1}): "
                 "save the track from the editor again")
    scene = tok[0] in ("3", "4")
    # the sections: gates [/ structures] (formats 1 and 2); gates / structures / props / rails /
    # decals, an empty one as nothing between its '/' (3 and 4)
    secs = nums.split(" /")
    if len(secs) != (5 if scene else 1 + (" / " in nums)) or any(s and not s.startswith(" ") for s in secs[1:]):
        return p + ["format 3 and 4 have gates / structures / props / rails / decals, 1 and 2 gates [/ structures]" if scene
                    else "format 1 and 2 have gates [/ structures]: props, rails and decals are format 3 or 4"]
    toks = [s.split() for s in secs] + [[]] * (5 - len(secs))
    gt = toks[0]
    bad = [t for t in sum(toks, []) if not NUM.match(t)]
    if bad:
        return p + [f"{bad[0]!r} is not a number as the editor writes it (plain, at most 2 decimals)"]
    v = [float(t) for t in gt]
    if not (1 <= v[0] <= 99 and v[0] == int(v[0])) or not (0 <= v[1] <= 30 and v[1] == int(v[1])):
        p.append(f"tree seed {gt[0]} (1 to 99) and trees {gt[1]} (0 to 30)")
    G, B, P, R, D = v[2:], *[[float(t) for t in s] for s in toks[1:]]
    if len(G) % 5 or len(B) % 7 or len(P) % 4 or len(R) % 6 or len(D) % 6:
        return p + ["gates are 5 numbers each, structures 7, props 4, rails 6, decals 6"]
    ng, nb, npr, nr, nd = len(G) // 5, len(B) // 7, len(P) // 4, len(R) // 6, len(D) // 6
    if not 2 <= ng <= F2[0]:
        p.append(f"{ng} gates: 2 to {F2[0]}")
    for n, most_, what in ((nb, F4[1], "structures"), (npr, F4[2], "props"), (nr, F4[3], "rails"), (nd, F4[4], "decals")):
        if n > most_:
            p.append(f"{n} {what}: {most_} at most")
    size = len(text.encode())
    kinds = any(B[i * 7 + 6] > 3 for i in range(nb))
    if scene:
        if not (npr or nr or nd or kinds):
            p.append("no scenery (props, rails, decals, structures of kinds 4 to 9) is format 1 or 2: save the track from the editor again")
        fits3 = ng <= F3[0] and nb <= F3[1] and npr <= F3[2] and nr <= F3[3] and nd <= F3[4] and size <= F3[5]
        if tok[0] == "3" and not fits3:
            p.append(f"more than {F3[0]} gates, {F3[1]} structures, {F3[2]} props, {F3[3]} rails, {F3[4]} decals or {F3[5]} bytes "
                     "is format 4: save the track from the editor again")
        elif tok[0] == "4" and fits3:
            p.append("it fits format 3 (color and B&W radios): save the track from the editor again")
    else:
        fits = ng <= F1[0] and nb <= F1[1] and size <= F1[2]
        if tok[0] == "1" and not fits:
            p.append(f"more than {F1[0]} gates, {F1[1]} structures or {F1[2]} bytes is format 2: save the track from the editor again")
        elif tok[0] == "2" and fits:
            p.append("it fits format 1 (color and B&W radios): save the track from the editor again")
    for i in range(ng):
        x, z, k, yaw, h = G[i * 5:i * 5 + 5]
        if not (abs(x) <= 999 and abs(z) <= 999 and k in range(1, 9) and yaw in range(360) and 0 <= h <= 100):
            p.append(f"gate {i + 1}: x and z within 999 m, type 1 to 8, yaw 0 to 359, height 0 to 100")
        if i == 0 and k == 3:
            p.append("gate 1 can't be a dive gate")
    kmax = 9 if scene else 3
    for i in range(nb):
        x, z, hx, hz, y0, y1, k = B[i * 7:i * 7 + 7]
        if not (abs(x) <= 999 and abs(z) <= 999 and 0.05 <= hx <= 200 and 0.05 <= hz <= 200 and 0 <= y0 <= 200
                and 0.1 <= y1 <= 300 and y0 < y1 and k in range(1, kmax + 1)):
            p.append(f"structure {i + 1}: within 999 m, half sizes 0.05 to 200, bottom 0 to 200 below top 0.1 to 300, kind 1 to {kmax}")
    for i in range(npr):
        x, z, k, h = P[i * 4:i * 4 + 4]
        if not (abs(x) <= 999 and abs(z) <= 999 and k in range(1, 11) and 0 <= h <= 40):
            p.append(f"prop {i + 1}: within 999 m, kind 1 to 10, height 0 to 40")
    for i in range(nr):
        x1, z1, x2, z2, k, h = R[i * 6:i * 6 + 6]
        if not (max(abs(x1), abs(z1), abs(x2), abs(z2)) <= 999 and k in range(1, 6) and 0 <= h <= 40 and (x2 - x1) ** 2 + (z2 - z1) ** 2 > 0.25):
            p.append(f"rail {i + 1}: within 999 m, kind 1 to 5, height 0 to 40, its ends more than 0.5 m apart")
    for i in range(nd):
        x, z, a, b, yaw, k = D[i * 6:i * 6 + 6]
        if not (abs(x) <= 999 and abs(z) <= 999 and 0.05 <= a <= 200 and 0.05 <= b <= 200 and yaw in range(360) and k in range(1, 7)):
            p.append(f"decal {i + 1}: within 999 m, half length and half width 0.05 to 200, yaw 0 to 359, kind 1 to 6")
    return p


def info_problems(info):
    if not isinstance(info, dict):
        return ["the .json holds one object: {\"by\": ..., \"about\": ..., \"source\": ...}"]
    p = [f"{k!r}: the keys are by, about and source" for k in info if k not in KEYS]
    for k, n in KEYS.items():
        v = info.get(k)
        if v is None and k == "by":
            p.append("'by' says who made it")
        # (control, zero-width and direction characters too: they hide or turn round what the card
        # shows; the length as the page counts it, in UTF-16 units)
        elif v is not None and (not isinstance(v, str) or not v.strip() or len(v.encode("utf-16-le")) // 2 > n
                                or re.search("[\x00-\x1f\x7f-\x9f\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]", v)):
            p.append(f"{k!r}: one line of plain text, {n} characters at most (leave the key out if there is nothing to say)")
    s = info.get("source")
    if isinstance(s, str) and not re.match(r"^https://[^\s\"'<>]+$", s):
        p.append("'source' is an https:// link")
    return p


def earlier_ids(f, now):
    """the ids a track had before, from its file's git history (renames followed), newest first: a
    slot holding one of them has an older version of it (none outside a git checkout)"""
    try:
        log = subprocess.run(["git", "log", "--follow", "--format=%H", "--name-only", "--", f.name],
                             cwd=f.parent, capture_output=True, text=True, check=True).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        return []
    ids = []
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=f.parent, capture_output=True, text=True).stdout.strip()
    for sha, path in zip(log[::2], log[1::2]):
        try:
            text = subprocess.run(["git", "show", f"{sha}:{path}"], cwd=top, capture_output=True, check=True).stdout
        except (OSError, subprocess.CalledProcessError):
            continue
        tok = text.decode("utf-8", "replace").replace("\r\n", "\n").split("\n")[1:2]
        tok = tok[0].split(" ") if tok else []
        if len(tok) > 1 and re.fullmatch(r"[1-9][0-9]*", tok[1]) and int(tok[1]) != now and int(tok[1]) not in ids:
            ids.append(int(tok[1]))
    return ids


def gallery(d=DIR):
    """(tracks, problems): the tracks in file order, each {file, name, by, about, source, text, was}"""
    tracks, probs = [], []
    files = sorted(d.glob("*")) if d.is_dir() else []
    for f in files:
        if f.name.lower() == "readme.md":
            continue
        if f.suffix not in (".txt", ".json"):
            probs.append(f"{f.name}: the gallery takes <name>.txt and <name>.json")
        elif not FILE.match(f.stem) or len(f.stem) > 40 or WIN.match(f.stem):
            probs.append(f"{f.name}: a name of lowercase letters, digits and dashes (40 at most), like my-track.txt")
        elif not f.with_suffix(".json" if f.suffix == ".txt" else ".txt").exists():
            probs.append(f"{f.name}: no {f.stem}{'.json' if f.suffix == '.txt' else '.txt'} beside it")
    for f in files:
        if f.suffix != ".txt" or not FILE.match(f.stem) or WIN.match(f.stem) or not f.with_suffix(".json").exists():
            continue
        try:
            # (a checkout on Windows may have CR LF line ends: the repo has LF, as Save file writes)
            text = f.read_bytes().replace(b"\r\n", b"\n").decode("utf-8")
        except UnicodeDecodeError:
            probs.append(f"{f.name}: not plain text")
            continue
        try:
            info = json.loads(f.with_suffix(".json").read_text(encoding="utf-8-sig"))   # (a BOM is fine)
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
            was = earlier_ids(f, int(text.split("\n")[1].split(" ")[1]))
            if was:
                t["was"] = was                 # (the editor offers Update to a slot with one of these)
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
