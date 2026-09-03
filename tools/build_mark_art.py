#!/usr/bin/env python3
"""Convert generated reticle PNGs (white glow on black) into white-on-alpha .tga
mark textures for HunterKit.

The source images are luminance-keyed: black becomes fully transparent and the
bright mark becomes opaque white, so the in-game `SetVertexColor` can tint them
per range state. Content is cropped to the mark, padded to a square and resized
to 256px so every style frames identically.

Usage: python3 tools/build_mark_art.py
Re-run after dropping new PNGs into art/ and extending MAP.
"""
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ART = os.path.join(ROOT, "art")
MEDIA = os.path.join(ROOT, "Media")

# (source png in art/, output tga in Media/)
MAP = [
    ("ok-reticle.png", "mark-ok-reticle.tga"),
    ("ok-chevrons.png", "mark-ok-chevrons.tga"),
    ("ok-diamond.png", "mark-ok-diamond.tga"),
    ("ok-ticks.png", "mark-ok-ticks.tga"),
    ("trial-dead.png", "mark-dead-hexx.tga"),
    ("dead-cross.png", "mark-dead-cross.tga"),
    ("dead-block.png", "mark-dead-block.tga"),
    ("dead-bars.png", "mark-dead-bars.tga"),
    ("dead-burst.png", "mark-dead-burst.tga"),
    ("far-dashring.png", "mark-far-dashring.tga"),
    ("far-hollow.png", "mark-far-hollow.tga"),
    ("far-sides.png", "mark-far-sides.tga"),
    ("far-slashes.png", "mark-far-slashes.tga"),
    ("far-halo.png", "mark-far-halo.tga"),
    ("ok-plus.png", "mark-ok-plus.tga"),
    ("far-ban.png", "mark-far-ban.tga"),
]

SIZE = 256


def convert(src, dst):
    im = Image.open(src).convert("RGBA")
    r, g, b, _ = im.split()
    # alpha = luminance of the glow; output is pure white so the game can tint it
    from PIL import ImageChops
    lum = ImageChops.lighter(ImageChops.lighter(
        r.point(lambda v: int(v * 0.30)),
        g.point(lambda v: int(v * 0.59))),
        b.point(lambda v: int(v * 0.11)))
    # strengthen: crush near-black noise, then gamma-boost the glow so strokes
    # are solid white in-game instead of a faint wash (ADD blend uses alpha as
    # intensity, so mid-grey alpha read as "barely visible").
    lum = lum.point(lambda v: 0 if v < 8 else min(255, int(255 * ((v / 255.0) ** 0.55))))
    white = Image.new("L", im.size, 255)
    out = Image.merge("RGBA", (white, white, white, lum))

    bbox = out.getbbox()
    if bbox:
        out = out.crop(bbox)
    w, h = out.size
    side = max(w, h)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(out, ((side - w) // 2, (side - h) // 2), out)
    out = square.resize((SIZE, SIZE), Image.LANCZOS)

    os.makedirs(os.path.dirname(dst), exist_ok=True)
    # Classic Era reliably reads only UNCOMPRESSED (type 2) 32-bit RGBA TGA -- the
    # bundled originals are exactly that. RLE (type 10) decodes to a broken
    # mosaic in-client, so never compress.
    out.save(dst, "TGA", rle=False)
    return out


def main():
    made = []
    for src, name in MAP:
        s = os.path.join(ART, src)
        if not os.path.exists(s):
            print("skip (missing) %s" % src)
            continue
        d = os.path.join(MEDIA, name)
        convert(s, d)
        made.append((name, os.path.getsize(d) // 1024))
    for name, kb in made:
        print("wrote Media/%s  %dKB" % (name, kb))
    # a human-viewable composite over mid-grey to sanity-check legibility
    prev = os.path.join(ART, "preview.png")
    thumbs = []
    for src, name in MAP:
        d = os.path.join(MEDIA, name)
        if os.path.exists(d):
            thumbs.append(Image.open(d).convert("RGBA"))
    if thumbs:
        n = len(thumbs)
        cols = min(6, n)
        rows = (n + cols - 1) // cols
        cell = 96
        # composite ADDITIVELY over the grey, exactly like the in-game ADD blend,
        # so the preview predicts what the client will show.
        canvas = Image.new("RGB", (cols * cell, rows * cell), (60, 60, 66))
        layer = Image.new("RGB", canvas.size, (0, 0, 0))
        for i, t in enumerate(thumbs):
            x = (i % cols) * cell
            y = (i // cols) * cell
            a = t.resize((cell, cell)).split()[3]
            layer.paste(Image.merge("RGB", (a, a, a)), (x, y))
        from PIL import ImageChops as IC
        IC.add(canvas, layer).save(prev)
        print("preview -> %s" % prev)


if __name__ == "__main__":
    main()
