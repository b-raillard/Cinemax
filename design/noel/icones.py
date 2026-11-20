#!/usr/bin/env python3
"""L'icône de Noël : le logo d'origine, coiffé d'un bonnet, des ampoules sur les tentacules.

    python3 design/noel/icones.py

Écrit la déclinaison `design/logo-variantes/declinaisons/noel/` (validée par le
propriétaire le 2026-11-20, planches I7 et TV8 du canevas « JellyGlass — Thème
de Noël ») : icône iOS claire et sombre, calques Apple TV, logo des Réglages
Apple TV. Ensuite : `recolor.py --alternates` (icône alternative
`AppIconChristmas` + vignettes) et `scripts/seasonal-icon.py noel` (icône
principale de la version de décembre).

Rien n'est dessiné à la main : le bonnet (volume, bord et pompon en fourrure) et
les ampoules (verre, culot, halo) sont rendus, posés sur les pixels du logo.
- iOS : le logo des `originaux/`, coins remplis par recolor.py.
- Apple TV : le logo DÉTOURÉ des Réglages (`classique/AppLogo.imageset`) sur le
  calque Front — le calque Front d'origine laisse un halo sombre autour de la
  méduse dès qu'on lui ajoute un élément — et, sur le calque Back, le fond
  d'origine avec une guirlande de couleurs en haut et quelques flocons.
Graines fixes : deux lancements donnent les mêmes images.
"""
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "logo-variantes"))
import recolor as R  # noqa: E402

CLASSIC = os.path.join(R.OUT, "classique")
VARIANT = os.path.join(R.OUT, "noel")
WARM = (255, 214, 150)
GARLAND = ((255, 96, 96), (255, 205, 92), (104, 226, 146), (118, 188, 255))
BULBS = [(255, 84, 84), (255, 205, 92), (92, 226, 138), (110, 184, 255)]


def parts(rgb):
    H, S, V = R.rgb_to_hsv(rgb)
    glow = (np.clip((S - 0.12) / 0.13, 0, 1)
            * np.clip(1 - np.maximum(np.maximum(110 - H, 0), np.maximum(H - 245, 0)) / 15, 0, 1))
    t = np.clip((H - 150) / 50, 0, 1)
    return H, S, V, glow, t


def jelly_box(rgb, alpha=None):
    """→ mask, (x0, y0, x1, y1) of the whole jellyfish, y of the bell's lower edge."""
    _, S, V, glow, _ = parts(rgb)
    m = (glow > 0.6) & (V > 0.45)
    if alpha is not None:
        m &= alpha > 128
    ys, xs = np.where(m)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    widths = np.array([(np.where(m[y])[0].max() - np.where(m[y])[0].min()) if m[y].any() else 0
                       for y in range(y0, y1 + 1)])
    widest = int(widths.argmax())
    below = np.where(widths[widest:] < 0.78 * widths.max())[0]
    bell_bottom = y0 + widest + (int(below[0]) if len(below) else 0)
    return m, (int(x0), int(y0), int(x1), int(y1)), int(bell_bottom)


def bezier(p0, p1, p2, n=24):
    return [((1 - u) ** 2 * p0[0] + 2 * (1 - u) * u * p1[0] + u * u * p2[0],
             (1 - u) ** 2 * p0[1] + 2 * (1 - u) * u * p1[1] + u * u * p2[1])
            for u in np.linspace(0, 1, n)]


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
        d.line([(x * k, yy * k) for x, yy in pts], fill=255, width=max(1, int(1.3 * k)))
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


def crystal(px, glow=True):
    """One snow crystal, white, with a soft halo."""
    k = 4
    im = Image.new("L", (px * k, px * k), 0)
    d = ImageDraw.Draw(im)
    c, r = px * k / 2, px * k * 0.42
    for i in range(6):
        a = math.pi / 3 * i + math.pi / 6
        d.line([c, c, c + r * math.cos(a), c + r * math.sin(a)], fill=255, width=max(2, int(px * k / 34)))
        for frac, bl in ((0.34, 0.30), (0.56, 0.24), (0.78, 0.15)):
            bx, by = c + r * frac * math.cos(a), c + r * frac * math.sin(a)
            for s in (-1, 1):
                b = a + s * math.pi / 3
                d.line([bx, by, bx + r * bl * math.cos(b), by + r * bl * math.sin(b)], fill=255, width=max(2, int(px * k / 44)))
    d.ellipse([c - r * 0.08, c - r * 0.08, c + r * 0.08, c + r * 0.08], fill=255)
    im = im.resize((px, px), Image.LANCZOS)
    layers = [solid(im, (255, 255, 255), 1.0)]
    if glow:
        layers.insert(0, solid(blur(im, px / 16), (214, 232, 255), 0.9))
    return over(Image.new("RGBA", (px, px), (0, 0, 0, 0)), *layers)


def scatter_flakes(base, n, seed, sizes=(10, 22), soft=0.5, avoid=None):
    rnd = random.Random(seed)
    out = base.convert("RGBA")
    for _ in range(n):
        px = int(rnd.uniform(*sizes))
        f = crystal(px * 2).resize((px, px), Image.LANCZOS).rotate(rnd.uniform(0, 60), resample=Image.BICUBIC)
        if soft:
            f = blur(f, soft * rnd.uniform(0.3, 1.4))
        a = np.array(f)
        a[..., 3] = (a[..., 3] * rnd.uniform(0.35, 0.8)).astype(np.uint8)
        x, y = int(rnd.uniform(0, out.width - px)), int(rnd.uniform(0, out.height - px))
        if avoid and avoid(x + px / 2, y + px / 2):
            continue
        out.alpha_composite(Image.fromarray(a), (x, y))
    return out


def _blur(a, r):
    return np.array(Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(r))).astype(np.float64) / 255


def _fur(mask, seed, grain, reach):
    """A furry edge: the mask's soft border broken by fine noise."""
    h, w = mask.shape
    rs = np.random.RandomState(seed)
    small = rs.rand(max(2, int(h / grain)), max(2, int(w / grain)))
    noise = np.array(Image.fromarray((small * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)).astype(np.float64) / 255
    soft = _blur(mask, reach)
    return np.clip((soft + (noise - 0.5) * 0.55 - 0.42) / 0.16, 0, 1)


def hat_layer(size, box):
    """The Santa hat, with volume: lit from the upper left, a fold, a furry brim and pompom."""
    w, h = size
    x0, y0, x1, _ = box
    W = x1 - x0
    cx = (x0 + x1) / 2
    k = 2

    def P(dx, dy):
        return ((cx + dx * W) * k, (y0 + dy * W) * k)

    left, right = P(-0.33, 0.15), P(0.27, 0.06)
    apex, pom = P(0.03, -0.20), P(0.42, 0.03)
    body_pts = (bezier(left, P(-0.24, -0.14), apex) + bezier(apex, P(0.30, -0.27), pom)
                + bezier(pom, P(0.27, -0.08), right))
    body = Image.new("L", (w * k, h * k), 0)
    ImageDraw.Draw(body).polygon(body_pts, fill=255)
    body = np.array(body.resize((w, h), Image.LANCZOS)).astype(np.float64) / 255

    yy, xx = np.mgrid[0:h, 0:w]
    # volume: the inside of the shape is the near side; light comes from the upper left
    depth = _blur(body, W * 0.05)
    gx = np.gradient(_blur(body, W * 0.035), axis=1)
    gy = np.gradient(_blur(body, W * 0.035), axis=0)
    lit = np.clip(0.5 + (gx * 0.55 + gy * 0.8) * W * 0.11, 0, 1)        # 1 = facing the light
    shade = 0.42 + 0.62 * lit * (0.55 + 0.45 * depth)
    base = np.array([0.82, 0.10, 0.13])
    col = base[None, None] * shade[..., None]
    # the fold where the tip flops over, and a soft sheen on the flank
    fold = np.exp(-(((xx - (cx + 0.20 * W)) / (0.035 * W)) ** 2)) * np.clip(1 - np.abs(yy - (y0 - 0.12 * W)) / (0.10 * W), 0, 1)
    col *= (1 - 0.22 * fold)[..., None]
    sheen = np.exp(-(((xx - (cx - 0.13 * W)) / (0.05 * W)) ** 2 + ((yy - (y0 - 0.05 * W)) / (0.11 * W)) ** 2))
    col += sheen[..., None] * np.array([0.30, 0.16, 0.14])
    out = R.to_image(col, (np.clip(body * 0.93, 0, 1) * 255).astype(np.uint8))
    # the logo's neon echo: a thin bright rim
    rim = np.clip(_blur(body, 1.2) - _blur(body, 3.0), 0, 1) * 3.0
    out = over(out, solid(Image.fromarray((np.clip(rim, 0, 1) * 255).astype(np.uint8)), (255, 150, 140), 0.85))

    def fur_layer(mask, seed):
        f = _fur(mask, seed, grain=W * 0.012, reach=W * 0.012)
        tone = np.clip((_blur(mask, W * 0.03) - 0.25) * 1.6, 0, 1)          # 1 in the middle
        gyb = np.gradient(_blur(mask, W * 0.03), axis=0) * W * 0.06
        light = np.clip(0.72 + 0.28 * tone + gyb * 0.9, 0.45, 1)
        c = np.array([0.97, 0.98, 1.0])[None, None] * light[..., None] * np.array([1.0, 1.0, 1.0]) + (1 - light[..., None]) * np.array([0.16, 0.22, 0.34]) * 0.6
        rs = np.random.RandomState(seed + 9)
        c += rs.normal(0, 0.025, c.shape)
        return R.to_image(c, (f * 255).astype(np.uint8))

    brim = Image.new("L", (w * k, h * k), 0)
    d = ImageDraw.Draw(brim)
    bw = int(0.092 * W * k)
    band = bezier(P(-0.37, 0.175), P(-0.04, 0.055), P(0.31, 0.075), 40)
    d.line(band, fill=255, width=bw, joint="curve")
    for end in (band[0], band[-1]):
        d.ellipse([end[0] - bw / 2, end[1] - bw / 2, end[0] + bw / 2, end[1] + bw / 2], fill=255)
    brim = np.array(brim.resize((w, h), Image.LANCZOS)).astype(np.float64) / 255
    pm = Image.new("L", (w * k, h * k), 0)
    r = 0.066 * W * k
    ImageDraw.Draw(pm).ellipse([pom[0] - r, pom[1] - r, pom[0] + r, pom[1] + r], fill=255)
    pm = np.array(pm.resize((w, h), Image.LANCZOS)).astype(np.float64) / 255

    # a soft shadow of the brim on the hat and of the hat on the bell
    sh = solid(Image.fromarray((np.clip(_blur(brim, W * 0.02), 0, 1) * 255).astype(np.uint8)), (30, 0, 6), 0.55)
    shifted = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    shifted.alpha_composite(sh, (0, int(-0.02 * W)))
    hat = Image.fromarray(np.array(shifted) * (np.array(out)[..., 3:4] > 40))
    out = over(out, hat, fur_layer(brim, 1), fur_layer(pm, 2))
    return out


def bulbs_layer(size, mask, box, bell_bottom):
    """Small glass bulbs on the tentacles: a dark cap, a coloured drop, a hot core."""
    w, h = size
    x0, y0, x1, y1 = box
    k = 3
    r = 0.034 * (x1 - x0)
    span = y1 - bell_bottom
    spots = []
    n = 0
    for i, frac in enumerate((0.16, 0.40, 0.64, 0.86)):
        y = int(bell_bottom + frac * span)
        row = np.where(mask[y - 2:y + 3].any(0))[0]
        if len(row) == 0:
            continue
        runs = np.split(row, np.where(np.diff(row) > 6)[0] + 1)
        for j, run in enumerate(runs):
            if (i + j) % 2:
                continue
            spots.append((run.mean(), y, BULBS[n % len(BULBS)]))
            n += 1
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    for colour in BULBS:
        glass = Image.new("L", (w * k, h * k), 0)
        core = Image.new("L", (w * k, h * k), 0)
        dg, dc = ImageDraw.Draw(glass), ImageDraw.Draw(core)
        for (x, y, c) in spots:
            if c != colour:
                continue
            dg.ellipse([(x - r * 0.78) * k, (y - r * 0.55) * k, (x + r * 0.78) * k, (y + r * 1.45) * k], fill=255)
            dc.ellipse([(x - r * 0.34) * k, (y - r * 0.05) * k, (x + r * 0.34) * k, (y + r * 0.85) * k], fill=255)
        glass, core = glass.resize(size, Image.LANCZOS), core.resize(size, Image.LANCZOS)
        out = over(out, solid(blur(glass, r * 2.6), colour, 1.3), solid(blur(glass, r * 0.9), colour, 1.5),
                      solid(glass, colour, 0.95), solid(blur(core, r * 0.25), (255, 252, 240), 0.9))
    caps = Image.new("L", (w * k, h * k), 0)
    dcap = ImageDraw.Draw(caps)
    for (x, y, _) in spots:
        dcap.rounded_rectangle([(x - r * 0.42) * k, (y - r * 0.95) * k, (x + r * 0.42) * k, (y - r * 0.35) * k], radius=r * 0.15 * k, fill=255)
    return over(out, solid(caps.resize(size, Image.LANCZOS), (38, 44, 40), 1.0))


def dressed(src, alpha):
    """Hat + bulbs on a source, classic colours."""
    mask, box, bell_bottom = jelly_box(src, alpha)
    size = (src.shape[1], src.shape[0])
    W = box[2] - box[0]
    out = src.copy()
    a = alpha
    for layer in (bulbs_layer(size, mask, box, bell_bottom), hat_layer(size, box)):
        top = np.array(layer).astype(np.float64) / 255
        out = out * (1 - top[..., 3:4]) + top[..., :3] * top[..., 3:4]
        if a is not None:
            a = np.maximum(a, np.array(layer)[..., 3])
    return np.clip(out, 0, 1), a


def save(image, rel):
    path = os.path.join(VARIANT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path, optimize=True)
    print(rel)


def main():
    for rel in (R.ICON, R.ICON_DARK):
        rgb, _, _ = R.load(rel)
        save(R.to_image(dressed(rgb, None)[0]), rel)

    logo = np.array(Image.open(os.path.join(CLASSIC, R.LOGO_TV)).convert("RGBA"))
    rgb, alpha = dressed(logo[..., :3].astype(np.float64) / 255, logo[..., 3])
    jelly = R.to_image(rgb, alpha)
    save(jelly, R.LOGO_TV)

    # Apple TV, Front: the dressed cut-out, a touch smaller so the hat clears the garland.
    w, h = jelly.size
    crop = jelly.crop(jelly.getbbox())
    crop = crop.resize((int(crop.width * 0.86), int(crop.height * 0.86)), Image.LANCZOS)
    pos = ((w - crop.width) // 2, (h - crop.height) // 2 + 46)
    front = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    front.alpha_composite(crop, pos)

    def near(x, y):
        return pos[0] - 30 < x < pos[0] + crop.width + 30 and pos[1] - 30 < y < pos[1] + crop.height + 30

    # Apple TV, Back: the original ground, the garland along the top, a few flakes.
    ground = Image.open(os.path.join(CLASSIC, R.TV_BACKS[0])).convert("RGB")
    swags = [(-40, 330, 34, 62), (330, 650, 40, 70), (650, 960, 40, 70), (960, 1320, 34, 62)]
    back = scatter_flakes(over(ground, string_lights((w, h), swags, 7, 2, colours=GARLAND, bulb=7.5, seed=3)),
                          26, 8, sizes=(16, 40), soft=0.9, avoid=near).convert("RGB")
    for rel, layer in list(zip(R.TV_FRONTS, [front] * 3)) + list(zip(R.TV_BACKS, [back] * 3)):
        size = Image.open(os.path.join(CLASSIC, rel)).size
        save(layer if layer.size == size else layer.resize(size, Image.LANCZOS), rel)


if __name__ == "__main__":
    main()
