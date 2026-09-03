#!/usr/bin/env python3
"""Convert the mark art Media/*.tga -> Media/*.png, LOSSLESSLY.

PNG is the format most addons ship: the client decodes it natively (it has
supported addon PNGs for many expansions, Classic Era included), and DEFLATE
compresses the glow-on-transparent art far better than raw 32-bit TGA --
without touching a single pixel value.

This is the shipped pipeline as of 0.9.28:
    tools/build_mark_art.py   (writes Media/*.tga)
    tools/tga_to_png.py       (lossless PNG, deletes the TGAs)

Every file is decoded back and compared pixel-for-pixel against the source;
the conversion aborts if any pixel differs. (tools/tga_to_blp.py is the
abandoned BLP experiment -- do not ship its output.)
"""
import os
import sys

import numpy as np
from PIL import Image

MEDIA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Media")


def main():
    keep = "--keep" in sys.argv
    total_before = total_after = 0
    for name in sorted(os.listdir(MEDIA)):
        if not name.endswith(".tga"):
            continue
        src = os.path.join(MEDIA, name)
        img = Image.open(src).convert("RGBA")
        src_arr = np.asarray(img)
        dst = os.path.join(MEDIA, name[:-4] + ".png")
        img.save(dst, "PNG", optimize=True)
        # lossless proof: decode the PNG back and demand pixel equality
        back = np.asarray(Image.open(dst).convert("RGBA"))
        if not np.array_equal(back, src_arr):
            raise SystemExit(f"{name}: PNG round-trip is NOT lossless -- aborting")
        before, after = os.path.getsize(src), os.path.getsize(dst)
        total_before += before
        total_after += after
        print(f"{name:28s} {before:8d} -> {after:7d} B  "
              f"({before / after:5.1f}x)  lossless OK")
        if not keep:
            os.remove(src)
    print(f"\nTOTAL {total_before} -> {total_after} bytes "
          f"({total_before / total_after:.1f}x smaller), every file pixel-identical")


if __name__ == "__main__":
    main()
