#!/usr/bin/env python3
"""Recolour the Cinemax app icon without redrawing it.

Only the HUE of the jellyfish changes: its shapes, highlights, shading and glow
are the original pixels, and the neutral ground is left untouched (verified:
ground pixels and alpha are byte-identical, except in the explicit « fond
aubergine » variant).

    python3 design/logo-variantes/recolor.py                    # regenerates everything here
    python3 design/logo-variantes/recolor.py --install-corners  # + writes the corner-filled
                                                                #   icons into Resources/

Needs Pillow + numpy.

Sources
- The icons whose rounded corners are painted in (`CORNERED`) are read from
  `originaux/`, the untouched copies taken on 2026-09-28 before Resources/ got
  their corner-filled versions. Everything else is read from Resources/.
- Each variant is written to `declinaisons/<variant>/<path inside Assets.xcassets>`,
  only for the files it actually changes (the tvOS back layers are plain ground,
  so only the aubergine variant has them). The tinted icon is greyscale, and
  `app_logo.png` is `app_icon_1024.png` pixel for pixel: neither is duplicated.

How it works
- The original glow runs from green (hue ~150°, tentacles / diaphragm) to blue
  (hue ~200°, bell) — the same on every source. `t` = where a pixel sits on that
  gradient (0 green → 1 blue).
- A pixel is recoloured only if it is saturated (s > 0.12, full weight at 0.25)
  and inside the glow's hue band (110°–245°), with soft edges so the halo blends.
- Accent variants: the gradient is re-centred on the accent's hue (the app's
  dark-theme `accentDark` in `AccentOption.swift`) and compressed to ±~17°, so it
  reads as one colour but keeps a soft two-tone depth.
- Halloween variants: t=0 and t=1 are mapped to the « Nuit d'Halloween » theme's
  Citrouille #FF7A1A and Potion #A57BFF, going round the hue wheel through
  magenta/red (the way the original goes through cyan).
- Corners: the originals have their rounded corners painted in, white (light grey
  on the dark icon) outside, plus a bevel along the curve. iOS / tvOS apply their
  own mask to a SQUARE icon, so `fill_corners` replaces the white and that bevel
  with the ground, inpainted harmonically from the surrounding pixels (the top
  highlight fades into the corner). Every pixel outside the corner boxes stays
  byte-identical.
"""
import colorsys
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ASSETS = os.path.join(ROOT, "Resources/Assets.xcassets")
ORIGINALS = os.path.join(HERE, "originaux")
OUT = os.path.join(HERE, "declinaisons")

ICON = "AppIcon.appiconset/app_icon_1024.png"
ICON_DARK = "AppIcon.appiconset/app_icon_1024_dark.png"
ICON_TINTED = "AppIcon.appiconset/app_icon_1024_tinted.png"
LOGO = "AppLogo.imageset/app_logo.png"
LOGO_TV = "AppLogo.imageset/app_logo_tv.png"
TV = "App Icon & Top Shelf Image.brandassets"
TV_LARGE = f"{TV}/App Icon - Large.imagestack"
TV_SMALL = f"{TV}/App Icon - Small.imagestack"
TV_FRONTS = [f"{TV_LARGE}/Front.imagestacklayer/Content.imageset/front_appstore.png",
             f"{TV_SMALL}/Front.imagestacklayer/Content.imageset/front_1x.png",
             f"{TV_SMALL}/Front.imagestacklayer/Content.imageset/front_2x.png"]
TV_BACKS = [f"{TV_LARGE}/Back.imagestacklayer/Content.imageset/back_appstore.png",
            f"{TV_SMALL}/Back.imagestacklayer/Content.imageset/back_1x.png",
            f"{TV_SMALL}/Back.imagestacklayer/Content.imageset/back_2x.png"]
# The Middle layers are empty (fully transparent) and the Top Shelf images are
# not part of an app icon (an alternate icon never swaps them): not declined.

CORNERED = [ICON, ICON_DARK, ICON_TINTED, LOGO]           # painted corners → filled
RECOLOURED = [ICON, ICON_DARK, LOGO_TV] + TV_FRONTS + TV_BACKS

# AccentOption.swift — accentDark (the hue the app shows on its dark theme).
ACCENTS = {
    "rouge": 0xFF6B6B, "orange": 0xFF8C42, "jaune": 0xFFC940, "vert": 0x4CAF82, "cyan": 0x2DD4BF,
    "bleu": 0x679CFF, "indigo": 0x818CF8, "violet": 0xBF7FFF, "rose": 0xFF6BB5,
}
CITROUILLE = 0xFF7A1A  # Halloween theme accent
POTION = 0xA57BFF      # Halloween theme accent 2
# Halloween surfaces, darkest → lightest: Nuit, Crypte, Caveau, Tombe.
AUBERGINE = [0x0C0A10, 0x15111C, 0x1D1726, 0x262033]

HALLOWEEN_A = "halloween_cloche-citrouille_tentacules-potion"
HALLOWEEN_B = "halloween_cloche-potion_tentacules-citrouille"
HALLOWEEN_A_AUBERGINE = "halloween_cloche-citrouille_tentacules-potion_fond-aubergine"

CORNER_BOX = 260       # px (at 1024) searched for the painted white corner
CORNER_GROW = 14       # px added around the white so the curved bevel goes too

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


def harmonic_fill(img, mask, iterations=60):
    """Fill `img` where `mask` is true with a smooth (Laplace) continuation of the
    pixels around it — coarse-to-fine, image edges treated as free (Neumann)."""
    h, w = mask.shape
    if min(h, w) <= 16:
        out = img.copy()
        out[mask] = img[~mask].mean(0) if (~mask).any() else 0
        iterations = 400
    else:
        h2, w2 = (h + 1) // 2, (w + 1) // 2
        known = np.zeros((h2 * 2, w2 * 2)); vals = np.zeros((h2 * 2, w2 * 2, img.shape[2]))
        known[:h, :w] = ~mask; vals[:h, :w] = img * (~mask)[..., None]
        k = known.reshape(h2, 2, w2, 2).sum((1, 3))
        v = vals.reshape(h2, 2, w2, 2, -1).sum((1, 3))
        coarse = harmonic_fill(v / np.maximum(k, 1)[..., None], k == 0, iterations)
        out = img.copy()
        out[mask] = coarse.repeat(2, 0).repeat(2, 1)[:h, :w][mask]
    for _ in range(iterations):
        p = np.pad(out, ((1, 1), (1, 1), (0, 0)), mode="edge")
        avg = (p[:-2, 1:-1] + p[2:, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:]) / 4
        out[mask] = avg[mask]
    return out


def fill_corners(rgb):
    """Square the icon: the painted white corners and their bevel become ground."""
    n = rgb.shape[0]
    white = np.zeros(rgb.shape[:2], bool)
    for ys in (slice(0, CORNER_BOX), slice(n - CORNER_BOX, n)):
        for xs in (slice(0, CORNER_BOX), slice(n - CORNER_BOX, n)):
            white[ys, xs] = rgb[ys, xs].mean(-1) > 0.55
    grown = Image.fromarray(white.astype(np.uint8) * 255)
    for _ in range(CORNER_GROW):
        grown = grown.filter(ImageFilter.MaxFilter(3))
    mask = np.array(grown) > 0
    out = rgb.copy()
    out[mask] = harmonic_fill(rgb, mask)[mask]
    return out, mask


def to_image(arr, alpha=None):
    rgb = (np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8)
    return Image.fromarray(rgb if alpha is None else np.dstack([rgb, alpha]))


def load(rel):
    """→ (rgb float, alpha uint8 or None, corner mask or None). Painted corners filled."""
    if rel not in CORNERED:
        img = Image.open(os.path.join(ASSETS, rel))
        alpha = np.array(img.convert("RGBA"))[..., 3] if img.mode in ("RGBA", "LA", "P") else None
        return np.array(img.convert("RGB")).astype(np.float64) / 255, alpha, None
    raw = np.array(Image.open(os.path.join(ORIGINALS, rel)).convert("RGB"))
    filled, mask = fill_corners(raw.astype(np.float64) / 255)
    out = np.array(to_image(filled))
    assert (out[~mask] == raw[~mask]).all(), f"{rel}: fill_corners touched the icon"
    assert out[mask].mean(-1).max() < 0.4 * 255, f"{rel}: white left in a corner"
    return out.astype(np.float64) / 255, None, mask


def variants(rgb):
    """Every colour variant of one source, keyed by variant name."""
    H, S, V = rgb_to_hsv(rgb)
    glow = (np.clip((S - 0.12) / 0.13, 0, 1)
            * np.clip(1 - np.maximum(np.maximum(110 - H, 0), np.maximum(H - 245, 0)) / 15, 0, 1))[..., None]
    t = np.clip((H - 150) / 50, 0, 1)  # 0 = original green, 1 = original blue

    def blend(recoloured):
        return rgb * (1 - glow) + recoloured * glow

    out = {}

    # 1. One variant per theme accent.
    for name, hexv in ACCENTS.items():
        accent_h = hex_hsv(hexv)[0] * 360
        nh = ((accent_h + (H - ACCENT_CENTER) * ACCENT_SPREAD) % 360) / 360
        out[name] = blend(hsv_to_rgb(nh, S, V))

    # 2. Halloween: bell / tentacles in Citrouille / Potion.
    orange_h = hex_hsv(CITROUILLE)[0] * 360          # ~25°
    potion_h, potion_s, _ = hex_hsv(POTION)          # ~259°, s ~0.52
    potion_h *= 360
    potion_sat = potion_s / 0.9 if potion_s < 0.9 else 1.0

    # A: tentacles (t=0) potion → bell (t=1) citrouille, via magenta/red.
    h0, h1 = potion_h, orange_h + 360
    nh = ((h0 + (h1 - h0) * t) % 360) / 360
    out[HALLOWEEN_A] = blend(hsv_to_rgb(nh, np.clip(S * np.interp(t, [0, 1], [potion_sat, 1.0]), 0, 1), V))

    # B: the reverse — tentacles citrouille, bell potion.
    h0, h1 = orange_h + 360, potion_h
    nh = ((h0 + (h1 - h0) * t) % 360) / 360
    out[HALLOWEEN_B] = blend(hsv_to_rgb(nh, np.clip(S * np.interp(t, [0, 1], [1.0, 0.62]), 0, 1), V))

    # A + aubergine ground: only the dark neutral ground.
    ground = np.clip((0.12 - S) / 0.04, 0, 1) * np.clip((0.40 - V) / 0.10, 0, 1)
    lum = rgb.mean(-1)
    ramp = np.array([hex_rgb(x) for x in AUBERGINE])
    base = np.stack([np.interp(lum, [0.04, 0.08, 0.14, 0.20], ramp[:, c]) for c in range(3)], -1)
    base = base * (lum / np.maximum(base.mean(-1), 1e-6))[..., None]  # keep the original light falloff
    out[HALLOWEEN_A_AUBERGINE] = out[HALLOWEEN_A] * (1 - ground[..., None]) + base * ground[..., None]
    return out


def main():
    install = "--install-corners" in sys.argv[1:]

    # 1. Corner-filled sources — and, on request, into the app.
    sources = {rel: load(rel) for rel in dict.fromkeys(CORNERED + RECOLOURED)}
    for rel in CORNERED:
        rgb, _, _ = sources[rel]
        target = os.path.join(ASSETS, rel)
        if install:
            to_image(rgb).save(target, optimize=True)
        if not (np.array(Image.open(target).convert("RGB")) == np.array(to_image(rgb))).all():
            print(f"note: {rel} in Resources/ still has its painted corners (--install-corners)")

    # 1b. « classique » — the identity variant (corners filled, original hue),
    # written for EVERY recoloured file: scripts/seasonal-icon.py restores it.
    for rel in RECOLOURED:
        rgb, alpha, _ = sources[rel]
        path = os.path.join(OUT, "classique", rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        to_image(rgb, alpha).save(path, optimize=True)

    # 2. Every variant of every recoloured source; only files that differ are written.
    written = {}
    for rel in RECOLOURED:
        rgb, alpha, _ = sources[rel]
        src8 = np.array(to_image(rgb))
        ground = rgb_to_hsv(rgb)[1] < 0.1
        for name, arr in variants(rgb).items():
            img = to_image(arr, alpha)
            out8 = np.array(img)[..., :3]
            if (out8 == src8).all():
                continue
            if name != HALLOWEEN_A_AUBERGINE:  # guard: the ground never moves
                diff = np.abs(out8[ground].astype(int) - src8[ground]).max()
                assert diff == 0, f"{name}/{rel}: ground changed (max diff {diff})"
            path = os.path.join(OUT, name, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            img.save(path, optimize=True)
            written[(name, rel)] = img

    # 3. Contact sheets.
    font = None
    for candidate in ("DejaVuSans.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf"):
        try:
            font = ImageFont.truetype(candidate, 20)
            break
        except OSError:
            pass
    font = font or ImageFont.load_default(size=20)

    def rounded(img, size, radius):
        """`img` scaled to `size`, under a rounded mask (the way the system shows it)."""
        w, h = size
        mask = Image.new("L", (w * 4, h * 4), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, w * 4 - 1, h * 4 - 1), radius=radius * 4, fill=255)
        return img.convert("RGB").resize(size, Image.LANCZOS), mask.resize(size, Image.LANCZOS)

    def get(name, rel):
        if (name, rel) in written:
            return written[(name, rel)]
        rgb, alpha, _ = sources[rel]
        return to_image(rgb, alpha)

    def tv_icon(name):
        back = get(name, TV_BACKS[0]).convert("RGBA")
        back.alpha_composite(get(name, TV_FRONTS[0]).convert("RGBA"))
        return back

    def sheet(rows, cols, cell, name, bg, labels_on_top=None):
        pad, label_h = 24, 56
        head = 40 if labels_on_top else 0
        out = Image.new("RGB", (cols * (cell[0] + pad) + pad, head + len(rows) * (cell[1] + pad + label_h) + pad), bg)
        draw = ImageDraw.Draw(out)
        for c, text in enumerate(labels_on_top or []):
            w = draw.textlength(text, font=font)
            draw.text((pad + c * (cell[0] + pad) + (cell[0] - w) / 2, 12), text, fill=(160, 156, 152), font=font)
        for r, (label, tiles) in enumerate(rows):
            y = head + pad + r * (cell[1] + pad + label_h)
            for c, (img, size, radius) in enumerate(tiles):
                x = pad + c * (cell[0] + pad)
                if radius is None:
                    out.paste(img.convert("RGB").resize(size, Image.LANCZOS), (x, y))
                else:
                    tile_img, mask = rounded(img, size, radius)
                    out.paste(tile_img, (x, y), mask)
            for j, line in enumerate(label.split("\n")):
                w = draw.textlength(line, font=font)
                draw.text((pad + (cell[0] * cols + pad * (cols - 1) - w) / 2 if len(tiles) > 1 else pad + (cell[0] - w) / 2,
                           y + cell[1] + 8 + j * 24), line, fill=(236, 232, 228), font=font)
        out.save(os.path.join(HERE, name), optimize=True)

    def grid(items, cols, tile, name, bg):
        # items: (label, image) in a grid, one label under each tile.
        pad, label_h = 24, 56
        nrows = (len(items) + cols - 1) // cols
        out = Image.new("RGB", (cols * (tile + pad) + pad, nrows * (tile + pad + label_h) + pad), bg)
        draw = ImageDraw.Draw(out)
        for k, (label, img) in enumerate(items):
            x = pad + (k % cols) * (tile + pad)
            y = pad + (k // cols) * (tile + pad + label_h)
            tile_img, mask = rounded(img, (tile, tile), tile * 0.2237)
            out.paste(tile_img, (x, y), mask)
            for j, line in enumerate(label.split("\n")):
                w = draw.textlength(line, font=font)
                draw.text((x + (tile - w) / 2, y + tile + 8 + j * 24), line, fill=(236, 232, 228), font=font)
        out.save(os.path.join(HERE, name), optimize=True)

    labels = {HALLOWEEN_A: "A · cloche citrouille\ntentacules potion",
              HALLOWEEN_B: "B · cloche potion\ntentacules citrouille",
              HALLOWEEN_A_AUBERGINE: "A + fond aubergine"}
    grid([("actuelle", get(None, ICON))] + [(n, get(n, ICON)) for n in ACCENTS],
         5, 300, "apercu_accents.png", (18, 18, 20))
    grid([("actuelle", get(None, ICON))] + [(labels[k], get(k, ICON)) for k in labels],
         4, 360, "apercu_halloween.png", (12, 10, 16))

    # Every declined asset, one row per variant: clair · sombre · tvOS · logo tvOS.
    rows = []
    for name in [None] + list(ACCENTS) + list(labels):
        logo_tv = Image.new("RGBA", (1280, 768), (14, 14, 14, 255))
        logo_tv.alpha_composite(get(name, LOGO_TV).convert("RGBA"))
        rows.append((labels.get(name, name or "actuelle").replace("\n", " "), [
            (get(name, ICON), (240, 240), 240 * 0.2237),
            (get(name, ICON_DARK), (240, 240), 240 * 0.2237),
            (tv_icon(name), (400, 240), 12),
            (logo_tv, (400, 240), None)]))
    sheet(rows, 4, (400, 240), "apercu_declinaisons.png", (18, 18, 20),
          labels_on_top=["iOS clair", "iOS sombre", "tvOS (fond + face)", "logo in-app tvOS"])

    n_variants = len({name for name, _ in written})
    print(f"{len(written)} files for {n_variants} variants + 3 previews written to {HERE}")


if __name__ == "__main__":
    main()
