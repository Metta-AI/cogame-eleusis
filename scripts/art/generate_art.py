#!/usr/bin/env python3
"""Generate the two Eleusis-specific art pieces with nano-banana.

Follows coworld-builder's playbooks/art-nanobanana.md: model
gemini-2.5-flash-image, the key only ever as the `x-goog-api-key` header,
the raw renders committed under scripts/art/source/ so the assets are
reproducible rather than mysterious.

Two pieces are generated here; the other four cog sprites are copied
verbatim from cogame-bullwhip's data/ (MIT, via coworld-ctf):

  cog_violet_front.png  the FIFTH seat's cog, matched to bullwhip's four
                        (chrome.css already reserves .seat4 -> --violet)
  bench_surface.png     the lab-bench worktop the canvas tiles as its
                        background (replaces bullwhip's arena_floor.png)

    GEMINI_API_KEY=... python3 scripts/art/generate_art.py
    python3 scripts/art/split_art.py

The split script is what turns the raw renders into the committed
data/*.png; run it after this one.
"""

import base64
import json
import os
import urllib.request

ENDPOINT = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    "gemini-2.5-flash-image:generateContent"
)
SOURCE = os.path.join(os.path.dirname(__file__), "source")

COG_PROMPT = """Using this robot character ("cog") as the exact character design
reference, draw ONE of these cogs, full body, front-facing, same pose, same size,
same clean cartoon rendering, same chunky wheels and same glowing cyan screen face
with two round eyes and a small smile. The ONLY change: its plating and wheels are
VIOLET / PURPLE (#a86fd6) instead of red, with darker purple (#6f3fa0) shading and
the same lighter highlights. Background: perfectly flat, solid, uniform pure bright
green (#00FF00), no shadows, no gradients, no floor, no ground plane - it will be
chroma-keyed out. No text, no labels, nothing else in frame."""

BENCH_PROMPT = """A seamless, tileable top-down texture of a dark laboratory
workbench surface, 1:1 square. Worn dark charcoal-brown resin worktop
(#241a12 to #16110d), a faint warm paper-cream (#f2e8d8) grid of very thin
scribed measuring lines, a few small scratches, a faint ring stain, and subtle
brushed grain. Very low contrast, very dark, no highlights, no objects, no
equipment, no text, no labels, no glassware, no border, nothing but the surface
itself. Edges must tile seamlessly."""


def generate(prompt, out_name, reference=None):
    parts = []
    if reference:
        parts.append({
            "inline_data": {
                "mime_type": "image/png",
                "data": base64.b64encode(open(reference, "rb").read()).decode(),
            }
        })
    parts.append({"text": prompt})
    body = {
        "contents": [{"parts": parts}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={
            "x-goog-api-key": os.environ["GEMINI_API_KEY"],
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(request) as response:
        payload = json.load(response)
    part = next(
        p for p in payload["candidates"][0]["content"]["parts"] if "inlineData" in p
    )
    os.makedirs(SOURCE, exist_ok=True)
    path = os.path.join(SOURCE, out_name)
    with open(path, "wb") as handle:
        handle.write(base64.b64decode(part["inlineData"]["data"]))
    print(f"wrote {path}")


if __name__ == "__main__":
    repo = os.path.join(os.path.dirname(__file__), "..", "..")
    generate(
        COG_PROMPT,
        "cog_violet_sheet.png",
        reference=os.path.join(repo, "data", "cog_red_front.png"),
    )
    generate(BENCH_PROMPT, "bench_surface_sheet.png")
