#!/usr/bin/env python3
"""EXPERIMENTAL -- DO NOT SHIP THE OUTPUT (as of 0.9.27).

Both hand-rolled containers failed on the user's 1.15.9 client: BLP1 showed
neon-green "unreadable texture" squares, and the BLP2/DXT5 rewrite did not
render either. The addon ships the uncompressed 32-bit TGAs instead; the
docs test enforces that. This tool stays as a reference/experiment only --
if you ever make it render in-game, update tests/test_docs.lua first.

Convert the mark art Media/*.tga -> Media/*.blp (BLP2 / DXT5), losslessly
for anything DXT5 can represent exactly and visually-lossless otherwise.

WHY: the shipped art is uncompressed 32-bit TGA (6.2 MB). BLP+DXT5 is the
container/compression Blizzard's own client files use: 4x smaller, hardware
native, and the classic client reads it from addons exactly like Blizzard
reads its own UI art. TGA's RLE mode would have been the lossless win, but
it is known broken on this pipeline/client (tested earlier -- do not retry).

DXT5 (BC3) stores each 4x4 block as:
  * an 8-byte alpha block: two endpoint alphas + 6 interpolated values,
    3-bit nearest-match index per pixel;
  * an 8-byte colour block: two RGB565 endpoints + 2 interpolated colours,
    2-bit nearest-match index per pixel (endpoints refined with two Lloyd
    iterations for gradient quality).
Every file is decoded straight back after encoding and measured against the
source (PSNR / max channel error) -- the numbers are printed, nothing is
claimed that wasn't measured.

Usage:  python3 tools/tga_to_blp.py            # convert + verify + replace
        python3 tools/tga_to_blp.py --keep     # also keep the .tga sources
"""
import os
import struct
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA = os.path.join(ROOT, "Media")


# --------------------------------------------------------------------------
# DXT5 (BC3) encoder
# --------------------------------------------------------------------------
def _pack_alpha_block(alphas):
    """alphas: (16,) uint8 -> 8 bytes."""
    a0 = int(alphas.max())
    a1 = int(alphas.min())
    if a0 == a1:
        return bytes([a0, a1]) + b"\x00" * 6
    # BC3 ramp: idx0=a0, idx1=a1, idx2..7 = ((7-k)*a0 + k*a1)/7 for k=1..6
    ramp = np.array(
        [a0, a1] + [int(round(((7 - k) * a0 + k * a1) / 7.0)) for k in range(1, 7)],
        dtype=np.int32,
    )
    idx = np.abs(alphas.astype(np.int32)[:, None] - ramp[None, :]).argmin(axis=1)
    bits = 0
    for p in range(16):
        bits |= int(idx[p]) << (3 * p)
    return bytes([a0, a1]) + bits.to_bytes(6, "little")


def _q565(c):
    """Expand an 8-bit RGB triple through its 565 quantisation."""
    r, g, b = int(c[0]) >> 3, int(c[1]) >> 2, int(c[2]) >> 3
    return np.array([(r << 3) | (r >> 2), (g << 2) | (g >> 1), (b << 3) | (b >> 2)],
                    dtype=np.int32)


def _w565(c):
    return ((int(c[0]) >> 3) << 11) | ((int(c[1]) >> 2) << 5) | (int(c[2]) >> 3)


def _pack_color_block(px):
    """px: (16,3) int32 -> 8 bytes (RGB565 endpoints + 2-bit indices).

    Endpoint fitting: assign indices, then solve the EXACT least-squares
    endpoints for that assignment (2x2 normal equations per channel -- the
    interpolated colours are c0, 2/3c0+1/3c1, 1/3c0+2/3c1, c1, so each pixel
    is linear in (c0,c1)), requantise through 565, repeat. Two seeds
    (min/max and mean +/- 2 stdev) are fitted and the lower-error result is
    packed -- that combination is what keeps smooth glow gradients clean.
    """
    def fit(e0, e1):
        for _ in range(6):
            cols = np.stack([e0, (2 * e0 + e1 + 1) // 3, (e0 + 2 * e1 + 1) // 3, e1])
            d2 = ((px[:, None, :] - cols[None, :, :]) ** 2).sum(axis=2)
            idx = d2.argmin(axis=1)
            w0 = np.where(idx == 0, 1.0, np.where(idx == 1, 2 / 3,
                           np.where(idx == 2, 1 / 3, 0.0)))
            w1 = 1.0 - w0
            a = (w0 * w0).sum(); b = (w0 * w1).sum(); c = (w1 * w1).sum()
            det = a * c - b * b
            if abs(det) < 1e-9:
                break
            n0, n1 = [], []
            for ch in range(3):
                d0 = (w0 * px[:, ch]).sum(); d1 = (w1 * px[:, ch]).sum()
                n0.append((c * d0 - b * d1) / det)
                n1.append((a * d1 - b * d0) / det)
            ne0 = _q565(np.clip(np.array(n0), 0, 255))
            ne1 = _q565(np.clip(np.array(n1), 0, 255))
            if _w565(ne0) < _w565(ne1):
                ne0, ne1 = ne1, ne0
            if (ne0 == e0).all() and (ne1 == e1).all():
                break
            e0, e1 = ne0, ne1
        cols = np.stack([e0, (2 * e0 + e1 + 1) // 3, (e0 + 2 * e1 + 1) // 3, e1])
        idx = ((px[:, None, :] - cols[None, :, :]) ** 2).sum(axis=2).argmin(axis=1)
        sse = float(((px - cols[idx]) ** 2).sum())
        return e0, e1, idx, sse

    seeds = []
    pmin = px.min(axis=0)
    pmax = px.max(axis=0)
    s0, s1 = _q565(pmax), _q565(pmin)
    if _w565(s0) < _w565(s1):
        s0, s1 = s1, s0
    seeds.append((s0, s1))
    mean = px.mean(axis=0)
    std = px.std(axis=0) + 1e-6
    m0 = _q565(np.clip(mean + 2 * std, 0, 255))
    m1 = _q565(np.clip(mean - 2 * std, 0, 255))
    if _w565(m0) < _w565(m1):
        m0, m1 = m1, m0
    seeds.append((m0, m1))

    best = None
    for seed in seeds:
        r = fit(*seed)
        if best is None or r[3] < best[3]:
            best = r
    e0, e1, idx, _ = best
    w0, w1 = _w565(e0), _w565(e1)
    if w0 < w1:  # keep 4-colour mode: c0 >= c1; swapping mirrors the indices
        w0, w1 = w1, w0
        idx = 3 - idx
    bits = 0
    for p in range(16):
        bits |= int(idx[p]) << (2 * p)
    return struct.pack("<HHI", w0, w1, bits)


def dxt5_encode(rgba):
    """rgba: HxWx4 uint8 (H,W % 4 == 0) -> bytes."""
    h, w, _ = rgba.shape
    blocks = (rgba.reshape(h // 4, 4, w // 4, 4, 4)
                  .transpose(0, 2, 1, 3, 4).reshape(-1, 16, 4))
    out = bytearray()
    for blk in blocks:
        a = blk[:, 3]
        out += _pack_alpha_block(a)
        if int(a.max()) == 0:
            out += b"\x00" * 8  # fully transparent block: colour is irrelevant
        else:
            out += _pack_color_block(blk[:, :3].astype(np.int32))
    return bytes(out)


# --------------------------------------------------------------------------
# DXT5 decoder (verification only)
# --------------------------------------------------------------------------
def dxt5_decode(data, w, h):
    img = np.zeros((h, w, 4), dtype=np.uint8)
    pos = 0
    for by in range(h // 4):
        for bx in range(w // 4):
            a0, a1 = data[pos], data[pos + 1]
            abits = int.from_bytes(data[pos + 2:pos + 8], "little")
            pos += 8
            c0, c1, cbits = struct.unpack("<HHI", data[pos:pos + 8])
            pos += 8
            if a0 > a1:
                ramp = [a0, a1] + [((7 - k) * a0 + k * a1 + 3) // 7 for k in range(1, 7)]
            else:
                ramp = [a0, a1] + [((5 - k) * a0 + k * a1 + 2) // 5 for k in range(1, 5)] + [0, 255]

            def un565(v):
                r = (v >> 11) & 31
                g = (v >> 5) & 63
                b = v & 31
                return ((r << 3) | (r >> 2), (g << 2) | (g >> 1), (b << 3) | (b >> 2))

            e0, e1 = np.array(un565(c0), np.int32), np.array(un565(c1), np.int32)
            cols = [e0, (2 * e0 + e1 + 1) // 3, (e0 + 2 * e1 + 1) // 3, e1]
            for p in range(16):
                py, px = by * 4 + p // 4, bx * 4 + p % 4
                ai = (abits >> (3 * p)) & 7
                ci = (cbits >> (2 * p)) & 3
                img[py, px, :3] = cols[ci]
                img[py, px, 3] = ramp[ai]
    return img


# --------------------------------------------------------------------------
# BLP2 container (DXT flavour)
# --------------------------------------------------------------------------
# BLP2 -- NOT BLP1. BLP1 is the 2004-vanilla container; the Classic Era
# client (1.15, modern texture pipeline) cannot decode it and renders the
# bright-green "unreadable texture" placeholder. That was the "neon green
# squares" bug of 0.9.21-0.9.25. The DXT5 payload is byte-identical between
# the two containers; only this header differs.
def blp2_dxt5(rgba):
    h, w, _ = rgba.shape
    data = dxt5_encode(rgba)
    # magic, compression=2 (DXT), alphaDepth=8, alphaEncoding=7 (DXT5),
    # hasMips=0, width, height
    header = struct.pack("<4sIIIIII", b"BLP2", 2, 8, 7, 0, w, h)
    header += struct.pack("<16I", 156, *([0] * 15))           # mip0 offset
    header += struct.pack("<16I", len(data), *([0] * 15))     # mip0 size
    assert len(header) == 156, len(header)
    return header + data


def main():
    keep = "--keep" in sys.argv
    total_before = total_after = 0
    worst = None
    for name in sorted(os.listdir(MEDIA)):
        if not name.endswith(".tga"):
            continue
        src = os.path.join(MEDIA, name)
        img = Image.open(src).convert("RGBA")
        w, h = img.size
        assert w % 4 == 0 and h % 4 == 0, (name, w, h)
        rgba = np.asarray(img)
        blob = blp2_dxt5(rgba)
        back = dxt5_decode(blob[156:], w, h)
        err = np.abs(back.astype(np.int32) - rgba.astype(np.int32))
        mse = float((err.astype(np.float64) ** 2).mean())
        psnr = 99.0 if mse == 0 else 10.0 * float(np.log10(255.0 * 255.0 / mse))
        # alpha-weighted error matters most for glow art: also report the
        # worst error among pixels the player actually sees (alpha >= 16).
        visible = rgba[:, :, 3] >= 16
        vmax = int(err[:, :, 3][visible].max()) if visible.any() else 0
        cmax = int(err[:, :, :3][visible].max()) if visible.any() else 0
        dst = os.path.join(MEDIA, name[:-4] + ".blp")
        with open(dst, "wb") as fh:
            fh.write(blob)
        before, after = os.path.getsize(src), os.path.getsize(dst)
        total_before += before
        total_after += after
        print(f"{name:28s} {before:8d} -> {after:7d} B  "
              f"({before / after:4.1f}x)  PSNR {psnr:5.1f} dB  "
              f"max err rgb {cmax:3d} / a {vmax:3d} (visible px)")
        if worst is None or psnr < worst[1]:
            worst = (name, psnr)
        if not keep:
            os.remove(src)
    print(f"\nTOTAL {total_before} -> {total_after} bytes "
          f"({total_before / total_after:.1f}x smaller); worst PSNR {worst[1]:.1f} dB ({worst[0]})")


if __name__ == "__main__":
    main()
