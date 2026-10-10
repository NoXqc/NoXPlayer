"""Generates VesperTV's icon set: a gold "V" cradling an evening star
("vesper" = evening star) on near-black with a warm horizon glow.

Run from the repo root:  python assets/icon/gen_icon.py
Writes icon_flat/icon_background/icon_foreground (1024px) and tv_banner
(1280x720) into assets/icon, plus the Android TV banner drawables. Then run
`dart run flutter_launcher_icons` to regenerate launcher icons.
"""
import math
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 4  # supersample
N = 1024


def gold_gradient(size, top=(255, 226, 140), bot=(196, 132, 18)):
    w, h = size
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))


def star_points(cx, cy, rx, ry, pinch=0.16):
    pts = []
    for i in range(8):
        a = math.radians(i * 45 - 90)
        if i % 2 == 0:
            r = (rx, ry)
        else:
            r = (rx * pinch * 1.6, ry * pinch * 1.6)
        pts.append((cx + r[0] * math.cos(a), cy + r[1] * math.sin(a)))
    return pts


def mark(scale=1.0, size=N):
    """Gold V + star on a transparent canvas (size x size)."""
    W = size * S
    k = W / N * scale
    off = (W - N * k) / 2

    def P(x, y):
        return (off + x * k, off + y * k)

    mask = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(mask)
    v = [(236, 300), (392, 300), (512, 624), (632, 300), (788, 300), (586, 742), (438, 742)]
    d.polygon([P(*p) for p in v], fill=255)
    # star in the notch
    cx, cy = P(512, 372)
    d.polygon(star_points(cx, cy, 78 * k, 112 * k), fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)
    layer = gold_gradient((size, size)).convert("RGBA")
    layer.putalpha(mask)
    # soft glow behind the mark
    glow = Image.new("RGBA", (size, size), (255, 190, 70, 0))
    glow.putalpha(mask.filter(ImageFilter.GaussianBlur(size * 0.03)).point(lambda p: int(p * 0.55)))
    out = Image.alpha_composite(glow, layer)
    return out


def background(size=N, w=None, h=None):
    w = w or size
    h = h or size
    img = Image.new("RGB", (w, h), (8, 6, 8))
    px = img.load()
    cx, cy = w * 0.5, h * 1.05
    rmax = max(w, h) * 0.85
    for y in range(h):
        for x in range(w):
            r = math.hypot(x - cx, (y - cy) * 1.15) / rmax
            t = max(0.0, 1 - r) ** 2.2
            base = (8 + 8 * (y / h), 6 + 5 * (y / h), 8)
            px[x, y] = (
                int(base[0] + 92 * t),
                int(base[1] + 52 * t),
                int(base[2] + 10 * t),
            )
    return img


def main():
    bg = background()
    bg.save("assets/icon/icon_background.png")
    fg = mark(scale=0.82)
    fg.save("assets/icon/icon_foreground.png")
    flat = bg.convert("RGBA")
    flat.alpha_composite(mark(scale=1.0))
    flat.convert("RGB").save("assets/icon/icon_flat.png")

    # TV banner 1280x720: mark left, wordmark right
    bw, bh = 1280, 720
    ban = background(w=bw, h=bh).convert("RGBA")
    m = mark(scale=1.0, size=520)
    ban.alpha_composite(m, (150, 100))
    d = ImageDraw.Draw(ban)
    font = None
    for f in ("C:/Windows/Fonts/segoeuib.ttf", "C:/Windows/Fonts/arialbd.ttf"):
        try:
            font = ImageFont.truetype(f, 118)
            break
        except OSError:
            pass
    text = "VesperTV"
    tw = d.textlength(text, font=font)
    grad = gold_gradient((int(tw) + 4, 160), top=(255, 236, 170), bot=(222, 160, 40))
    tmask = Image.new("L", grad.size, 0)
    ImageDraw.Draw(tmask).text((0, 8), text, font=font, fill=255)
    ban.paste(grad, (680, 280), tmask)
    ban = ban.convert("RGB")
    ban.save("assets/icon/tv_banner.png")
    for dens, (w, h) in {"mdpi": (160, 90), "hdpi": (240, 135), "xhdpi": (320, 180),
                         "xxhdpi": (480, 270), "xxxhdpi": (640, 360)}.items():
        path = f"android/app/src/main/res/drawable-{dens}/vespertv_banner.png"
        try:
            cur = Image.open(path).size
        except OSError:
            cur = (w, h)
        ban.resize(cur, Image.LANCZOS).save(path)


if __name__ == "__main__":
    main()
