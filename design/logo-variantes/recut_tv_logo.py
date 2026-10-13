"""Recut app_logo_tv.png: drop the dark icon ground left around the jellyfish.

Usage: python3 logo_recut.py <src png> <out png> <preview dir> [T] [K]

- G, the ground colour, is read on the old cut's outermost opaque ring (pure ground).
- Ground region = flood fill from the transparent outside over pixels within T of G
  (the neon outline stops it; the dome's dark glass, enclosed by it, is never reached;
  the gaps between tentacles, open at the bottom, are).
- In that region the pixel becomes LIGHT over transparency: alpha = excess over G / K,
  colour unmixed (F = G + excess / alpha) — so the outer glow stays, as translucent glow.
- Everything else stays opaque, exactly as it was.
"""
import collections
import sys

from PIL import Image, ImageFilter

src, out, prev = sys.argv[1], sys.argv[2], sys.argv[3]
T = float(sys.argv[4]) if len(sys.argv) > 4 else 34
K = float(sys.argv[5]) if len(sys.argv) > 5 else 110

im = Image.open(src).convert("RGBA")
W, H = im.size
px = im.load()

# Ground colour: median of opaque pixels touching transparency.
ring = []
for y in range(1, H - 1):
    for x in range(1, W - 1):
        if px[x, y][3] == 255 and min(px[x + dx, y + dy][3] for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))) == 0:
            ring.append(px[x, y][:3])
ring.sort(key=lambda c: sum(c))
G = ring[len(ring) // 2]
print("ground", G, "from", len(ring), "edge pixels")


def diff(c):
    return max(abs(c[0] - G[0]), abs(c[1] - G[1]), abs(c[2] - G[2]))


# Flood fill the ground region from everything transparent.
LENS, LENS_R = (646, 282), 128
ground = bytearray(W * H)
# Seed from the image border only: a translucent pixel enclosed by the body
# (inside the lens) must not open a way in.
stack = [(x, y) for x in range(W) for y in (0, H - 1)] + [(x, y) for y in range(H) for x in (0, W - 1)]
for x, y in stack:
    ground[y * W + x] = 1
# Outside first: transparent pixels connected to the border.
outside = list(stack)
while outside:
    x, y = outside.pop()
    for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
        if 0 <= nx < W and 0 <= ny < H and not ground[ny * W + nx] and px[nx, ny][3] < 255:
            ground[ny * W + nx] = 1
            outside.append((nx, ny))
            stack.append((nx, ny))
while stack:
    x, y = stack.pop()
    for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
        if 0 <= nx < W and 0 <= ny < H and not ground[ny * W + nx]:
            if (nx - LENS[0]) ** 2 + (ny - LENS[1]) ** 2 < LENS_R ** 2:
                continue  # the lens is body, whatever its darks
            c = px[nx, ny]
            if c[3] < 255 or diff(c) < T:
                ground[ny * W + nx] = 1
                stack.append((nx, ny))

print("T", T, "lens centre flooded:", bool(ground[LENS[1] * W + LENS[0]]),
      "ground px:", sum(ground))

core_img = im.split()[3].point(lambda v: 255 if v == 255 else 0).filter(ImageFilter.MinFilter(7))
core = core_img.load()
# The glow fades out towards the old edge instead of stopping on its jags.
fade = core_img.filter(ImageFilter.GaussianBlur(6)).load()

body = Image.new("L", (W, H), 0)
body.putdata([0 if g else 255 for g in ground])
near_body = body.filter(ImageFilter.MaxFilter(5)).load()  # within 2 px of the body

groundimg = Image.new("L", (W, H), 0)
groundimg.putdata([255 if g else 0 for g in ground])
near_ground = groundimg.filter(ImageFilter.MaxFilter(3)).load()  # body pixel touching ground


def brightest_body(x, y, fallback):
    """Colour of the brightest body pixel within 2 px (the neon, unmixed)."""
    best, best_l = fallback, -1
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            nx, ny = x + dx, y + dy
            if 0 <= nx < W and 0 <= ny < H and not ground[ny * W + nx]:
                c = px[nx, ny]
                lum = c[0] + c[1] + c[2]
                if lum > best_l:
                    best, best_l = c[:3], lum
    return best


res = Image.new("RGBA", (W, H), (0, 0, 0, 0))
rp = res.load()
for y in range(H):
    for x in range(W):
        r, g, b, a = px[x, y]
        if a == 0:
            continue
        if not ground[y * W + x]:
            if near_ground[x, y]:
                # The neon's own outer pixel: anti-aliased against the dark
                # ground. Fade it by how far it stands above the ground, and
                # give it the colour of the neon beside it.
                al = min(1.0, max(0.0, (diff((r, g, b)) - (T - K)) / (2 * K)))
                rp[x, y] = brightest_body(x, y, (r, g, b)) + (int(al * 255 + 0.5),)
                continue
            # Body: opaque, holes the old cut punched into it included.
            rp[x, y] = (r, g, b, 255)
            continue
        if a < 255 or not core[x, y]:
            # The old cut's own jagged edge and its 3 px fringe: ground
            # through and through, mixed with whatever it was cut against.
            continue
        # Ground is gone. Only the last few levels below the threshold — the
        # pixels hugging the neon outline — stay, as its anti-aliasing.
        al = (diff((r, g, b)) - (T - K)) / K
        if al <= 0.02 or not near_body[x, y]:
            continue
        # Decontaminate: an edge pixel takes the colour of the brightest body
        # pixel within 2 px — its own colour is neon mixed with the dark ground.
        rp[x, y] = brightest_body(x, y, (r, g, b)) + (int(min(1.0, al) * 255 + 0.5),)

# Soften the seam between the opaque body and the glow by one pixel.
alpha = res.split()[3]
soft = alpha.filter(ImageFilter.GaussianBlur(0.6))
res.putalpha(Image.eval(Image.merge("L", [alpha]), lambda v: v).point(lambda v: v) if False else soft)
res.save(out)

bbox = res.split()[3].getbbox()
for bgc, name in (((250, 250, 250, 255), "white"), ((92, 52, 22, 255), "brown"), ((14, 14, 14, 255), "black")):
    bg = Image.new("RGBA", (W, H), bgc)
    bg.alpha_composite(res)
    bg.crop(bbox).save(f"{prev}/new_on_{name}.png")
print("bbox", bbox)
