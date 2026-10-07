#!/usr/bin/env python3
"""wolfmap.py - reads a level of Wolfenstein 3D (MAPHEAD / GAMEMAPS, shareware .WL1).

Only the level layout is taken from the original game: the wall plane and the
object plane, 64 x 64 words each. All the art of the cartridge is new.

  wolfmap.py [level]        prints the level and a census of what it uses
load_level(n) -> dict(name, width, height, walls, objects)
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.environ.get("WOLFDATA") or os.path.join(os.path.dirname(os.path.dirname(HERE)),
                                                  "wolf3d-shareware", "wolf3d14")


def carmack_expand(src, length):
    """id's 'Carmack' compression: words; high byte A7h / A8h tag near / far copies."""
    out = []
    i = 0
    n = length // 2
    while len(out) < n:
        w = src[i] | (src[i + 1] << 8)
        i += 2
        hi, count = w >> 8, w & 0xFF
        if hi == 0xA7:
            if count == 0:
                out.append((hi << 8) | src[i])
                i += 1
            else:
                ofs = src[i]
                i += 1
                start = len(out) - ofs
                for k in range(count):
                    out.append(out[start + k])
        elif hi == 0xA8:
            if count == 0:
                out.append((hi << 8) | src[i])
                i += 1
            else:
                ofs = src[i] | (src[i + 1] << 8)
                i += 2
                for k in range(count):
                    out.append(out[ofs + k])
        else:
            out.append(w)
    return out


def rlew_expand(words, length, tag):
    out = []
    i = 0
    n = length // 2
    while len(out) < n:
        w = words[i]
        i += 1
        if w == tag:
            count, value = words[i], words[i + 1]
            i += 2
            out.extend([value] * count)
        else:
            out.append(w)
    return out[:n]


def load_level(n=0):
    head = open(os.path.join(DATA, "MAPHEAD.WL1"), "rb").read()
    tag = struct.unpack_from("<H", head, 0)[0]
    ofs = struct.unpack_from("<i", head, 2 + 4 * n)[0]
    maps = open(os.path.join(DATA, "GAMEMAPS.WL1"), "rb").read()
    pstart = struct.unpack_from("<3i", maps, ofs)
    plen = struct.unpack_from("<3H", maps, ofs + 12)
    width, height = struct.unpack_from("<2H", maps, ofs + 18)
    name = maps[ofs + 22:ofs + 38].split(b"\0")[0].decode("ascii")
    planes = []
    for p in range(2):
        src = maps[pstart[p]:pstart[p] + plen[p]]
        explen = struct.unpack_from("<H", src, 0)[0]
        words = carmack_expand(src[2:], explen)
        planes.append(rlew_expand(words[1:], words[0], tag))
    return dict(name=name, width=width, height=height, walls=planes[0], objects=planes[1])


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    lv = load_level(n)
    w, h = lv["width"], lv["height"]
    print(lv["name"], w, "x", h)
    walls, objs = lv["walls"], lv["objects"]
    census_w, census_o = {}, {}
    for v in walls:
        census_w[v] = census_w.get(v, 0) + 1
    for v in objs:
        if v:
            census_o[v] = census_o.get(v, 0) + 1
    print("wall plane:", sorted((k, v) for k, v in census_w.items() if k < 106))
    print("areas:", sorted(k for k in census_w if k >= 106))
    print("object plane:", sorted(census_o.items()))
    xs = [i % w for i, v in enumerate(walls) if v >= 106 or 90 <= v <= 101]
    ys = [i // w for i, v in enumerate(walls) if v >= 106 or 90 <= v <= 101]
    print("used:", min(xs), "..", max(xs), "x", min(ys), "..", max(ys),
          "free cells:", sum(1 for v in walls if v >= 106), "doors:", sum(1 for v in walls if 90 <= v <= 101))
    for y in range(h):
        row = ""
        for x in range(w):
            v, o = walls[y * w + x], objs[y * w + x]
            if 19 <= o <= 22:
                c = "P"
            elif 90 <= v <= 101:
                c = "|" if v % 2 == 0 else "-"
            elif v < 64:
                c = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"[v] if v < 36 else "#"
            elif o == 98:
                c = "s"
            elif 108 <= o < 400:
                c = "e"
            elif 23 <= o <= 74:
                c = "o"
            else:
                c = "."
            row += c
        print(row)


if __name__ == "__main__":
    main()
