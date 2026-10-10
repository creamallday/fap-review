"""Draws the app icon and writes Packaging/AppIcon.iconset (needs Pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = Path(__file__).resolve().parent.parent / "Packaging" / "AppIcon.iconset"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def icon():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # macOS icon grid: 824pt rounded square centred on a 1024 canvas.
    box = (100, 100, 924, 924)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((100, 112, 924, 936), 185, fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))

    grad = Image.new("RGBA", (S, S))
    top, bottom = (58, 123, 246), (23, 63, 189)
    for y in range(S):
        ImageDraw.Draw(grad).line([(0, y), (S, y)], fill=lerp(top, bottom, y / S) + (255,))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, 185, fill=255)
    img.alpha_composite(Image.composite(grad, Image.new("RGBA", (S, S)), mask))

    # Page with folded corner.
    page = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(page)
    px0, py0, px1, py1, fold = 268, 200, 716, 824, 120
    d.polygon([(px0, py0), (px1 - fold, py0), (px1, py0 + fold), (px1, py1), (px0, py1)], fill=(255, 255, 255, 255))
    d.polygon([(px1 - fold, py0), (px1 - fold, py0 + fold), (px1, py0 + fold)], fill=(214, 224, 240, 255))
    pshadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(pshadow).polygon([(px0, py0 + 14), (px1 - fold, py0 + 14), (px1, py0 + fold + 14), (px1, py1 + 14), (px0, py1 + 14)], fill=(0, 0, 40, 80))
    img.alpha_composite(pshadow.filter(ImageFilter.GaussianBlur(16)))
    img.alpha_composite(page)

    d = ImageDraw.Draw(img)
    grey = (190, 199, 214, 255)
    red = (226, 60, 60, 255)
    ins = (31, 122, 72, 255)
    x0 = px0 + 62
    lines = [(330, 300), (392, 324), (454, 312), (516, 324), (578, 250), (640, 300), (702, 220)]
    for i, (y, w) in enumerate(lines):
        if i == 2:
            d.rounded_rectangle((x0, y, x0 + 120, y + 26), 13, fill=grey)
            d.rounded_rectangle((x0 + 140, y, x0 + w, y + 26), 13, fill=(244, 196, 196, 255))
            d.line((x0 + 130, y + 13, x0 + w + 10, y + 13), fill=red, width=10)
        elif i == 3:
            d.rounded_rectangle((x0, y, x0 + 100, y + 26), 13, fill=grey)
            d.rounded_rectangle((x0 + 120, y, x0 + w, y + 26), 13, fill=(190, 230, 205, 255))
            d.line((x0 + 120, y + 40, x0 + w, y + 40), fill=ins, width=8)
        else:
            d.rounded_rectangle((x0, y, x0 + w, y + 26), 13, fill=grey)

    # Comment bubble.
    bx0, by0, bx1, by1 = 600, 560, 836, 740
    bubble = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bubble)
    bd.rounded_rectangle((bx0, by0, bx1, by1), 44, fill=(255, 204, 0, 255))
    bd.polygon([(bx0 + 50, by1 - 10), (bx0 + 40, by1 + 60), (bx0 + 120, by1 - 10)], fill=(255, 204, 0, 255))
    bs = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(bs).rounded_rectangle((bx0, by0 + 12, bx1, by1 + 12), 44, fill=(0, 0, 0, 70))
    img.alpha_composite(bs.filter(ImageFilter.GaussianBlur(14)))
    img.alpha_composite(bubble)
    for i, w in enumerate([150, 110]):
        d.rounded_rectangle((bx0 + 42, by0 + 52 + i * 48, bx0 + 42 + w, by0 + 74 + i * 48), 11, fill=(255, 255, 255, 235))
    return img


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    base = icon()
    for size in (16, 32, 128, 256, 512):
        base.resize((size, size), Image.LANCZOS).save(OUT / f"icon_{size}x{size}.png")
        base.resize((size * 2, size * 2), Image.LANCZOS).save(OUT / f"icon_{size}x{size}@2x.png")
    base.save(OUT.parent / "AppIcon-1024.png")


main()
