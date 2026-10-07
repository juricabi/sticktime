#!/usr/bin/env python3
"""Extract ASCII glyphs from public-domain X11 misc-fixed bitmap fonts (KOI8 builds,
ASCII range is identical) into a compact JS module used by the web emulator to draw
B&W radio text."""
import gzip, io, json, sys
from PIL import PcfFontFile

SRC = "/usr/share/fonts/X11/cyrillic/{}.pcf.gz"
# EdgeTX B&W size flags -> closest misc-fixed font
FONTS = {"tin": "koi5x8", "sml": "koi5x8", "std": "koi6x9", "mid": "koi8x16b", "dbl": "koi9x15b", "xxl": "koi12x24b"}
# koi6x9 stores its table one code early (glyph[code - 1] is the character)
SHIFT = {"koi6x9": -1}
# cell fitted to EdgeTX's font: rows dropped at the top, cell height. MIDSIZE is EdgeTX's
# bold 8x10 font in a 12-row cell, capitals on rows 1-10 (koi8x16b has them on rows 2-11)
CELL = {"mid": (1, 12)}

out = {}
for key, name in FONTS.items():
    raw = gzip.open(SRC.format(name)).read()
    f = PcfFontFile.PcfFontFile(io.BytesIO(raw), "iso8859-1")
    glyphs = []
    cellw = 0
    asc = 0
    desc = 0
    for code in range(32, 127):
        g = f.glyph[code + SHIFT.get(name, 0)]
        if g is None:
            glyphs.append([0, 0, 0, 0, 0, ""]); continue
        (adv, _), dst, src, im = g
        x0, y0, x1, y1 = dst          # relative to origin, y up? (PIL: dst box in output cell)
        w, h = im.size
        rows = []
        for y in range(h):
            bits = 0
            for x in range(w):
                if im.getpixel((x, y)):
                    bits |= 1 << x
            rows.append(bits)
        glyphs.append([adv, x0, y0, w, h, ",".join(str(r) for r in rows)])
        cellw = max(cellw, adv)
    # vertical metrics from bbox
    ys0 = min(g[2] for g in glyphs if g[4]); ys1 = max(g[2] + g[4] for g in glyphs if g[4])
    if key in CELL:
        top, rows = CELL[key]
        ys0 += top
        ys1 = ys0 + rows
    out[key] = {"name": name, "adv": cellw, "y0": ys0, "y1": ys1, "g": glyphs}
    print(key, name, "adv", cellw, "y-range", ys0, ys1, file=sys.stderr)

js = "/* B&W radio text: ASCII glyphs from the public-domain X11 misc-fixed bitmap fonts */\nconst BW_FONTS = " + json.dumps(out, separators=(",", ":")) + ";\n"
open(sys.argv[1], "w").write(js)
print("wrote", sys.argv[1], len(js), "bytes", file=sys.stderr)
