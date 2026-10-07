#!/usr/bin/env python3
"""sim.py - the frame the cartridge draws, computed on the PC.

build_frame() is the specification of the Z80 renderer (src/render.asm): the
same integer arithmetic, the same order of vertices and faces. Its output goes
through geo3d's bit-exact reference model (geo3d/sim/gen_scenes.py) and a
SCREEN 8 model of LRMM, so the page it paints is what the hardware paints.

  sim.py x z yaw [out.png]      one frame; x, z in cells, yaw in 1/256 turn
  sim.py --tour                 a set of poses -> out/sim_*.png
tests/compare.py uses render_page() to check the emulator's VRAM.
"""
import json
import os
import sys

from common import *

GEO3D = os.environ.get("GEO3D") or os.path.join(os.path.dirname(MSX), "V9968_Cartridge", "geo3d")
sys.path.insert(0, os.path.join(GEO3D, "sim"))
from gen_scenes import render_faces            # noqa: E402

W = json.load(open(os.path.join(OUT, "world.json")))
KIND, VAL = W["kind"], W["val"]
CELL_IDX = {tuple(c): i for i, c in enumerate(W["open"])}
TEX = open(os.path.join(OUT, "tex.bin"), "rb").read()
HIDDEN = open(os.path.join(OUT, "hidden.bin"), "rb").read()
PALS = open(os.path.join(OUT, "palettes.bin"), "rb").read()
FRAMES = W["frames"]
DOORS = W["doors"]
OBJECTS = W["objects"]
DOOR_OPEN = 252                                # a door at this position or more is not drawn


def mulq14(a, b):
    """(a * b) >> 14 as the Z80 does it: on magnitudes, sign put back after."""
    p = (abs(a) * abs(b)) >> 14
    return -p if (a < 0) != (b < 0) else p


def frac8(num, den):
    """floor(256 * num / den) for 0 <= num < den (8 steps of restoring division)."""
    q = 0
    for _ in range(8):
        num <<= 1
        q <<= 1
        if num >= den:
            num -= den
            q |= 1
    return q


def tex_uv(tex, dark):
    """-> (level, u0): the 64-row band and the column of a wall texture."""
    return tex // 4 + 3 * dark, 64 * (tex % 4)


class Scene:
    def __init__(self):
        self.verts, self.faces, self.uvs = [], [], []

    def vert(self, x, y, z):
        self.verts.append((x, y, z))
        return len(self.verts) - 1

    def pair(self, x, z, y1=WALL_H, y0=0):
        a = self.vert(x, y1, z)
        self.vert(x, y0, z)
        return a

    def face(self, a, b, level, ul, ur, v0=0, v1=63):
        """Top vertices a (left) and b (right); the bottom ones follow them."""
        self.faces.append((a, b, b + 1, a + 1, 0, ny_of(level), 0, 0x80))
        self.uvs.append([ul, v0, ur, v0, ur, v1, ul, v1])


def camera(px, pz, yaw, eye=EYE):
    fx, fz = sin_q14(yaw), -sin_q14(yaw + 64)
    rx, rz = sin_q14(yaw + 64), sin_q14(yaw)
    m = [rx, 0, rz, 0, 16384, 0, fx, 0, fz]
    t = [-(mulq14(rx, px) + mulq14(rz, pz)), -eye, -(mulq14(fx, px) + mulq14(fz, pz))]
    return m, t, (fx, fz, rx, rz)


def cell_lists(cell):
    near, spr, drs, far, areas = W["lists"][cell]
    return bytes.fromhex(near), bytes.fromhex(spr), bytes.fromhex(drs), bytes.fromhex(far), areas


def add_near_static(sc, cell):
    """The walls of the 3 x 3 cells around the cell, each as four strips 64 units wide."""
    near = cell_lists(cell)[0][:64]
    pcx, pcz = W["open"][cell]
    corner, walls = {}, []

    def vtx(i, j):
        if (i, j) not in corner:
            corner[(i, j)] = sc.pair((pcx - 1 + i) * CELL, (pcz - 1 + j) * CELL)
        return corner[(i, j)]

    for k in range(0, len(near), 2):
        b0, b1 = near[k], near[k + 1]
        i, j, d = b0 & 3, (b0 >> 2) & 3, b0 >> 4
        level, u = tex_uv(b1 & 15, b1 >> 4)
        idx = [vtx(i, j), 0, 0, 0, vtx(i + DIRS[d][0], j + DIRS[d][1])]
        ax, az = (pcx - 1 + i) * CELL, (pcz - 1 + j) * CELL
        for n in (1, 2, 3):
            idx[n] = sc.pair(ax + DIRS[d][0] * 64 * n, az + DIRS[d][1] * 64 * n)
        for n in range(4):
            sc.face(idx[n], idx[n + 1], level, u + 16 * n, u + 16 * n + 15)
        walls.append(idx)
    return walls


def door_closed(doors, dep):
    return dep and doors.get(dep - 1, 0) == 0


def add_far(sc, cell, build_yaw, doors):
    """The far faces the bearing test lets through and no closed door hides."""
    far = cell_lists(cell)[3]
    pcx, pcz = W["open"][cell]
    corner = {}

    def vtx(cx, cz):
        if (cx, cz) not in corner:
            assert abs(cx - pcx) <= WIN and abs(cz - pcz) <= WIN
            corner[(cx, cz)] = sc.pair(cx * CELL, cz * CELL)
        return corner[(cx, cz)]

    for k in range(0, len(far), 6):
        ax, az, b2, a0, lim, dep = far[k:k + 6]
        if (build_yaw - a0) % 256 > lim or door_closed(doors, dep):
            continue
        if len(sc.verts) > VMAX_STATIC - 6 or len(sc.faces) > FMAX_STATIC - 2:
            break
        d = b2 & 3
        level, u = tex_uv((b2 >> 2) & 15, (b2 >> 6) & 1)
        a = vtx(ax, az)
        b = vtx(ax + DIRS[d][0], az + DIRS[d][1])
        if b2 & 0x80:                           # two halves, a vertex pair in the middle
            m = sc.pair(ax * CELL + DIRS[d][0] * 128, az * CELL + DIRS[d][1] * 128)
            sc.face(a, m, level, u, u + 31)
            sc.face(m, b, level, u + 32, u + 63)
        else:
            sc.face(a, b, level, u, u + 63)


def add_billboard(sc, frame, x, z, cam):
    fx, fz, rx, rz = cam
    f = FRAMES[frame]
    ox, oz = mulq14(rx, f["halfw"]), mulq14(rz, f["halfw"])
    a = sc.pair(x - ox, z - oz, f["y1"], f["y0"])
    b = sc.pair(x + ox, z + oz, f["y1"], f["y0"])
    v0 = f["sy"] - 64 * 6
    sc.face(a, b, 6, f["u0"], f["u0"] + f["w"] - 1, v0, v0 + f["h"] - 1)


def add_objects(sc, cell, spr_yaw, doors, taken):
    """The objects in sight, as billboards facing spr_yaw (rebuilt when the player turns
    SPR_MARGIN away from it): nearest first, until the budget is full."""
    spr = cell_lists(cell)[1]
    cam = camera(0, 0, spr_yaw)[2]
    for k in range(0, len(spr), 4):
        i, a0, lim, dep = spr[k:k + 4]
        if (spr_yaw - a0) % 256 > lim or door_closed(doors, dep) or i in taken:
            continue
        if len(sc.verts) > VMAX_SPR - 4 or len(sc.faces) > 250:
            break
        ox, oz, fr, _ = OBJECTS[i]
        add_billboard(sc, fr, ox * CELL + 128, oz * CELL + 128, cam)


def zgrid(px, pz, cam):
    fx, fz, rx, rz = cam
    dx0 = -(256 + (px & 255))
    dz0 = -(256 + (pz & 255))
    z00 = mulq14(fx, dx0 * ZSCALE) + mulq14(fz, dz0 * ZSCALE)
    sx, sz = fx >> 1, fz >> 1
    return [[z00 + i * sx + j * sz for j in range(4)] for i in range(4)]


def clip_range(za, zb):
    """The part of a line from A (depth za) to B (zb), 256 long, in front of Z = ZCLIP:
    -> (lo, hi) in 0..256, or None."""
    zc = ZCLIP * ZSCALE
    if za < zc and zb < zc:
        return None
    if za < zc:
        return frac8(zc - za, zb - za) + 1, 256
    if zb < zc:
        return 0, 255 - frac8(zc - zb, za - zb)
    return 0, 256


def add_near(sc, cell, px, pz, zg, walls):
    """For each near wall that crosses Z = ZCLIP, one face from the crossing to the end of
    the strip it falls in (geo3d may have dropped that strip)."""
    near = cell_lists(cell)[0][:64]
    pcx, pcz = px >> 8, pz >> 8
    zc = ZCLIP * ZSCALE
    for w in range(len(near) // 2):
        b0, b1 = near[2 * w], near[2 * w + 1]
        i, j, d = b0 & 3, (b0 >> 2) & 3, b0 >> 4
        level, u = tex_uv(b1 & 15, b1 >> 4)
        za = zg[i][j]
        zb = zg[i + DIRS[d][0]][j + DIRS[d][1]]
        if (za < zc) == (zb < zc):
            continue
        if len(sc.verts) > 253 or len(sc.faces) > 254:
            break
        ax, az = (pcx - 1 + i) * CELL, (pcz - 1 + j) * CELL
        idx = walls[w]
        lo, hi = clip_range(za, zb)
        if za < zc:
            if lo > 255:
                continue
            n = lo >> 6
            a = sc.pair(ax + DIRS[d][0] * lo, az + DIRS[d][1] * lo)
            sc.face(a, idx[n + 1], level, u + (lo >> 2), u + 16 * n + 15)
        else:
            if hi < 1:
                continue
            n = (hi - 1) >> 6
            b = sc.pair(ax + DIRS[d][0] * hi, az + DIRS[d][1] * hi)
            sc.face(idx[n], b, level, u + 16 * n, u + ((hi - 1) >> 2))


def add_doors(sc, cell, px, pz, yaw, zg, doors):
    """The doors in sight that are not fully open: one face each, from the door's edge (it
    slides south or east into the wall) to the end of its cell."""
    drs = cell_lists(cell)[2]
    pcx, pcz = px >> 8, pz >> 8
    for k in range(0, len(drs), 4):
        n, a0, lim, dep = drs[k:k + 4]
        pos = doors.get(n, 0)
        if (yaw - a0) % 256 > lim or door_closed(doors, dep) or pos >= DOOR_OPEN:
            continue
        if len(sc.verts) > 251 or len(sc.faces) > 254:
            break
        dx, dz, vert, tex = DOORS[n]
        lo, hi = pos, 256
        i, j = dx - (pcx - 1), dz - (pcz - 1)
        if 0 <= i <= 2 and 0 <= j <= 2:         # near: cut at Z = ZCLIP
            if vert:
                za, zb = (zg[i][j] >> 1) + (zg[i + 1][j] >> 1), (zg[i][j + 1] >> 1) + (zg[i + 1][j + 1] >> 1)
            else:
                za, zb = (zg[i][j] >> 1) + (zg[i][j + 1] >> 1), (zg[i + 1][j] >> 1) + (zg[i + 1][j + 1] >> 1)
            r = clip_range(za, zb)
            if r is None:
                continue
            lo, hi = max(lo, r[0]), min(hi, r[1])
            if lo >= hi:
                continue
        level, u = tex_uv(tex, 1 if vert else 0)
        ulo, uhi = u + ((lo - pos) >> 2), u + ((hi - 1 - pos) >> 2)
        if vert:
            x = dx * CELL + 128
            plo, phi = (x, dz * CELL + lo), (x, dz * CELL + hi)
            first_lo = px < x                   # seen from the west, the north end is on the left
        else:
            z = dz * CELL + 128
            plo, phi = (dx * CELL + lo, z), (dx * CELL + hi, z)
            first_lo = pz > z                   # seen from the south, the west end is on the left
        if first_lo:
            a = sc.pair(*plo)
            b = sc.pair(*phi)
            sc.face(a, b, level, ulo, uhi)
        else:
            a = sc.pair(*phi)
            b = sc.pair(*plo)
            sc.face(a, b, level, uhi, ulo)


def area_seen(cell, x, z):
    """Is a monster at (x, z) drawn? Its area must be in sight of the player's cell."""
    cx, cz = x >> 8, z >> 8
    pcx, pcz = W["open"][cell]
    if abs(cx - pcx) > WIN or abs(cz - pcz) > WIN:
        return False
    if KIND[cz][cx] == G_DOOR:
        return True
    a = VAL[cz][cx]
    return a < 37 and bool(cell_lists(cell)[4] & (1 << a))


def build_frame(px, pz, yaw, sprites=(), doors=None, taken=(), build_yaw=None, spr_yaw=None, eye=EYE):
    """px, pz: world units; sprites: (frame, x, z) of the monsters and loose items;
    doors: {door: position 0..255}. -> (cfg, Scene)"""
    doors = doors or {}
    cell = CELL_IDX[(px >> 8, pz >> 8)]
    m, t, cam = camera(px, pz, yaw, eye)
    sc = Scene()
    walls = add_near_static(sc, cell)
    add_far(sc, cell, yaw if build_yaw is None else build_yaw, doors)
    add_objects(sc, cell, yaw if spr_yaw is None else spr_yaw, doors, set(taken))
    zg = zgrid(px, pz, cam)
    add_near(sc, cell, px, pz, zg, walls)
    add_doors(sc, cell, px, pz, yaw, zg, doors)
    for fr, x, z in sprites:
        if len(sc.verts) > 251 or len(sc.faces) > 254:
            break
        if area_seen(cell, x, z):
            add_billboard(sc, fr, x, z, cam)
    assert len(sc.verts) <= 255 and len(sc.faces) <= 255, (len(sc.verts), len(sc.faces))
    return m + t + [FOCAL, CX, CY, ZNEAR, VIEW_W, VIEW_H], sc


def paint(vram, cmds):
    """LRMM spans (19 bytes) into a SCREEN 8 VRAM of 1024 rows."""
    for c in cmds:
        assert len(c) == 19
        sx = (c[0] | (c[1] << 8)) << 8
        sy = (c[2] | (c[3] << 8)) << 8
        dx, dy = c[4] | (c[5] << 8), c[6] | (c[7] << 8)
        nx = c[8] | (c[9] << 8)
        vx = c[14] | (c[15] << 8)
        vy = c[16] | (c[17] << 8)
        vx -= 65536 if vx & 0x8000 else 0
        vy -= 65536 if vy & 0x8000 else 0
        timp = c[18] & 8
        for _ in range(nx):
            src = vram[(((sy >> 8) & 0x3FF) << 8) | ((sx >> 8) & 0xFF)]
            if not (timp and src == 0):
                vram[((dy & 0x3FF) << 8) | (dx & 0xFF)] = src
            dx += 1
            if dx > 255:
                break
            sx = (sx + vx) & 0xFFFFF
            sy = (sy + vy) & 0x1FFFFF


def render_page(px, pz, yaw, sprites=(), doors=None, taken=(), weapon=0, gun_y=0, **kw):
    """-> (the 256 x 180 view as bytes, statistics). weapon: pistol frame, or None."""
    cfg, sc = build_frame(px, pz, yaw, sprites, doors, taken, **kw)
    vram = bytearray(256 * 1024)
    vram[TEXY * 256:] = TEX
    vram[PISTOL_ROW * 256:(PISTOL_ROW + 44) * 256] = HIDDEN
    for y in range(VIEW_H):
        vram[y * 256:(y + 1) * 256] = bytes([8 if y < CY else 9]) * 256
    tex = dict(on=True, texx=0, texy=TEXY, tstride=TSTRIDE, uv=sc.uvs)
    cmds, skip, draw, cull = render_faces(cfg, sc.verts, sc.faces, 8, 0, [0, 16384, 0], tex)
    paint(vram, cmds)
    if weapon is not None:                      # two LMMM + TIMP copies of 44 rows
        top = VIEW_H - 76 + gun_y
        for y in range(88):
            if top + y >= VIEW_H:
                break
            for x in range(64):
                p = vram[(PISTOL_ROW + y % 44) * 256 + 128 * weapon + 64 * (y // 44) + x]
                if p:
                    vram[(top + y) * 256 + 96 + x] = p
    stats = dict(verts=len(sc.verts), faces=len(sc.faces), skip=skip, draw=draw, cull=cull,
                 spans=len(cmds), texels=sum(c[8] | (c[9] << 8) for c in cmds))
    return bytes(vram[:256 * VIEW_H]), stats


def palette(n=0):
    return [tuple(PALS[n * 768 + 3 * i:n * 768 + 3 * i + 3]) for i in range(256)]


def start_sprites():
    """The monsters where the level puts them, standing."""
    return [(W["frame_id"]["guard_stand"] if e[0] == 0 else W["frame_id"]["dog_run1"],
             e[1] * CELL + 128, e[2] * CELL + 128) for e in W["enemies"]]


def main():
    args = sys.argv[1:]
    if args and args[0] == "--tour":
        p = W["player"]
        poses = [(p[0] + 0.5, p[1] + 0.5, p[2], "start"), (33.5, 55.5, 0, "hall"), (34.5, 50.5, 0, "door"),
                 (34.5, 34.5, 192, "bigroom"), (37.5, 33.5, 64, "bigroom2"), (10.5, 46.5, 64, "wood"),
                 (30.5, 11.5, 64, "woodroom"), (47.5, 33.5, 64, "blue"), (34.3, 31.2, 16, "close")]
        for x, z, yaw, name in poses:
            page, st = render_page(int(x * 256), int(z * 256), yaw, start_sprites())
            indexed_png(os.path.join(OUT, f"sim_{name}.png"), 256, VIEW_H, page, palette(), 2)
            print(name, st)
        return
    x, z, yaw = float(args[0]), float(args[1]), int(args[2])
    out = args[3] if len(args) > 3 else os.path.join(OUT, "sim.png")
    page, st = render_page(int(x * 256), int(z * 256), yaw, start_sprites())
    indexed_png(out, 256, VIEW_H, page, palette(), 2)
    print(st)


if __name__ == "__main__":
    main()
