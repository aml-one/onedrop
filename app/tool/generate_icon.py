from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "icon"
WIN_ICO = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"

MASTER = 1024
WORK_SCALE = 4
WORK = MASTER * WORK_SCALE
TILE_N = 4.0
TILE_INSET = 0.035
# OneMail-depth blue, a step darker than the pale sky draft.
TILE = ((93, 198, 206), (93, 159, 222), (124, 137, 224))
PEARL = ((255, 252, 255), (239, 229, 255), (204, 232, 255))


def sc(value: float) -> int:
    return round(value * WORK_SCALE)


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def diagonal_gradient(colors: tuple, size: int) -> Image.Image:
    image = Image.new("RGB", (size, size))
    pixels = image.load()
    denom = 2 * (size - 1) if size > 1 else 1
    for y in range(size):
        for x in range(size):
            t = (x + y) / denom
            if t <= 0.5:
                rgb = lerp(colors[0], colors[1], t * 2)
            else:
                rgb = lerp(colors[1], colors[2], (t - 0.5) * 2)
            pixels[x, y] = rgb
    return image.convert("RGBA")


def superellipse_mask(size: int, inset: float = TILE_INSET, n: float = TILE_N) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    margin = inset * (size - 1)
    a = max(((size - 1) - 2 * margin) / 2.0, 1.0)
    cx = cy = (size - 1) / 2.0
    curve: list[tuple[float, float]] = []
    for i in range(1440):
        angle = (math.tau * i) / 1440
        cosine = math.cos(angle)
        sine = math.sin(angle)
        x = cx + a * math.copysign(abs(cosine) ** (2.0 / n), cosine)
        y = cy + a * math.copysign(abs(sine) ** (2.0 / n), sine)
        curve.append((x, y))
    ImageDraw.Draw(mask).polygon(curve, fill=255)
    return mask


def droplet_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    cx = cy = (size - 1) / 2.0
    s = size * 0.34
    cy += size * 0.016
    tip = (cx, cy - s * 1.08)
    left = (cx - s * 0.70, cy + s * 0.18)
    bottom = (cx, cy + s * 0.98)
    right = (cx + s * 0.70, cy + s * 0.18)

    def cubic(p0, p1, p2, p3, steps: int = 48) -> list[tuple[float, float]]:
        pts: list[tuple[float, float]] = []
        for i in range(steps):
            t = i / (steps - 1)
            u = 1.0 - t
            pts.append(
                (
                    u * u * u * p0[0]
                    + 3 * u * u * t * p1[0]
                    + 3 * u * t * t * p2[0]
                    + t * t * t * p3[0],
                    u * u * u * p0[1]
                    + 3 * u * u * t * p1[1]
                    + 3 * u * t * t * p2[1]
                    + t * t * t * p3[1],
                )
            )
        return pts

    pts: list[tuple[float, float]] = []
    pts += cubic(tip, (cx - s * 0.18, cy - s * 0.55), (left[0], left[1] - s * 0.45), left)
    pts += cubic(left, (left[0] - s * 0.04, left[1] + s * 0.42), (cx - s * 0.42, bottom[1]), bottom)
    pts += cubic(bottom, (cx + s * 0.42, bottom[1]), (right[0] + s * 0.04, right[1] + s * 0.42), right)
    pts += cubic(right, (right[0], right[1] - s * 0.45), (cx + s * 0.18, cy - s * 0.55), tip)
    draw.polygon(pts, fill=255)
    return mask


def glass_rim(size: int, tile: Image.Image) -> Image.Image:
    outer = superellipse_mask(size, inset=TILE_INSET)
    inner = superellipse_mask(size, inset=TILE_INSET + 0.012)
    ring = ImageChops.subtract(outer, inner)
    shine = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    shine.putalpha(ring.point(lambda a: round(a * 0.30)))
    out = tile.copy()
    out.alpha_composite(shine)
    return out


def glyph_layer(mask: Image.Image) -> Image.Image:
    result = Image.new("RGBA", (WORK, WORK))
    shadow = Image.new("RGBA", (WORK, WORK), (70, 46, 126, 0))
    shifted = Image.new("L", (WORK, WORK))
    shifted.paste(mask, (0, sc(12)))
    blurred = shifted.filter(ImageFilter.GaussianBlur(sc(15)))
    shadow.putalpha(blurred.point(lambda alpha: round(alpha * 0.23)))
    result.alpha_composite(shadow)
    pearl = diagonal_gradient(PEARL, WORK)
    pearl.putalpha(mask)
    result.alpha_composite(pearl)
    highlight = Image.new("L", (WORK, WORK))
    highlight.paste(mask, (0, -sc(5)))
    edge = ImageChops.subtract(highlight, mask.filter(ImageFilter.GaussianBlur(sc(2))))
    shine = Image.new("RGBA", (WORK, WORK), (255, 255, 255, 0))
    shine.putalpha(edge.point(lambda alpha: round(alpha * 0.32)))
    result.alpha_composite(shine)
    return result


def paint_tile() -> Image.Image:
    tile_mask = superellipse_mask(WORK)
    tile = diagonal_gradient(TILE, WORK)
    tile.putalpha(tile_mask)
    tile = glass_rim(WORK, tile)

    drop = droplet_mask(WORK)
    tile.alpha_composite(glyph_layer(drop))
    return tile.resize((MASTER, MASTER), Image.Resampling.LANCZOS)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    family = (
        Path(r"C:\Users\ambru\source\repos\aml-systems\messageme")
        / "scripts"
        / "assets"
        / "app-icon-family"
        / "onedrop.png"
    )
    if family.exists():
        master = Image.open(family).convert("RGBA")
    else:
        master = paint_tile()
    master.save(OUT / "tray.png")
    master.save(OUT / "app_icon.png")
    mac_icons = (
        ROOT
        / "macos"
        / "Runner"
        / "Assets.xcassets"
        / "AppIcon.appiconset"
    )
    if mac_icons.is_dir():
        for edge in (16, 32, 64, 128, 256, 512, 1024):
            master.resize((edge, edge), Image.Resampling.LANCZOS).save(
                mac_icons / f"app_icon_{edge}.png",
            )
        print(f"wrote {mac_icons}")
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    WIN_ICO.parent.mkdir(parents=True, exist_ok=True)
    master.save(OUT / "tray.ico", format="ICO", sizes=sizes)
    master.save(WIN_ICO, format="ICO", sizes=sizes)
    print(f"wrote {OUT} and {WIN_ICO}")


if __name__ == "__main__":
    main()
