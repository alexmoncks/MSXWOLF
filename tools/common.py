#!/usr/bin/env python3
"""Shared constants and helpers of the MSX WOLF build tools (pure Python 3, no packages)."""
import math
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
MSX = os.path.dirname(HERE)
OUT = os.path.join(MSX, "out")

# ---------------------------------------------------------------- the target
MAP_W = MAP_H = 64
CELL = 256              # world units per map cell (a wall texel is 4 units)
EYE = 128
WALL_H = 256
VIEW_W, VIEW_H = 256, 180
FOCAL = 128             # geo3d F: 90 degrees across 256 pixels
CX, CY = 128, 90
ZNEAR = 2               # geo3d ZNEAR (the Z80 patches the near walls itself, at ZCLIP)
ZCLIP = 16
ZSCALE = 32             # the Z80 keeps those Z values times 32
SPLIT_DIST = 3.2        # far faces closer than this (cells) are sent as two halves
TEXY = 512              # the texture area: VRAM rows 512..1023 (SCREEN 8 pages 2 and 3)
TSTRIDE = 64            # geo3d's "light level" 0..6 picks the 64-row band of the texture
FOV_HALF = 32           # half the horizontal field of view, in 1/256 of a turn
YAW_MARGIN = 24         # the loaded far faces cover the build yaw +- this much turning
SPR_MARGIN = 8          # the loaded object billboards face the build yaw +- this much
DRAW_DIST = 12          # view range in cells
WIN = 13                # corners are mapped in a window of +-WIN cells around the player
VMAX_STATIC = 156       # vertices the near strips and the far faces may take (of geo3d's 255)
FMAX_STATIC = 110
VMAX_SPR = 200          # ... and with the object billboards after them
PISTOL_ROW = 468        # the pistol frames: the rows of page 1 that are never shown

DIRS = [(1, 0), (-1, 0), (0, 1), (0, -1)]       # face direction A -> B and step codes: +x -x +z -z

# grid byte: kind in bits 7-6, the rest in bits 5-0
G_FLOOR, G_BLOCK, G_DOOR, G_WALL = 0x00, 0x40, 0x80, 0xC0
AREA_EXIT = 63          # floor of the elevator: stepping on it ends the level


def write_png(path, w, h, rgb):
    raw = b"".join(b"\0" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def indexed_png(path, w, h, pix, pal, scale=1):
    """pix: one palette index per pixel; pal: 256 x (r, g, b) 5-bit."""
    lut = [bytes(((c << 3) | (c >> 2)) for c in e) for e in pal]
    out = bytearray()
    for y in range(h):
        row = b"".join(lut[pix[y * w + x]] * scale for x in range(w))
        out += row * scale
    write_png(path, w * scale, h * scale, bytes(out))


def sin_q14(a):
    return int(round(math.sin(2 * math.pi * (a & 255) / 256) * 16384))


def ny_of(level):
    """The normal's Y that makes geo3d pick `level` (0..6) under the light (0, 1, 0)."""
    return 0 if level == 0 else level * 2341 + 100
