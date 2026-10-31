#!/usr/bin/env python3
"""Generate Edge AI launcher icons (legacy + adaptive foreground)."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "app" / "android" / "app" / "src" / "main" / "res"
PRIMARY = (146, 51, 38, 255)
WHITE = (255, 255, 255, 255)
SIZE = 1024
SCALE = 4


def draw_mark() -> Image.Image:
    canvas = SIZE * SCALE
    image = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    bar_h = 112 * SCALE
    gap = 40 * SCALE
    left = 214 * SCALE
    widths = [600, 480, 360]
    total_h = bar_h * 3 + gap * 2
    top = (canvas - total_h) // 2
    radius = bar_h // 2

    # Three decreasing bars: an abstract E / edge mark.
    for index, width in enumerate(widths):
        y = top + index * (bar_h + gap)
        draw.rounded_rectangle(
            [left, y, left + width * SCALE, y + bar_h],
            radius=radius,
            fill=PRIMARY,
        )

    return image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def main() -> None:
    mark = draw_mark()

    legacy_sizes = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    foreground_sizes = {
        "mdpi": 108,
        "hdpi": 162,
        "xhdpi": 216,
        "xxhdpi": 324,
        "xxxhdpi": 432,
    }

    for density, size in legacy_sizes.items():
        icon = Image.new("RGBA", (size, size), WHITE)
        inner = int(size * 0.95)
        icon.alpha_composite(
            mark.resize((inner, inner), Image.Resampling.LANCZOS),
            ((size - inner) // 2, (size - inner) // 2),
        )
        icon.save(RES / f"mipmap-{density}" / "ic_launcher.png")

    for density, size in foreground_sizes.items():
        foreground = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        inner = int(size * 1.02)
        foreground.alpha_composite(
            mark.resize((inner, inner), Image.Resampling.LANCZOS),
            ((size - inner) // 2, (size - inner) // 2),
        )
        foreground.save(RES / f"mipmap-{density}" / "ic_launcher_foreground.png")

    master = Image.new("RGBA", (SIZE, SIZE), WHITE)
    master.alpha_composite(mark)
    master.convert("RGB").save(ROOT / "dist" / "edge-ai-icon.png")

    print("icons generated")


if __name__ == "__main__":
    main()
