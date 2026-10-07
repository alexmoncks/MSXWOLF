#!/usr/bin/env python3
"""build_art.py - the Higgsfield pictures (assets/src/*.png) -> the cartridge's art.

  out/art.json          palette, wall textures, sprites, pistol frames (indices)
  out/preview_art.png   everything, in the final colours

Palette: 256 entries of 15 bits (V9968 EPAL). Entries 1..127 are the colours;
entry n + 128 is entry n darkened, so a wall facing east or west is the same
texture with 128 added to every texel (Wolfenstein 3D's light and dark walls).
Entry 0 is black and, in a texture, a hole (the Geo3D run uses TIMP).
  1..7    status bar colours     8, 9  ceiling and floor     10  near black
  11..127 the art, quantized together (median cut, then k-means)

Pure Python (zlib only): the pictures are decoded once and cached in out/cache.
"""
import json
import os
import pickle
import struct
import sys
import zlib

from common import MSX as ROOT, OUT, write_png

SRC = os.path.join(ROOT, "assets", "src")
CACHE = os.path.join(OUT, "cache")

FIXED = {0: (0, 0, 0), 1: (0, 2, 12), 2: (21, 21, 23), 3: (31, 31, 31), 4: (31, 7, 5), 5: (31, 27, 5),
         6: (0, 0, 5), 7: (10, 10, 13), 8: (7, 7, 7), 9: (14, 14, 14), 10: (1, 1, 1)}
FIRST_FREE = 11
DARK = 0.60

WALLS = ["wall_stone", "wall_stone_banner", "wall_stone_painting", "wall_stone_plaque",
         "wall_blue", "wall_blue_cell", "wall_wood", "wall_wood_emblem",
         "wall_elevator", "door", "door_elevator", "door_jamb"]

UPP = 5        # world units per sprite pixel (a wall texel is 4)

# name: (source, quadrant or None, fit width, fit height, base: "floor", "ceil" or units above the floor)
SPRITES = {
    "guard_stand": ("guard_stand", None, 34, 46, "floor"),
    "guard_walk1": ("guard_walk1", None, 34, 46, "floor"),
    "guard_walk2": ("guard_walk2", None, 34, 46, "floor"),
    "guard_aim": ("guard_aim", None, 34, 46, "floor"),
    "guard_fire": ("guard_fire", None, 34, 46, "floor"),
    "guard_pain": ("guard_pain", None, 36, 44, "floor"),
    "guard_dying": ("guard_dying", None, 36, 34, "floor"),
    "guard_dead": ("guard_dead", None, 44, 14, "floor"),
    "dog_run1": ("dog_run1", None, 26, 30, "floor"),
    "dog_run2": ("dog_run2", None, 26, 30, "floor"),
    "dog_bite": ("dog_bite", None, 30, 34, "floor"),
    "dog_dead": ("dog_dead", None, 38, 12, "floor"),
    "lamp_floor": ("sheet_decor1", 0, 14, 40, "floor"),
    "armor": ("sheet_decor1", 1, 22, 44, "floor"),
    "plant": ("sheet_decor1", 2, 24, 34, "floor"),
    "barrel": ("sheet_decor1", 3, 22, 26, "floor"),
    "table": ("sheet_decor2", 0, 44, 24, "floor"),
    "vase": ("sheet_decor2", 1, 16, 24, "floor"),
    "bones": ("sheet_decor2", 2, 30, 12, "floor"),
    "lamp_ceil": ("sheet_decor2", 3, 18, 16, "ceil"),
    "chandelier": ("sheet_decor3", 0, 32, 24, "ceil"),
    "well": ("sheet_decor3", 1, 30, 24, "floor"),
    "chest": ("sheet_decor3", 2, 22, 16, "floor"),
    "cross": ("sheet_decor3", 3, 12, 16, "floor"),
    "food": ("sheet_items", 0, 20, 12, "floor"),
    "medkit": ("sheet_items", 1, 18, 14, "floor"),
    "ammo": ("sheet_items", 2, 10, 14, "floor"),
    "chalice": ("sheet_items", 3, 12, 16, "floor"),
}
PISTOL_W, PISTOL_H, PISTOL_FIT_H = 64, 88, 74


# ---------------------------------------------------------------- PNG reader
def read_png(path):
    """-> (w, h, rows): rows[y] is a bytes object of w * 4 (RGBA)."""
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n"
    i, idat = 8, []
    while i < len(d):
        n, typ = struct.unpack(">I4s", d[i:i + 8])
        body = d[i + 8:i + 8 + n]
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
            assert depth in (8, 16) and ctype in (2, 6) and inter == 0, (depth, ctype, inter)
        elif typ == b"IDAT":
            idat.append(body)
        i += 12 + n
    raw = zlib.decompress(b"".join(idat))
    ch = (3 if ctype == 2 else 4) * (depth // 8)
    bpp = ch
    stride = w * ch
    rows, prev = [], bytearray(stride)
    pos = 0
    for y in range(h):
        f = raw[pos]
        cur = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if f == 1:
            for x in range(bpp, stride):
                cur[x] = (cur[x] + cur[x - bpp]) & 255
        elif f == 2:
            cur = bytearray((a + b) & 255 for a, b in zip(cur, prev))
        elif f == 3:
            for x in range(stride):
                left = cur[x - bpp] if x >= bpp else 0
                cur[x] = (cur[x] + ((left + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = cur[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                cur[x] = (cur[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = cur
        if depth == 16:
            cur = cur[0::2]
        if ctype == 2:
            row = bytearray(w * 4)
            row[0::4], row[1::4], row[2::4] = cur[0::3], cur[1::3], cur[2::3]
            row[3::4] = b"\xff" * w
            rows.append(bytes(row))
        else:
            rows.append(bytes(cur))
    return w, h, rows


def load(name):
    os.makedirs(CACHE, exist_ok=True)
    src = os.path.join(SRC, name + ".png")
    cp = os.path.join(CACHE, name + ".pkl")
    if os.path.exists(cp) and os.path.getmtime(cp) >= os.path.getmtime(src):
        return pickle.load(open(cp, "rb"))
    print("  decoding", name, file=sys.stderr)
    img = read_png(src)
    pickle.dump(img, open(cp, "wb"))
    return img


# ---------------------------------------------------------------- resampling
def box(rows, x0, y0, x1, y1, need_alpha):
    """Average of the opaque pixels of a box -> (r, g, b, coverage)."""
    r = g = b = n = 0
    tot = (x1 - x0) * (y1 - y0)
    for y in range(y0, y1):
        row = rows[y]
        for x in range(x0, x1):
            if not need_alpha or row[4 * x + 3] >= 128:
                r += row[4 * x]
                g += row[4 * x + 1]
                b += row[4 * x + 2]
                n += 1
    if not n:
        return 0, 0, 0, 0.0
    return r / n, g / n, b / n, n / tot


def tile(name, size=64):
    w, h, rows = load(name)
    out = []
    for y in range(size):
        for x in range(size):
            r, g, b, _ = box(rows, x * w // size, y * h // size, (x + 1) * w // size, (y + 1) * h // size, False)
            out.append((r, g, b))
    return out


def bbox(rows, x0, y0, x1, y1):
    xs, ys = [], []
    for y in range(y0, y1):
        row = rows[y]
        hit = [x for x in range(x0, x1) if row[4 * x + 3] >= 128]
        if hit:
            ys.append(y)
            xs.append(hit[0])
            xs.append(hit[-1])
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


def sprite(name, quad, fw, fh, scale=None, anchor=None):
    """Crop to the opaque part, scale to fit fw x fh -> (w, h, pixels or None)."""
    w, h, rows = load(name)
    if quad is None:
        region = (0, 0, w, h)
    else:
        region = ((quad % 2) * w // 2, (quad // 2) * h // 2, (quad % 2 + 1) * w // 2, (quad // 2 + 1) * h // 2)
    bx0, by0, bx1, by1 = bbox(rows, *region)
    bw, bh = bx1 - bx0, by1 - by0
    s = min(fw / bw, fh / bh)
    ow, oh = max(1, round(bw * s)), max(1, round(bh * s))
    out = []
    for y in range(oh):
        for x in range(ow):
            sx0, sx1 = bx0 + x * bw // ow, bx0 + max(x * bw // ow + 1, (x + 1) * bw // ow)
            sy0, sy1 = by0 + y * bh // oh, by0 + max(y * bh // oh + 1, (y + 1) * bh // oh)
            r, g, b, cov = box(rows, sx0, sy0, sx1, sy1, True)
            out.append((r, g, b) if cov >= 0.5 else None)
    return ow, oh, out


def pistol(name, ref_box=None):
    """The pistol in a 64 x 88 canvas, bottom centre; both frames use the first one's box."""
    w, h, rows = load(name)
    if ref_box is None:
        ref_box = bbox(rows, 0, 0, w, h)
    bx0, by0, bx1, by1 = ref_box
    s = PISTOL_FIT_H / (by1 - by0)
    cx = (bx0 + bx1) / 2
    out = []
    for y in range(PISTOL_H):
        for x in range(PISTOL_W):
            # canvas pixel -> source box
            fx0 = cx + (x - PISTOL_W / 2) / s
            fy0 = by1 - (PISTOL_H - y) / s
            sx0, sy0 = int(fx0), int(fy0)
            sx1, sy1 = max(sx0 + 1, int(fx0 + 1 / s)), max(sy0 + 1, int(fy0 + 1 / s))
            if sx0 < 0 or sy0 < 0 or sx1 > w or sy1 > h:
                out.append(None)
                continue
            r, g, b, cov = box(rows, sx0, sy0, sx1, sy1, True)
            out.append((r, g, b) if cov >= 0.5 else None)
    return ref_box, out


# ---------------------------------------------------------------- palette
def to15(c):
    return (min(31, int(c[0] * 31 / 255 + 0.5)), min(31, int(c[1] * 31 / 255 + 0.5)), min(31, int(c[2] * 31 / 255 + 0.5)))


def quantize(hist, n):
    """hist: {(r, g, b) 5-bit: weight} -> n colours (median cut, then k-means)."""
    boxes = [list(hist.items())]
    while len(boxes) < n:
        best, bi = -1, -1
        for i, bx in enumerate(boxes):
            if len(bx) < 2:
                continue
            spread = max(max(c[0][k] for c in bx) - min(c[0][k] for c in bx) for k in range(3))
            score = spread * sum(c[1] for c in bx) ** 0.5
            if score > best:
                best, bi = score, i
        if bi < 0:
            break
        bx = boxes.pop(bi)
        k = max(range(3), key=lambda k: max(c[0][k] for c in bx) - min(c[0][k] for c in bx))
        bx.sort(key=lambda c: c[0][k])
        half, acc, cut = sum(c[1] for c in bx) / 2, 0, 1
        for i, c in enumerate(bx[:-1]):
            acc += c[1]
            cut = i + 1
            if acc >= half:
                break
        boxes += [bx[:cut], bx[cut:]]
    cents = []
    for bx in boxes:
        wsum = sum(c[1] for c in bx)
        cents.append(tuple(sum(c[0][k] * c[1] for c in bx) / wsum for k in range(3)))
    items = list(hist.items())
    for _ in range(4):
        acc = [[0, 0, 0, 0] for _ in cents]
        for col, wgt in items:
            bi = min(range(len(cents)), key=lambda i: (col[0] - cents[i][0]) ** 2 * 3 +
                     (col[1] - cents[i][1]) ** 2 * 4 + (col[2] - cents[i][2]) ** 2 * 2)
            a = acc[bi]
            a[0] += col[0] * wgt
            a[1] += col[1] * wgt
            a[2] += col[2] * wgt
            a[3] += wgt
        cents = [(a[0] / a[3], a[1] / a[3], a[2] / a[3]) if a[3] else cents[i] for i, a in enumerate(acc)]
    return [tuple(int(v + 0.5) for v in c) for c in cents]


def main():
    os.makedirs(OUT, exist_ok=True)
    walls = {n: tile(n) for n in WALLS}
    sprites = {}
    for name, (src, quad, fw, fh, base) in SPRITES.items():
        w, h, pix = sprite(src, quad, fw, fh)
        sprites[name] = dict(w=w, h=h, pix=pix, base=base)
    ref, p0 = pistol("pistol_ready")
    _, p1 = pistol("pistol_fire", ref)
    pistols = [p0, p1]

    # one histogram for everything (sprites weigh more: fewer pixels, looked at closely)
    hist = {}
    for pix, wgt in [(walls[n], 1) for n in WALLS] + [(s["pix"], 3) for s in sprites.values()] + [(p, 2) for p in pistols]:
        for c in pix:
            if c is not None:
                k = to15(c)
                hist[k] = hist.get(k, 0) + wgt
    art = quantize(hist, 128 - FIRST_FREE)
    pal = [(0, 0, 0)] * 256
    for i, c in FIXED.items():
        pal[i] = c
    for i, c in enumerate(art):
        pal[FIRST_FREE + i] = c
    for i in range(128):
        pal[128 + i] = tuple(int(v * DARK + 0.5) for v in pal[i])
    cache = {}

    def nearest(c):
        k = to15(c)
        if k not in cache:
            cache[k] = min(range(1, 128), key=lambda i: (k[0] - pal[i][0]) ** 2 * 3 +
                           (k[1] - pal[i][1]) ** 2 * 4 + (k[2] - pal[i][2]) ** 2 * 2)
        return cache[k]

    out = dict(palette=pal, walls={}, sprites={}, pistol=[], upp=UPP)
    for n in WALLS:
        out["walls"][n] = [nearest(c) for c in walls[n]]
    for name, s in sprites.items():
        out["sprites"][name] = dict(w=s["w"], h=s["h"], base=s["base"],
                                    pix=[0 if c is None else nearest(c) for c in s["pix"]])
    for p in pistols:
        out["pistol"].append([0 if c is None else nearest(c) for c in p])
    json.dump(out, open(os.path.join(OUT, "art.json"), "w"))

    # preview: walls (light over dark), then the sprites and the pistol on grey
    W, H = 64 * 12, 64 * 2 + 100 + 96
    img = bytearray(bytes((40, 0, 48)) * (W * H))
    lut = [bytes(((v << 3) | (v >> 2)) for v in c) for c in pal]

    def put(x, y, idx):
        if 0 <= x < W and 0 <= y < H:
            img[3 * (y * W + x):3 * (y * W + x) + 3] = lut[idx]

    for i, n in enumerate(WALLS):
        for k, p in enumerate(out["walls"][n]):
            put(64 * i + k % 64, k // 64, p)
            put(64 * i + k % 64, 64 + k // 64, p + 128)
    x = 2
    y0 = 132
    for name, s in out["sprites"].items():
        if x + s["w"] > W - 2:
            x, y0 = 2, y0 + 50
        for k, p in enumerate(s["pix"]):
            if p:
                put(x + k % s["w"], y0 + 48 - s["h"] + k // s["w"], p)
        x += s["w"] + 3
    for i, p in enumerate(out["pistol"]):
        for k, v in enumerate(p):
            if v:
                put(W - 140 + 68 * i + k % 64, H - 90 + k // 64, v)
    write_png(os.path.join(OUT, "preview_art.png"), W, H, bytes(img))
    area = sum(s["w"] * s["h"] for s in out["sprites"].values())
    print(f"{len(WALLS)} wall textures, {len(sprites)} sprites ({area} pixels), {len(art)} art colours")


if __name__ == "__main__":
    main()
