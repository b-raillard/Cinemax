#!/usr/bin/env python3
"""Recolour the Cinemax app icon without redrawing it.

Only the HUE of the jellyfish changes: its shapes, highlights, shading and glow
are the original pixels, and the neutral ground is left untouched (verified:
background pixels are byte-identical, except in the explicit « fond aubergine »
variant).

    python3 design/logo-variantes/recolor.py            # regenerates every PNG here

Needs Pillow + numpy. Source: Resources/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png.

How it works
- The original glow runs from green (hue ~150°, tentacles / diaphragm) to blue
  (hue ~200°, bell). `t` = where a pixel sits on that gradient (0 green → 1 blue).
- A pixel is recoloured only if it is saturated (s > 0.12, full weight at 0.25)
  and inside the glow's hue band (110°–245°), with soft edges so the halo blends.
- Accent variants: the gradient is re-centred on the accent's hue (the app's
  dark-theme `accentDark` in `AccentOption.swift`) and compressed to ±~17°, so it
  reads as one colour but keeps a soft two-tone depth.
- Halloween variants: t=0 and t=1 are mapped to the « Nuit d'Halloween » theme's
  Citrouille #FF7A1A and Potion #A57BFF, going round the hue wheel through
  magenta/red (the way the original goes through cyan).
"""
import colorsys
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(ROOT, "Resources/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png")

# AccentOption.swift — accentDark (the hue the app shows on its dark theme).
ACCENTS = {
    "rouge": 0xFF6B6B, "orange": 0xFF8C42, "jaune": 0xFFC940, "vert": 0x4CAF82, "cyan": 0x2DD4BF,
    "bleu": 0x679CFF, "indigo": 0x818CF8, "violet": 0xBF7FFF, "rose": 0xFF6BB5,
}
CITROUILLE = 0xFF7A1A  # Halloween theme accent
POTION = 0xA57BFF      # Halloween theme accent 2
# Halloween surfaces, darkest → lightest: Nuit, Crypte, Caveau, Tombe.
AUBERGINE = [0x0C0A10, 0x15111C, 0x1D1726, 0x262033]

ACCENT_CENTER = 177.0   # centre of the original green→blue gradient, in degrees
ACCENT_SPREAD = 0.45    # how much of the original hue spread the accent variants keep


def hex_rgb(x):
    return ((x >> 16) & 255) / 255, ((x >> 8) & 255) / 255, (x & 255) / 255


def hex_hsv(x):
    return colorsys.rgb_to_hsv(*hex_rgb(x))


def rgb_to_hsv(rgb):
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx, mn = rgb.max(-1), rgb.min(-1)
    d = mx - mn
    nz = d > 1e-9
    dd = np.maximum(d, 1e-9)
    rc, gc, bc = (mx - r) / dd, (mx - g) / dd, (mx - b) / dd
    h = np.where(r == mx, bc - gc, np.where(g == mx, 2 + rc - bc, 4 + gc - rc))
    h = np.where(nz, (h / 6) % 1.0, 0)
    s = np.where(mx > 0, d / np.maximum(mx, 1e-9), 0)
    return h * 360, s, mx


def hsv_to_rgb(h, s, v):
    i = np.floor(h * 6).astype(int) % 6
    f = h * 6 - np.floor(h * 6)
    p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    c = [i == k for k in range(6)]
    return np.stack([np.select(c, [v, q, p, p, t, v]),
                     np.select(c, [t, v, v, q, p, p]),
                     np.select(c, [p, p, t, v, v, q])], -1)


def to_image(arr):
    return Image.fromarray((np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8))


def main():
    src_img = Image.open(SOURCE).convert("RGB")
    rgb = np.array(src_img).astype(np.float64) / 255
    H, S, V = rgb_to_hsv(rgb)
    glow = (np.clip((S - 0.12) / 0.13, 0, 1)
            * np.clip(1 - np.maximum(np.maximum(110 - H, 0), np.maximum(H - 245, 0)) / 15, 0, 1))[..., None]
    t = np.clip((H - 150) / 50, 0, 1)  # 0 = original green, 1 = original blue

    def blend(recoloured):
        return rgb * (1 - glow) + recoloured * glow

    outputs = {}

    # 1. One variant per theme accent.
    for name, hexv in ACCENTS.items():
        accent_h = hex_hsv(hexv)[0] * 360
        nh = ((accent_h + (H - ACCENT_CENTER) * ACCENT_SPREAD) % 360) / 360
        outputs[f"accent/cinemax_icone_{name}.png"] = blend(hsv_to_rgb(nh, S, V))

    # 2. Halloween: bell / tentacles in Citrouille / Potion.
    orange_h = hex_hsv(CITROUILLE)[0] * 360          # ~25°
    potion_h, potion_s, _ = hex_hsv(POTION)          # ~259°, s ~0.52
    potion_h *= 360
    potion_sat = potion_s / 0.9 if potion_s < 0.9 else 1.0

    # A: tentacles (t=0) potion → bell (t=1) citrouille, via magenta/red.
    h0, h1 = potion_h, orange_h + 360
    nh = ((h0 + (h1 - h0) * t) % 360) / 360
    halloween_a = blend(hsv_to_rgb(nh, np.clip(S * np.interp(t, [0, 1], [potion_sat, 1.0]), 0, 1), V))
    outputs["halloween/cinemax_icone_halloween_cloche-citrouille_tentacules-potion.png"] = halloween_a

    # B: the reverse — tentacles citrouille, bell potion.
    h0, h1 = orange_h + 360, potion_h
    nh = ((h0 + (h1 - h0) * t) % 360) / 360
    outputs["halloween/cinemax_icone_halloween_cloche-potion_tentacules-citrouille.png"] = blend(
        hsv_to_rgb(nh, np.clip(S * np.interp(t, [0, 1], [1.0, 0.62]), 0, 1), V))

    # A + aubergine ground: only the dark neutral ground (never the white outer corners).
    ground = np.clip((0.12 - S) / 0.04, 0, 1) * np.clip((0.40 - V) / 0.10, 0, 1)
    lum = rgb.mean(-1)
    ramp = np.array([hex_rgb(x) for x in AUBERGINE])
    base = np.stack([np.interp(lum, [0.04, 0.08, 0.14, 0.20], ramp[:, c]) for c in range(3)], -1)
    base = base * (lum / np.maximum(base.mean(-1), 1e-6))[..., None]  # keep the original light falloff
    outputs["halloween/cinemax_icone_halloween_cloche-citrouille_tentacules-potion_fond-aubergine.png"] = (
        halloween_a * (1 - ground[..., None]) + base * ground[..., None])

    images = {}
    for rel, arr in outputs.items():
        path = os.path.join(HERE, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        img = to_image(arr)
        img.save(path, optimize=True)
        images[rel] = img

    # Contact sheets.
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 20)
    except OSError:
        font = ImageFont.load_default()

    def sheet(items, cols, tile, name, bg):
        pad, label_h = 24, 56
        rows = (len(items) + cols - 1) // cols
        out = Image.new("RGB", (cols * (tile + pad) + pad, rows * (tile + pad + label_h) + pad), bg)
        draw = ImageDraw.Draw(out)
        for k, (label, img) in enumerate(items):
            x = pad + (k % cols) * (tile + pad)
            y = pad + (k // cols) * (tile + pad + label_h)
            out.paste(img.resize((tile, tile), Image.LANCZOS), (x, y))
            for j, line in enumerate(label.split("\n")):
                w = draw.textlength(line, font=font)
                draw.text((x + (tile - w) / 2, y + tile + 8 + j * 24), line, fill=(236, 232, 228), font=font)
        out.save(os.path.join(HERE, name), optimize=True)

    sheet([("actuelle", src_img)] + [(n, images[f"accent/cinemax_icone_{n}.png"]) for n in ACCENTS],
          5, 300, "apercu_accents.png", (18, 18, 20))
    sheet([("actuelle", src_img),
           ("A · cloche citrouille\ntentacules potion",
            images["halloween/cinemax_icone_halloween_cloche-citrouille_tentacules-potion.png"]),
           ("B · cloche potion\ntentacules citrouille",
            images["halloween/cinemax_icone_halloween_cloche-potion_tentacules-citrouille.png"]),
           ("A + fond aubergine",
            images["halloween/cinemax_icone_halloween_cloche-citrouille_tentacules-potion_fond-aubergine.png"])],
          4, 360, "apercu_halloween.png", (12, 10, 16))

    # Guard: the accent variants must leave the ground untouched.
    ground_mask = S < 0.1
    for rel, img in images.items():
        if rel.startswith("accent/"):
            diff = np.abs(np.array(img).astype(int)[ground_mask] - np.array(src_img).astype(int)[ground_mask]).max()
            assert diff == 0, f"{rel}: ground changed (max diff {diff})"
    print(f"{len(images)} icons + 2 previews written to {HERE}")


if __name__ == "__main__":
    main()
