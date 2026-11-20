#!/usr/bin/env python3
"""Décor du thème « Sapin de Noël » : les branches de sapin des deux angles du héros.

    python3 design/noel/decor.py

Rendu procédural (Pillow + numpy), jamais dessiné à la main : une tige, des
rameaux, des milliers d'aiguilles ombrées, des boules de verre éclairées en haut
à gauche, des micro-lumières. Écrit `SeasonFirLeft.imageset` et
`SeasonFirRight.imageset` dans `Resources/Assets.xcassets` : iPhone / iPad en
@2x et @3x (260 × 230 pt), Apple TV en @1x et @2x (1040 × 920 pt) ; et
`SeasonGarland.imageset`, UN feston de guirlande de couleurs qui se répète
en largeur (200 × 75 pt, 800 × 300 pt sur Apple TV).
Graines fixes : deux lancements donnent les mêmes images.
"""
import json
import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ASSETS = os.path.join(ROOT, "Resources/Assets.xcassets")
WARM = (255, 214, 150)
SC = 1.0   # scale of everything a bough is made of; set per output size


def to_image(arr, alpha=None):
    rgb = (np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8)
    return Image.fromarray(rgb if alpha is None else np.dstack([rgb, alpha]))


def blur(img, r):
    return img.filter(ImageFilter.GaussianBlur(r))


def solid(mask, colour, gain=1.0):
    """An RGBA layer of one colour whose alpha is `mask` (L image) × gain — no dark fringes."""
    a = np.clip(np.array(mask).astype(np.float64) * gain, 0, 255).astype(np.uint8)
    out = np.zeros(a.shape + (4,), np.uint8)
    out[..., :3] = colour
    out[..., 3] = a
    return Image.fromarray(out)


def over(base, *layers):
    out = base.convert("RGBA")
    for l in layers:
        out = Image.alpha_composite(out, l)
    return out


def bauble(r, base):
    """A glass ball: lit from the upper left, dark rim, a window highlight, a gold cap."""
    n = r * 2 + 8
    yy, xx = np.mgrid[0:n, 0:n]
    x, y = (xx - n / 2) / r, (yy - n / 2) / r
    rr = x * x + y * y
    z = np.sqrt(np.clip(1 - rr, 0, 1))
    l = np.array([-0.45, -0.60, 0.66])
    diff = np.clip(x * l[0] + y * l[1] + z * l[2], 0, 1)
    hx, hy, hz = l[0], l[1], l[2] + 1
    hn = math.sqrt(hx * hx + hy * hy + hz * hz)
    spec = np.clip((x * hx + y * hy + z * hz) / hn, 0, 1) ** 70
    fres = (1 - z) ** 3
    base = np.array(base) / 255
    col = base[None, None] * (0.16 + 0.95 * diff[..., None]) + spec[..., None] * 0.95 + fres[..., None] * np.array([0.9, 0.75, 0.5]) * 0.35
    col += np.clip(1 - ((x + 0.10) ** 2 / 0.05 + (y - 0.42) ** 2 / 0.02), 0, 1)[..., None] * 0.20   # warm bounce below
    alpha = np.clip((1 - np.sqrt(rr)) * r * 1.2, 0, 1)
    im = to_image(col, (alpha * 255).astype(np.uint8))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([n / 2 - r * 0.20, 4 - 2, n / 2 + r * 0.20, 4 + r * 0.22], radius=2, fill=(214, 178, 96, 255))
    return im


def fir_branch(size, start, angle, length, seed, k=2):
    """One fir bough: a stem, twigs on both sides, thousands of shaded needles; plus its shadow."""
    w, h = size
    rnd = random.Random(seed)
    layer = Image.new("RGBA", (w * k, h * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    greens = [(22, 62, 44), (30, 82, 56), (40, 104, 70), (54, 126, 86), (76, 150, 104)]

    def needles(x, y, ang, ln, dens):
        steps = max(4, int(ln / dens))
        for i in range(steps):
            u = i / steps
            px_, py_ = x + ln * u * math.cos(ang), y + ln * u * math.sin(ang)
            for s in (-1, 1):
                na = ang + s * rnd.uniform(0.45, 0.85)
                nl = rnd.uniform(11, 20) * SC * (1 - 0.45 * u)
                shade = greens[min(4, max(0, int(rnd.gauss(2.2 - s * math.sin(na) * 1.3, 0.9))))]
                d.line([px_ * k, py_ * k, (px_ + nl * math.cos(na)) * k, (py_ + nl * math.sin(na)) * k],
                       fill=shade + (255,), width=max(1, int(1.1 * k * SC)))

    x, y, a = start[0], start[1], angle
    seg = length / 16
    pts = [(x, y)]
    for i in range(16):
        a += rnd.uniform(-0.05, 0.05) + 0.012
        x, y = x + seg * math.cos(a), y + seg * math.sin(a)
        pts.append((x, y))
        if i > 1:
            for s in (-1, 1):
                ta = a + s * rnd.uniform(0.55, 0.85)
                tl = (length * 0.36) * (1 - i / 19) * rnd.uniform(0.75, 1.1)
                d.line([x * k, y * k, (x + tl * math.cos(ta)) * k, (y + tl * math.sin(ta)) * k], fill=(58, 40, 28, 255), width=int(1.6 * k * SC))
                needles(x, y, ta, tl, 2.3 * SC)
    d.line([(px_ * k, py_ * k) for px_, py_ in pts], fill=(62, 42, 28, 255), width=int(2.6 * k * SC), joint="curve")
    needles(pts[0][0], pts[0][1], angle + 0.05, length, 2.0 * SC)
    layer = layer.resize((w, h), Image.LANCZOS)
    sh = solid(blur(layer.split()[3], 7 * SC), (0, 0, 0), 0.55)
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    shadow.alpha_composite(sh, (int(4 * SC), int(9 * SC)))
    return over(shadow, layer), pts


# (start x offset from the corner, start y, angle, length, seed) at SC = 1, in @2x pixels
LEFT = [(-30, 10, 0.30, 400, 2), (-20, -6, 0.72, 300, 5), (-40, 60, 0.02, 250, 13)]
RIGHT = [(30, 6, 0.34, 420, 7), (20, -8, 0.78, 300, 9), (40, 70, 0.04, 240, 21)]
# (bough, point on its stem, radius, colour, thread length)
BALLS = {"left": [(0, 9, 30, (176, 30, 38), 64), (1, 8, 22, (206, 164, 82), 46)],
         "right": [(0, 10, 34, (206, 164, 82), 70), (1, 7, 24, (176, 30, 38), 50)]}
BASE = (520, 460)


def corner(side, sc):
    """One corner at scale `sc` (1 = iOS @2x)."""
    global SC
    SC = sc
    w, h = int(BASE[0] * sc), int(BASE[1] * sc)
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    stems = []
    for (dx, y, ang, ln, seed) in (LEFT if side == "left" else RIGHT):
        start = (dx * sc, y * sc) if side == "left" else (w + dx * sc, y * sc)
        bough, pts = fir_branch((w, h), start, ang if side == "left" else math.pi - ang, ln * sc, seed)
        out = over(out, bough)
        stems.append(pts)
    rnd = random.Random(3 if side == "left" else 4)
    lights = Image.new("L", (w, h), 0)
    dl = ImageDraw.Draw(lights)
    for pts in stems:
        for (x, y) in pts[3::3]:
            x, y = x + rnd.uniform(-22, 22) * sc, y + rnd.uniform(-10, 26) * sc
            dl.ellipse([x - 3 * sc, y - 3 * sc, x + 3 * sc, y + 3 * sc], fill=255)
    out = over(out, solid(blur(lights, 16 * sc), WARM, 1.5), solid(blur(lights, 5 * sc), WARM, 1.8),
               solid(blur(lights, sc), (255, 250, 236), 1.0))
    d = ImageDraw.Draw(out)
    for (stem, idx, r, colour, drop) in BALLS[side]:
        x, y = stems[stem][idx]
        r, drop = int(r * sc), int(drop * sc)
        d.line([x, y, x, y + drop], fill=(206, 178, 110, 230), width=max(1, int(2 * sc)))
        ball = bauble(r, colour)
        out.alpha_composite(ball, (min(max(0, int(x - ball.width / 2)), w - ball.width), int(y + drop - 4 * sc)))
    return out


def catenary(x0, x1, y, sag, n=60):
    return [(x0 + (x1 - x0) * u, y + sag * 4 * u * (1 - u)) for u in np.linspace(0, 1, n)]


def string_lights(size, swags, per_swag, k, colours=(WARM,), bulb=5.0, seed=1):
    """Fairy lights: a thin wire, small glass bulbs, a tight core and a wide bloom.
    `swags` = [(x0, x1, y, sag)], sizes in px of the final image; `k` = supersampling."""
    w, h = size
    rnd = random.Random(seed)
    wire = Image.new("L", (w * k, h * k), 0)
    d = ImageDraw.Draw(wire)
    bulbs = []
    for (x0, x1, y, sag) in swags:
        pts = catenary(x0, x1, y, sag)
        d.line([(x * k, yy * k) for x, yy in pts], fill=255, width=max(1, int(bulb * 0.28 * k)))
        for j in range(per_swag):
            u = (j + 0.5 + rnd.uniform(-0.12, 0.12)) / per_swag
            bulbs.append((x0 + (x1 - x0) * u, y + sag * 4 * u * (1 - u)))
    out = solid(wire.resize((w, h), Image.LANCZOS), (58, 52, 44), 0.9)
    for ci, colour in enumerate(colours):
        core = Image.new("L", (w * k, h * k), 0)
        dc = ImageDraw.Draw(core)
        for i, (x, y) in enumerate(bulbs):
            if i % len(colours) != ci:
                continue
            r = bulb * k
            dc.ellipse([x * k - r * 0.75, y * k + r * 0.2, x * k + r * 0.75, y * k + r * 2.3], fill=255)
        core = core.resize((w, h), Image.LANCZOS)
        out = over(out, solid(blur(core, bulb * 5), colour, 1.6), solid(blur(core, bulb * 1.8), colour, 1.9),
                   solid(core, colour, 1.0), solid(blur(core, 0.8), (255, 250, 236), 0.75))
    sock = Image.new("L", (w * k, h * k), 0)
    ds = ImageDraw.Draw(sock)
    for (x, y) in bulbs:
        ds.rectangle([x * k - bulb * 0.5 * k, y * k - bulb * 0.5 * k, x * k + bulb * 0.5 * k, y * k + bulb * 0.35 * k], fill=255)
    return over(out, solid(sock.resize((w, h), Image.LANCZOS), (34, 30, 26), 1.0))


GARLAND = ((255, 96, 96), (255, 205, 92), (104, 226, 146), (118, 188, 255))
TILE = (400, 150)   # one swag, in @2x pixels at scale 1 (200 × 75 pt)


def garland_tile(sc):
    """ONE swag of coloured bulbs that tiles sideways: three are rendered and the
    middle one kept, so every bulb's halo crosses the seam whole. The glass is
    SATURATED (a white-hot bulb vanishes on the light theme's linen ground): a
    coloured drop, a lighter heart, one small highlight, a soft halo."""
    w, h = int(TILE[0] * sc), int(TILE[1] * sc)
    k = 3
    per = 4
    r = 10 * sc
    wire = Image.new("L", (w * 3 * k, h * k), 0)
    dw = ImageDraw.Draw(wire)
    bulbs = []
    for i in range(3):
        pts = catenary(i * w, (i + 1) * w, 20 * sc, 30 * sc)
        dw.line([(x * k, y * k) for x, y in pts], fill=255, width=max(2, int(1.6 * sc * k)))
        for j in range(per):
            u = (j + 0.5) / per
            bulbs.append((i * w + w * u, 20 * sc + 30 * sc * 4 * u * (1 - u), GARLAND[(i * per + j) % len(GARLAND)]))
    out = solid(wire.resize((w * 3, h), Image.LANCZOS), (64, 88, 74), 0.95)
    for colour in GARLAND:
        glass = Image.new("L", (w * 3 * k, h * k), 0)
        heart = Image.new("L", (w * 3 * k, h * k), 0)
        shine = Image.new("L", (w * 3 * k, h * k), 0)
        dg, dh, ds = ImageDraw.Draw(glass), ImageDraw.Draw(heart), ImageDraw.Draw(shine)
        for (x, y, c) in bulbs:
            if c != colour:
                continue
            dg.ellipse([(x - r * 0.72) * k, (y + r * 0.35) * k, (x + r * 0.72) * k, (y + r * 2.5) * k], fill=255)
            dh.ellipse([(x - r * 0.36) * k, (y + r * 0.9) * k, (x + r * 0.30) * k, (y + r * 2.0) * k], fill=255)
            ds.ellipse([(x - r * 0.40) * k, (y + r * 0.70) * k, (x - r * 0.12) * k, (y + r * 1.15) * k], fill=255)
        glass, heart, shine = (m.resize((w * 3, h), Image.LANCZOS) for m in (glass, heart, shine))
        deep = tuple(int(c * 0.86) for c in colour)
        light = tuple(int(c + (255 - c) * 0.45) for c in colour)
        out = over(out, solid(blur(glass, r * 1.6), colour, 1.25), solid(glass, deep, 1.0),
                   solid(blur(heart, r * 0.25), light, 0.9), solid(blur(shine, 0.6 * sc), (255, 255, 255), 0.95))
    caps = Image.new("L", (w * 3 * k, h * k), 0)
    dc = ImageDraw.Draw(caps)
    for (x, y, _) in bulbs:
        dc.rounded_rectangle([(x - r * 0.42) * k, (y - r * 0.25) * k, (x + r * 0.42) * k, (y + r * 0.55) * k], radius=r * 0.12 * k, fill=255)
    out = over(out, solid(caps.resize((w * 3, h), Image.LANCZOS), (30, 44, 36), 1.0))
    return out.crop((w, 0, w * 2, h))


def main():
    for side, name in (("left", "SeasonFirLeft"), ("right", "SeasonFirRight")):
        folder = os.path.join(ASSETS, name + ".imageset")
        os.makedirs(folder, exist_ok=True)
        images = []
        for idiom, scale, sc in (("universal", "2x", 1.0), ("universal", "3x", 1.5), ("tv", "1x", 2.0), ("tv", "2x", 4.0)):
            filename = f"{name.lower()}_{idiom}@{scale}.png"
            corner(side, sc).save(os.path.join(folder, filename), optimize=True)
            images.append({"filename": filename, "idiom": idiom, "scale": scale})
            print(filename)
        with open(os.path.join(folder, "Contents.json"), "w") as f:
            json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
            f.write("\n")
    folder = os.path.join(ASSETS, "SeasonGarland.imageset")
    os.makedirs(folder, exist_ok=True)
    images = []
    for idiom, scale, sc in (("universal", "2x", 1.0), ("universal", "3x", 1.5), ("tv", "1x", 2.0), ("tv", "2x", 4.0)):
        filename = f"seasongarland_{idiom}@{scale}.png"
        garland_tile(sc).save(os.path.join(folder, filename), optimize=True)
        images.append({"filename": filename, "idiom": idiom, "scale": scale})
        print(filename)
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
