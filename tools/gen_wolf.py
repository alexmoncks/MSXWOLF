#!/usr/bin/env python3
"""gen_wolf.py - builds everything the MSX WOLF cartridge reads from ROM.

Input: the layout of a Wolfenstein 3D level (tools/wolfmap.py: wall plane and
object plane of the shareware GAMEMAPS) and the art of out/art.json
(tools/build_art.py, from the Higgsfield pictures). No art of the original
game is used.

  out/tex.bin        256 x 512: the texture area (VRAM rows 512..1023)
  out/hidden.bin     256 x 44: the pistol frames (VRAM rows 468..511)
  out/palettes.bin   3 palettes of 256 x (R, G, B) 5-bit: normal, hurt, bonus
  out/bank1.bin      the map grid, the objects, the monsters, the doors
  out/pvsptr.bin     3 bytes per map cell: bank and address of its list
  out/pvs_N.bin      the per-cell lists, packed in 16 KB banks
  out/inc/*.asm      constants, the small tables of bank 0, the bank list
  out/world.json     the same data for tools/sim.py

What the Z80 does not do is done here: for every cell the player can stand in,
rays from a grid of points inside it find the wall faces, objects and doors in
sight, and through which door each one is seen ("dep": it is skipped while that
door is closed).

A cell's list:
  db n ; n x 2   near walls (the 3 x 3 cells around): i | j << 2 | dir << 4, texture | dark << 4
  5 bytes        the areas in sight (bit per area): monsters there are drawn
  db n ; n x 4   objects: index, a0, lim, dep
  db n ; n x 4   doors: index, a0, lim, dep
  db n ; n x 6   far faces: corner A x, z ; dir | texture << 2 | dark << 6 | split << 7 ; a0, lim ; dep
a0, lim: in view when ((yaw - a0) & 255) <= lim. dep: 0, or a door's number + 1.
"""
import hashlib
import json
import math
import os
import sys

from common import *
from wolfmap import load_level

LEVEL = int(os.environ.get("LEVEL", "0"))
SKILL = int(os.environ.get("SKILL", "1"))        # 0 easy, 1 medium, 2 hard: which monsters are placed

lv = load_level(LEVEL)
assert lv["width"] == MAP_W and lv["height"] == MAP_H
P0, P1 = lv["walls"], lv["objects"]

WALL_TEX = {1: 0, 2: 0, 3: 1, 4: 2, 5: 5, 6: 3, 7: 5, 8: 4, 9: 4, 10: 7, 11: 7, 12: 6, 21: 8}
TEX_DOOR, TEX_ELEV_DOOR, TEX_JAMB = 9, 10, 11
ELEVATOR_TILE = 21

# object plane -> (sprite, blocks the way, kind). Kinds: what a pickup gives.
K_DECOR, K_FOOD, K_DOGFOOD, K_MEDKIT, K_AMMO, K_CROSS, K_CHALICE, K_CHEST, K_FULL = range(9)
OBJ = {
    24: ("barrel", 1, 0), 25: ("table", 1, 0), 26: ("lamp_floor", 1, 0), 27: ("chandelier", 0, 0),
    29: ("food", 0, K_DOGFOOD), 30: ("armor", 1, 0), 31: ("plant", 1, 0), 32: ("bones", 0, 0),
    33: ("well", 1, 0), 34: ("plant", 1, 0), 35: ("vase", 1, 0), 36: ("table", 1, 0),
    37: ("lamp_ceil", 0, 0), 39: ("armor", 1, 0), 41: ("bones", 0, 0), 42: ("bones", 0, 0),
    46: ("vase", 1, 0), 47: ("food", 0, K_FOOD), 48: ("medkit", 0, K_MEDKIT), 49: ("ammo", 0, K_AMMO),
    50: ("ammo", 0, K_AMMO), 51: ("ammo", 0, K_AMMO), 52: ("cross", 0, K_CROSS),
    53: ("chalice", 0, K_CHALICE), 54: ("chest", 0, K_CHEST), 55: ("chalice", 0, K_CHEST),
    56: ("medkit", 0, K_FULL), 57: ("bones", 0, 0), 58: ("barrel", 1, 0), 59: ("well", 1, 0),
    60: ("well", 1, 0), 61: ("bones", 0, 0), 62: ("lamp_floor", 1, 0), 124: ("guard_dead", 0, 0),
}

ART = json.load(open(os.path.join(OUT, "art.json")))
SPR_NAMES = list(ART["sprites"].keys())
FRAME_ID = {n: i for i, n in enumerate(SPR_NAMES)}

# ---------------------------------------------------------------- the level
kind = [[G_WALL] * MAP_W for _ in range(MAP_H)]      # per cell: G_*
val = [[0] * MAP_W for _ in range(MAP_H)]            # area, door number or wall texture
doors = []                                           # (x, z, vertical, texture)
objects = []                                         # (x, z, frame, kind)
enemies = []                                         # (type, x, z, dir)
player = None

for z in range(MAP_H):
    for x in range(MAP_W):
        v, o = P0[z * MAP_W + x], P1[z * MAP_W + x]
        if 90 <= v <= 101:
            kind[z][x] = G_DOOR
            val[z][x] = len(doors)
            doors.append((x, z, v % 2 == 0, TEX_ELEV_DOOR if v >= 100 else TEX_DOOR))
        elif v >= 106:
            kind[z][x] = G_FLOOR
            val[z][x] = v - 107 if v >= 107 else -1
        else:
            val[z][x] = WALL_TEX.get(v, 0)
            if v == ELEVATOR_TILE:
                val[z][x] |= 0x100                    # (marks the elevator's walls)
        if 19 <= o <= 22:
            player = (x, z, (0, 64, 128, 192)[o - 19])
        elif o in OBJ:
            name, block, k = OBJ[o]
            objects.append((x, z, FRAME_ID[name], k))
            if block and kind[z][x] == G_FLOOR:
                kind[z][x] = G_BLOCK
        else:
            for base, typ, minskill in ((108, 0, 0), (112, 0, 0), (144, 0, 1), (148, 0, 1), (180, 0, 2), (184, 0, 2),
                                        (138, 1, 0), (174, 1, 1), (210, 1, 2)):
                if base <= o < base + 4 and SKILL >= minskill:
                    enemies.append((typ, x, z, o - base))    # dir: 0 east, 1 north, 2 west, 3 south

assert player and len(doors) <= 64 and len(objects) <= 255
# floor cells without an area of their own (ambush tiles) take a neighbour's
for z in range(MAP_H):
    for x in range(MAP_W):
        if kind[z][x] in (G_FLOOR, G_BLOCK) and val[z][x] < 0:
            near = [val[z + dz][x + dx] for dx, dz in DIRS if kind[z + dz][x + dx] in (G_FLOOR, G_BLOCK) and val[z + dz][x + dx] >= 0]
            val[z][x] = near[0] if near else 0
# the elevator: floor next to its walls ends the level
for z in range(1, MAP_H - 1):
    for x in range(1, MAP_W - 1):
        if kind[z][x] == G_FLOOR and any(kind[z + dz][x + dx] == G_WALL and val[z + dz][x + dx] & 0x100 for dx, dz in DIRS):
            val[z][x] = AREA_EXIT
NAREAS = 37


def is_wall(x, z):
    return x < 0 or z < 0 or x >= MAP_W or z >= MAP_H or kind[z][x] == G_WALL


OPEN = [(x, z) for z in range(MAP_H) for x in range(MAP_W) if not is_wall(x, z)]

# ---------------------------------------------------------------- faces
SIDE_STEP = [(0, -1), (0, 1), (1, 0), (-1, 0)]       # side 0 N (wall at z-1), 1 S, 2 E, 3 W


def face_geom(cx, cz, side):
    """-> (ax, az, dir): corner A and the direction code of A -> B (left to right from inside)."""
    if side == 0:
        return cx, cz, 0
    if side == 1:
        return cx + 1, cz + 1, 1
    if side == 2:
        return cx + 1, cz, 2
    return cx, cz + 1, 3


def face_tex(cx, cz, side):
    """-> (texture, dark). Walls facing east or west are the dark copy, as in Wolfenstein 3D."""
    dark = 1 if side >= 2 else 0
    if kind[cz][cx] == G_DOOR:
        return TEX_JAMB, dark
    wx, wz = cx + SIDE_STEP[side][0], cz + SIDE_STEP[side][1]
    if wx < 0 or wz < 0 or wx >= MAP_W or wz >= MAP_H:
        return 0, dark
    return val[wz][wx] & 15, dark


# ---------------------------------------------------------------- visibility
SAMPLES = 5
RAYS = 720


def cast(ox, oz, dx, dz, maxd):
    """DDA. -> (cells: [(x, z, dep)], face hit or None, its dep). dep: the first door
    whose plane the ray crossed before getting there, + 1 (0: none)."""
    cx, cz = int(ox), int(oz)
    sx = 1 if dx > 0 else -1
    sz = 1 if dz > 0 else -1
    tdx = abs(1 / dx) if dx else 1e30
    tdz = abs(1 / dz) if dz else 1e30
    tmx = ((cx + 1 - ox) if dx > 0 else (ox - cx)) * tdx if dx else 1e30
    tmz = ((cz + 1 - oz) if dz > 0 else (oz - cz)) * tdz if dz else 1e30
    cells = []
    dep = 0
    tin = 0.0
    while True:
        cells.append((cx, cz, dep))
        stepx = tmx < tmz
        t = tmx if stepx else tmz
        tend = min(t, maxd)
        if kind[cz][cx] == G_DOOR and not dep:
            vert = doors[val[cz][cx]][2]
            a = (ox + dx * tin - cx - 0.5) if vert else (oz + dz * tin - cz - 0.5)
            b = (ox + dx * tend - cx - 0.5) if vert else (oz + dz * tend - cz - 0.5)
            if a * b < 0:
                dep = val[cz][cx] + 1
        if t >= maxd:
            return cells, None, dep
        if stepx:
            tmx += tdx
            if is_wall(cx + sx, cz):
                return cells, (cx, cz, 2 if sx > 0 else 3), dep
            cx += sx
        else:
            tmz += tdz
            if is_wall(cx, cz + sz):
                return cells, (cx, cz, 1 if sz > 0 else 0), dep
            cz += sz
        tin = t


def merge(d, key, dep):
    """A thing seen with no door in the way, or through different doors, depends on none."""
    if key not in d:
        d[key] = dep
    elif d[key] != dep:
        d[key] = 0


def compute_pvs():
    src = json.dumps([P0, P1, SAMPLES, RAYS, DRAW_DIST, SKILL])
    key = hashlib.sha1(src.encode()).hexdigest()
    cache = os.path.join(OUT, f"pvs_cache_{LEVEL}.json")
    if os.path.exists(cache):
        d = json.load(open(cache))
        if d.get("key") == key:
            return ([{tuple(k): v for k, v in c} for c in d["faces"]],
                    [{tuple(k): v for k, v in c} for c in d["cells"]])
    dirs = [(math.sin(2 * math.pi * (i + 0.5) / RAYS), -math.cos(2 * math.pi * (i + 0.5) / RAYS)) for i in range(RAYS)]
    faces, cells = [], []
    for n, (cx, cz) in enumerate(OPEN):
        fs, cs = {}, {}
        for j in range(SAMPLES):
            for i in range(SAMPLES):
                ox = cx + 0.03 + 0.94 * i / (SAMPLES - 1)
                oz = cz + 0.03 + 0.94 * j / (SAMPLES - 1)
                for dx, dz in dirs:
                    cl, hit, dep = cast(ox, oz, dx, dz, DRAW_DIST)
                    for (x, z, d) in cl:
                        merge(cs, (x, z), d)
                    if hit:
                        merge(fs, hit, dep)
        faces.append(fs)
        cells.append(cs)
        if n % 100 == 0:
            print(f"  visibility {n}/{len(OPEN)}", file=sys.stderr)
    json.dump({"key": key, "faces": [sorted(f.items()) for f in faces], "cells": [sorted(c.items()) for c in cells]},
              open(cache, "w"))
    return faces, cells


def bearing(dx, dz):
    return math.atan2(dx, -dz) * 256 / (2 * math.pi)


def arc(cx, cz, points, ref):
    """The bearings of `points` from the four corners of the cell -> (a0, lim) for the Z80's
    test, with the field of view and the turning margin added."""
    lo = hi = 0.0
    for px in (cx, cx + 1):
        for pz in (cz, cz + 1):
            for (ex, ez) in points:
                if ex == px and ez == pz:
                    return 0, 255
                d = (bearing(ex - px, ez - pz) - ref + 128) % 256 - 128
                lo, hi = min(lo, d), max(hi, d)
    amin, amax = math.floor(ref + lo), math.ceil(ref + hi)
    return (amin - FOV_HALF - YAW_MARGIN) % 256, min(255, (amax - amin) + 2 * (FOV_HALF + YAW_MARGIN))


OBJ_AT = {}
for i, o in enumerate(objects):
    OBJ_AT.setdefault((o[0], o[1]), []).append(i)


def build_lists(faces, cells):
    out = []
    for n, (cx, cz) in enumerate(OPEN):
        near, far, spr, drs = [], [], [], []
        for (fx, fz, side), dep in faces[n].items():
            ax, az, d = face_geom(fx, fz, side)
            tex, dark = face_tex(fx, fz, side)
            qx, qz = ax + DIRS[d][0] * 0.5, az + DIRS[d][1] * 0.5
            dist = math.hypot(qx - (cx + 0.5), qz - (cz + 0.5))
            if abs(fx - cx) <= 1 and abs(fz - cz) <= 1:
                i, j = ax - (cx - 1), az - (cz - 1)
                near.append((dist, bytes([i | (j << 2) | (d << 4), tex | (dark << 4)])))
            else:
                ref = bearing(qx - (cx + 0.5), qz - (cz + 0.5))
                a0, lim = arc(cx, cz, [(ax, az), (ax + DIRS[d][0], az + DIRS[d][1])], ref)
                split = 0x80 if dist < SPLIT_DIST else 0
                far.append((dist, bytes([ax, az, d | (tex << 2) | (dark << 6) | split, a0, lim, dep])))
        areas = 0
        for (x, z), dep in cells[n].items():
            if kind[z][x] in (G_FLOOR, G_BLOCK) and val[z][x] < NAREAS:
                areas |= 1 << val[z][x]
            if (x, z) == (cx, cz):
                continue
            pts = [(x, z), (x + 1, z), (x, z + 1), (x + 1, z + 1)]
            ref = bearing(x - cx, z - cz)
            dist = math.hypot(x - cx, z - cz)
            if kind[z][x] == G_DOOR:
                a0, lim = arc(cx, cz, pts, ref)
                drs.append((dist, bytes([val[z][x], a0, lim, dep])))
            for i in OBJ_AT.get((x, z), ()):
                a0, lim = arc(cx, cz, pts, ref)
                spr.append((dist, bytes([i, a0, lim, dep])))
        for i in OBJ_AT.get((cx, cz), ()):
            spr.append((0, bytes([i, 0, 255, 0])))
        if kind[cz][cx] == G_DOOR:
            drs.append((0, bytes([val[cz][cx], 0, 255, 0])))
        out.append(tuple([e for _, e in sorted(lst)] for lst in (near, spr, drs, far)) + (areas,))
    return out


def stats(lists):
    s = dict(near=0, spr=0, doors=0, far=0, far_in_view=0, static_v=0, bytes=0)
    for near, spr, drs, far, areas in lists:
        s["near"] = max(s["near"], len(near))
        s["spr"] = max(s["spr"], len(spr))
        s["doors"] = max(s["doors"], len(drs))
        s["far"] = max(s["far"], len(far))
        ncorn = set()
        for e in near:
            i, j, d = e[0] & 3, (e[0] >> 2) & 3, e[0] >> 4
            ncorn |= {(i, j), (i + DIRS[d][0], j + DIRS[d][1])}
        nv0 = 2 * len(ncorn) + 6 * len(near)
        for yaw in range(0, 256, 8):
            corners, nf, nv = set(), 0, nv0
            for e in far:
                if (yaw - e[3]) % 256 <= e[4]:
                    d = e[2] & 3
                    c2 = {(e[0], e[1]), (e[0] + DIRS[d][0], e[1] + DIRS[d][1])}
                    nv += 2 * len(c2 - corners) + (2 if e[2] & 0x80 else 0)
                    corners |= c2
                    nf += 1
            s["far_in_view"] = max(s["far_in_view"], nf)
            s["static_v"] = max(s["static_v"], nv)
    return s


# ---------------------------------------------------------------- textures
def build_texture():
    tex = bytearray(256 * 512)
    for t, name in enumerate(["wall_stone", "wall_stone_banner", "wall_stone_painting", "wall_stone_plaque",
                              "wall_blue", "wall_blue_cell", "wall_wood", "wall_wood_emblem",
                              "wall_elevator", "door", "door_elevator", "door_jamb"]):
        pix = ART["walls"][name]
        x0, y0 = 64 * (t % 4), 64 * (t // 4)
        for k, p in enumerate(pix):
            tex[(y0 + k // 64) * 256 + x0 + k % 64] = p
            tex[(y0 + 192 + k // 64) * 256 + x0 + k % 64] = p + 128      # the dark copy
    # the sprites, on shelves, in rows 384..511
    frames = [None] * len(SPR_NAMES)
    x = y = shelf = 0
    for name in sorted(SPR_NAMES, key=lambda n: -ART["sprites"][n]["h"]):
        s = ART["sprites"][name]
        if x + s["w"] > 256:
            x, y, shelf = 0, y + shelf, 0
        assert y + s["h"] <= 128, "the sprites do not fit rows 384..511"
        for k, p in enumerate(s["pix"]):
            tex[(384 + y + k // s["w"]) * 256 + x + k % s["w"]] = p
        upp = ART["upp"]
        hw = (s["w"] * upp + 1) // 2
        y0, y1 = (WALL_H - s["h"] * upp, WALL_H) if s["base"] == "ceil" else (0, s["h"] * upp)
        frames[FRAME_ID[name]] = dict(name=name, u0=x, sy=384 + y, w=s["w"], h=s["h"], halfw=hw, y0=y0, y1=y1)
        x += s["w"]
        shelf = max(shelf, s["h"])
    hidden = bytearray(256 * 44)
    for f, pix in enumerate(ART["pistol"]):
        for k, p in enumerate(pix):
            px, py = k % 64, k // 64
            hidden[(py % 44) * 256 + 128 * f + 64 * (py // 44) + px] = p
    return bytes(tex), frames, bytes(hidden)


def build_palettes():
    base = [tuple(c) for c in ART["palette"]]

    def mix(c, to, k):
        return tuple(int(round(c[i] + (to[i] - c[i]) * k)) for i in range(3))

    hud = lambda e: 1 <= (e & 127) <= 7
    hurt = [c if hud(e) else mix(c, (31, 0, 0), 0.40) for e, c in enumerate(base)]
    bonus = [c if hud(e) else mix(c, (31, 29, 16), 0.28) for e, c in enumerate(base)]
    pals = [base, hurt, bonus]
    return pals, b"".join(bytes(v for c in p for v in c) for p in pals)


# ---------------------------------------------------------------- sound effects (PSG)
def sfx_frames(n, tone=None, vol=(12, 0), noise=None, nvol=None):
    """n ticks of 1/60 s. tone: (f0, f1) Hz swept exponentially; noise: (p0, p1) noise periods.
    Each tick: flags | volume, tone period lo, hi, noise period (flags: 80h noise on, 40h tone off)."""
    out = bytearray()
    for i in range(n):
        k = i / max(1, n - 1)
        v = int(round(vol[0] + (vol[1] - vol[0]) * k))
        b0, per, npd = v & 15, 0, 0
        if tone:
            f = tone[0] * (tone[1] / tone[0]) ** k
            per = max(1, min(4095, int(round(111860.8 / f))))
        else:
            b0 |= 0x40
        if noise and (nvol is None or i < nvol):
            b0 |= 0x80
            npd = int(round(noise[0] + (noise[1] - noise[0]) * k)) & 31
        out += bytes([b0, per & 255, per >> 8, npd])
    return bytes(out)


SFX = [  # name, voice, ticks (the order is used by the code: BARK = ALERT + 1)
    ("shot", 0, sfx_frames(12, tone=(190, 50), vol=(15, 2), noise=(2, 20))),
    ("eshot", 1, sfx_frames(10, tone=(140, 60), vol=(13, 2), noise=(5, 24))),
    ("door", 1, sfx_frames(18, tone=(70, 110), vol=(9, 3), noise=(28, 16), nvol=18)),
    ("alert", 1, sfx_frames(6, tone=(330, 330), vol=(12, 10)) + sfx_frames(10, tone=(250, 200), vol=(12, 3))),
    ("bark", 1, sfx_frames(5, tone=(300, 180), vol=(13, 6), noise=(12, 18)) + sfx_frames(5, tone=(280, 160), vol=(13, 3), noise=(12, 20))),
    ("pain", 1, sfx_frames(7, tone=(260, 120), vol=(11, 3))),
    ("death", 1, sfx_frames(24, tone=(200, 40), vol=(13, 1), noise=(8, 28), nvol=14)),
    ("hurt", 1, sfx_frames(12, tone=(110, 70), vol=(13, 3), noise=(10, 20), nvol=7)),
    ("pickup", 1, sfx_frames(4, tone=(660, 660), vol=(12, 12)) + sfx_frames(6, tone=(880, 880), vol=(12, 4))),
    ("bonus", 1, sfx_frames(4, tone=(880, 880), vol=(12, 12)) + sfx_frames(4, tone=(1100, 1100), vol=(12, 12)) +
     sfx_frames(8, tone=(1320, 1320), vol=(12, 3))),
    ("empty", 0, sfx_frames(3, vol=(8, 4), noise=(4, 4))),
]


# ---------------------------------------------------------------- output
def db(data, per=16):
    data = bytes(data)
    return "\n".join("        db " + ", ".join(str(b) for b in data[i:i + per]) for i in range(0, len(data), per))


def dw(words, per=8):
    return "\n".join("        dw " + ", ".join(str(w & 0xFFFF) for w in words[i:i + per]) for i in range(0, len(words), per))


def main():
    os.makedirs(os.path.join(OUT, "inc"), exist_ok=True)
    tex, frames, hidden = build_texture()
    open(os.path.join(OUT, "tex.bin"), "wb").write(tex)
    open(os.path.join(OUT, "hidden.bin"), "wb").write(hidden)
    pals, palbin = build_palettes()
    open(os.path.join(OUT, "palettes.bin"), "wb").write(palbin)

    faces, cells = compute_pvs()
    lists = build_lists(faces, cells)
    st = stats(lists)

    # the lists, packed into 16 KB banks (a list never crosses a bank)
    PVS_BANK0 = 3
    banks, ptr = [bytearray()], bytearray(3 * MAP_W * MAP_H)
    for (cx, cz), (near, spr, drs, far, areas) in zip(OPEN, lists):
        near, spr, drs, far = near[:32], spr[:60], drs[:16], far[:120]
        assert len(near) <= 32
        blob = (bytes([len(near)]) + b"".join(near) + areas.to_bytes(5, "little") +
                bytes([len(spr)]) + b"".join(spr) + bytes([len(drs)]) + b"".join(drs) +
                bytes([len(far)]) + b"".join(far))
        if len(banks[-1]) + len(blob) > 16384:
            banks.append(bytearray())
        addr = 0x8000 + len(banks[-1])
        k = 3 * (cz * MAP_W + cx)
        ptr[k:k + 3] = bytes([PVS_BANK0 + len(banks) - 1, addr & 255, addr >> 8])
        banks[-1] += blob
    for n, b in enumerate(banks):
        open(os.path.join(OUT, f"pvs_{n}.bin"), "wb").write(bytes(b))
    open(os.path.join(OUT, "pvsptr.bin"), "wb").write(bytes(ptr))
    TEX_BANK0 = PVS_BANK0 + len(banks)
    HID_BANK = TEX_BANK0 + 8
    ROM_BANKS = 16
    while ROM_BANKS < HID_BANK + 1:
        ROM_BANKS *= 2

    grid = bytes(kind[z][x] | (val[z][x] & 63) for z in range(MAP_H) for x in range(MAP_W))
    open(os.path.join(OUT, "grid.bin"), "wb").write(grid)

    bk = ["; generated by tools/gen_wolf.py - do not edit", "; banks 3 and up: the cells' lists, the texture area, the pistol, padding"]
    for n in range(len(banks)):
        bk += ["        org 0x8000", f'        incbin "out/pvs_{n}.bin"', "        ds 0xC000 - $, 0xFF"]
    bk += ["        org 0x8000", '        incbin "out/tex.bin"']
    bk += ["        org 0x8000", '        incbin "out/hidden.bin"', "        ds 0xC000 - $, 0xFF"]
    for n in range(ROM_BANKS - HID_BANK - 1):
        bk += ["        org 0x8000", "        ds 0x4000, 0xFF"]
    open(os.path.join(OUT, "inc", "banks.asm"), "w").write("\n".join(bk) + "\n")

    c = ["; generated by tools/gen_wolf.py - do not edit"]
    eq = lambda n, v: c.append(f"{n}:{' ' * max(1, 15 - len(n))}equ {v}")
    for n, v in (("MAP_W", MAP_W), ("MAP_H", MAP_H), ("PVS_BANK0", PVS_BANK0), ("TEX_BANK0", TEX_BANK0),
                 ("TEX_BANKS", 8), ("HID_BANK", HID_BANK), ("ROM_BANKS", ROM_BANKS),
                 ("G3_F", FOCAL), ("G3_CX", CX), ("G3_CY", CY), ("G3_ZNEAR", ZNEAR),
                 ("G3_W", VIEW_W), ("G3_H", VIEW_H), ("EYE", EYE), ("WALL_H", WALL_H),
                 ("ZCLIP32", ZCLIP * ZSCALE), ("TEXY", TEXY), ("TSTRIDE", TSTRIDE),
                 ("YAW_MARGIN", YAW_MARGIN), ("SPR_MARGIN", SPR_MARGIN), ("WIN", WIN),
                 ("WIN_W", 2 * WIN + 1), ("CORNERS", (2 * WIN + 1) ** 2),
                 ("VMAX_STATIC", VMAX_STATIC), ("FMAX_STATIC", FMAX_STATIC), ("VMAX_SPR", VMAX_SPR),
                 ("NENEMY", len(enemies)), ("NOBJ", len(objects)), ("NDOOR", len(doors)),
                 ("START_X", player[0] * CELL + 128), ("START_Z", player[1] * CELL + 128), ("START_YAW", player[2]),
                 ("NBANDS", 2), ("PISTOL_ROW", PISTOL_ROW), ("AREA_EXIT", AREA_EXIT),
                 ("K_FOOD", K_FOOD), ("K_DOGFOOD", K_DOGFOOD), ("K_MEDKIT", K_MEDKIT), ("K_AMMO", K_AMMO),
                 ("K_CROSS", K_CROSS), ("K_CHALICE", K_CHALICE), ("K_CHEST", K_CHEST), ("K_FULL", K_FULL)):
        eq(n, v)
    for name, i in FRAME_ID.items():
        eq("FR_" + name.upper(), i)
    for i, (name, voice, data) in enumerate(SFX):
        eq("SFX_" + name.upper(), i)
    open(os.path.join(OUT, "inc", "const.asm"), "w").write("\n".join(c) + "\n")

    t = ["; generated by tools/gen_wolf.py - do not edit", "",
         "; sin(2 pi a / 256) in Q2.14; cos a = sin (a + 64)", "sin_tab:", dw([sin_q14(a) for a in range(256)])]
    t += ["", "; the normal's Y that makes geo3d pick texture band n (its 'light level')", "ny_tab:",
          dw([ny_of(l) for l in range(7)])]
    t += ["", "; row offsets of the corner window (WIN_W a row)", "corner_row:",
          dw([r * (2 * WIN + 1) for r in range(2 * WIN + 1)])]
    t += ["", "; billboard frames: u0, v0, w - 1, h - 1, dw normal Y, half width, y0, y1", "frame_tab:"]
    for f in frames:
        lvl = 6
        v0 = f["sy"] - 64 * lvl
        assert 0 <= v0 and v0 + f["h"] - 1 <= 255 and f["u0"] + f["w"] - 1 <= 255
        t.append(f"        db {f['u0']}, {v0}, {f['w'] - 1}, {f['h'] - 1}")
        t.append(f"        dw {ny_of(lvl)}, {f['halfw']}, {f['y0']}, {f['y1']}        ; {f['name']}")
    t += ["", "; ceiling and floor as VDP commands, for page 0 then page 1: R#36..R#46 of each fill", "bg_cmds:"]
    for page in range(2):
        t.append(f"        dw 0, {256 * page}, 256, {CY}")
        t.append("        db 8, 0, 0xC0")
        t.append(f"        dw 0, {256 * page + CY}, 256, {VIEW_H - CY}")
        t.append("        db 9, 0, 0xC0")
    t += ["", "; sound effects: dw data, db voice ; data: flags|volume, period lo, hi, noise ; FFh ends", "sfx_tab:"]
    for name, voice, data in SFX:
        t.append(f"        dw sfx_{name}")
        t.append(f"        db {voice}")
    for name, voice, data in SFX:
        t += [f"sfx_{name}:", db(data, 4), "        db 255"]
    open(os.path.join(OUT, "inc", "tables.asm"), "w").write("\n".join(t) + "\n")

    # bank 1 tables: objects, doors, monsters
    d = ["; generated by tools/gen_wolf.py - do not edit", "",
         "; objects: cell x, z, frame, kind (0 decoration, else what the pickup gives)", "obj_tab:"]
    for o in objects:
        d.append(f"        db {o[0]}, {o[1]}, {o[2]}, {o[3]}")
    d += ["", "; doors: cell x, z, flags (bit 0: vertical, the plane runs north-south), texture", "door_tab:"]
    for x, z, vert, tex_ in doors:
        d.append(f"        db {x}, {z}, {1 if vert else 0}, {tex_}")
    d += ["", "; monsters at the start: type (0 guard, 1 dog), cell x, z, direction (0 E, 1 N, 2 W, 3 S)", "spawn_enemies:"]
    for e in enemies:
        d.append(f"        db {e[0]}, {e[1]}, {e[2]}, {e[3]}")
    open(os.path.join(OUT, "inc", "level.asm"), "w").write("\n".join(d) + "\n")

    json.dump(dict(kind=kind, val=val, open=OPEN, doors=doors, objects=objects, enemies=enemies, player=player,
                   frames=frames, frame_id=FRAME_ID,
                   lists=[[b"".join(l).hex() for l in (n, s, dr, f)] + [a] for n, s, dr, f, a in lists], stats=st),
              open(os.path.join(OUT, "world.json"), "w"))

    indexed_png(os.path.join(OUT, "preview_tex.png"), 256, 512, tex, pals[0], 2)
    nfaces = len(set().union(*[set(f) for f in faces]))
    print(f"{lv['name']}: {len(OPEN)} open cells, {nfaces} wall faces, {len(doors)} doors, {len(objects)} objects, "
          f"{len(enemies)} monsters (skill {SKILL})")
    print(f"lists: {sum(len(b) for b in banks)} bytes in {len(banks)} banks; ROM {ROM_BANKS * 16} KB")
    print("worst cell:", st)


if __name__ == "__main__":
    main()
