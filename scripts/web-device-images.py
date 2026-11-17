#!/usr/bin/env python3
"""Build the website's phone images: real app screenshots composited into the official
iPhone Duo bezels, flattened, and saved as WebP in web/app/assets/.

Only the flattened composites go on the site and in the repo. The raw bezel PNGs are
licensed product images: keep them outside the repo and never copy them into web/app.

Usage (needs Pillow with WebP; FreeCAD's bundled Python has it):
  /Applications/FreeCAD.app/Contents/Resources/bin/python scripts/web-device-images.py \
      [/path/to/assets-folder-with-bezels-and-screens]

The assets folder holds bezel-inner.png (Inner Open Landscape, screen opening x120 y120
w2853 h2007), bezel-cover.png (Outer Closed Portrait, opening x88 y80 w1398 h2034) and
screens/<name>.png (1902x1338 inner screens, folded.png for the cover).
"""
import os
import sys
from PIL import Image

SRC = sys.argv[1] if len(sys.argv) > 1 else "/Users/user/Movies/MotionVideo/duo-dash-v2/assets"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "web", "app", "assets")

INNER_OPENING = (120, 120, 2853, 2007)
COVER_OPENING = (88, 80, 1398, 2034)
HINGE_X = 1546.5  # bezel midline of the inner image

INNER_SCREENS = ["home-unfolded", "maps-route", "music-player", "phone", "assistant"]


def composite(bezel_name, screen_name, opening):
    bezel = Image.open(os.path.join(SRC, bezel_name)).convert("RGBA")
    screen = Image.open(os.path.join(SRC, "screens", screen_name + ".png")).convert("RGBA")
    x, y, w, h = opening
    canvas = Image.new("RGBA", bezel.size, (0, 0, 0, 0))
    canvas.paste(screen.resize((w, h), Image.LANCZOS), (x, y))
    canvas.alpha_composite(bezel)  # the bezel's rounded opening masks the screen corners
    return canvas


def save(img, name, width, quality=82):
    if img.width != width:
        img = img.resize((width, round(img.height * width / img.width)), Image.LANCZOS)
    path = os.path.join(OUT, name + ".webp")
    img.save(path, "WEBP", quality=quality, alpha_quality=90, method=6)
    print(f"{path}  {img.width}x{img.height}  {os.path.getsize(path) // 1024} KB")


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in INNER_SCREENS:
        img = composite("bezel-inner.png", name, INNER_OPENING)
        save(img, f"duo-{name}-1600", 1600)
        save(img, f"duo-{name}-800", 800)
        if name == "home-unfolded":
            # Halves for the fold animation, split at the hinge (1 px overlap hides the seam).
            cut = int(HINGE_X)
            left = img.crop((0, 0, cut + 1, img.height))
            right = img.crop((cut, 0, img.width, img.height))
            for scale, suffix in ((2200 / 3093, "2200"), (1100 / 3093, "1100")):  # by full-device width
                w = round(left.width * scale)
                save(left, f"duo-fold-left-{suffix}", w)
                save(right, f"duo-fold-right-{suffix}", w)
    cover = composite("bezel-cover.png", "folded", COVER_OPENING)
    save(cover, "duo-cover-1120", 1120)
    save(cover, "duo-cover-560", 560)


if __name__ == "__main__":
    main()
