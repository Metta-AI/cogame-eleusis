#!/usr/bin/env python3
"""Turn the raw nano-banana renders in scripts/art/source/ into data/*.png.

  cog_violet_sheet.png    -> data/cog_violet_front.png   (chroma-keyed, padded
                             to the same 180x192 box as bullwhip's four cogs)
  bench_surface_sheet.png -> data/bench_surface.png      (tiled 256x256 worktop)

Gemini never returns alpha and the "pure green" it is asked for comes back as
*some* green with a tinted edge, so the key is a flood fill from the image
border against the MEDIAN border colour (corners sometimes carry a smudge).
Flood-filling from the border rather than keying globally means a green pixel
inside the character survives.

    python3 scripts/art/split_art.py
"""

import os
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SOURCE = os.path.join(HERE, "source")
DATA = os.path.join(REPO, "data")

COG_BOX = (180, 192)      # bullwhip's four cog sprites
BENCH_SIZE = 256          # the tile the canvas repeats
TOLERANCE = 62            # per-channel distance that still counts as backdrop


def median_border(image):
    pixels = image.load()
    width, height = image.size
    samples = []
    for x in range(width):
        samples.append(pixels[x, 0][:3])
        samples.append(pixels[x, height - 1][:3])
    for y in range(height):
        samples.append(pixels[0, y][:3])
        samples.append(pixels[width - 1, y][:3])
    return tuple(
        sorted(sample[channel] for sample in samples)[len(samples) // 2]
        for channel in range(3)
    )


def key_out(image, backdrop, tolerance=TOLERANCE):
    """Flood fill the backdrop colour inward from every border pixel."""
    image = image.convert("RGBA")
    pixels = image.load()
    width, height = image.size

    def near(colour):
        return all(abs(colour[c] - backdrop[c]) <= tolerance for c in range(3))

    queue = deque()
    seen = bytearray(width * height)
    for x in range(width):
        queue.append((x, 0))
        queue.append((x, height - 1))
    for y in range(height):
        queue.append((0, y))
        queue.append((width - 1, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= width or y >= height:
            continue
        index = y * width + x
        if seen[index]:
            continue
        seen[index] = 1
        if not near(pixels[x, y]):
            continue
        pixels[x, y] = (0, 0, 0, 0)
        queue.append((x + 1, y))
        queue.append((x - 1, y))
        queue.append((x, y + 1))
        queue.append((x, y - 1))
    return image


def key_enclosed(image, backdrop, tolerance=40):
    """Second pass: backdrop-coloured pixels the border fill could not reach.

    The violet cog carries no green of its own, so a pocket of backdrop the
    flood fill was walled out of (between the arms and the body) is always a
    hole, never art. Tighter tolerance than the border pass so shading is safe.
    """
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            colour = pixels[x, y]
            if colour[3] and all(
                abs(colour[c] - backdrop[c]) <= tolerance for c in range(3)
            ):
                pixels[x, y] = (0, 0, 0, 0)
    return image


def fit_box(image, box):
    """Crop to the opaque content, scale to fit `box`, centre on transparency."""
    bounds = image.getbbox()
    if bounds:
        image = image.crop(bounds)
    scale = min(box[0] / image.width, box[1] / image.height)
    size = (max(1, round(image.width * scale)), max(1, round(image.height * scale)))
    image = image.resize(size, Image.LANCZOS)
    canvas = Image.new("RGBA", box, (0, 0, 0, 0))
    canvas.paste(image, ((box[0] - size[0]) // 2, (box[1] - size[1]) // 2))
    return canvas


def build_cog():
    raw = Image.open(os.path.join(SOURCE, "cog_violet_sheet.png"))
    backdrop = median_border(raw)
    keyed = key_enclosed(key_out(raw, backdrop), backdrop)
    out = os.path.join(DATA, "cog_violet_front.png")
    fit_box(keyed, COG_BOX).save(out)
    print(f"wrote {out}")


def build_bench():
    raw = Image.open(os.path.join(SOURCE, "bench_surface_sheet.png")).convert("RGB")
    side = min(raw.size)
    left = (raw.width - side) // 2
    top = (raw.height - side) // 2
    tile = raw.crop((left, top, left + side, top + side))
    tile = tile.resize((BENCH_SIZE, BENCH_SIZE), Image.LANCZOS)
    out = os.path.join(DATA, "bench_surface.png")
    tile.save(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    build_cog()
    build_bench()
