"""
SINdle decoy cover generator.

Makes a plain, boring cover (cover.jpg) for the decoy book. Edit the settings
below, then run:

    pip install pillow
    python make_cover.py

The cover is written next to this script. Then add it to your book in Calibre
(Edit metadata -> Change cover) or rebuild the book as described in README.md.
"""
import os
from PIL import Image, ImageDraw, ImageFont

# ------------------------------------------------------------------ settings
TITLE_LINES = ["The Extensive", "Analysis of the", "Color Brown"]  # one entry per line
SUBTITLE = "The Non-Illustrated Edition"
AUTHOR = "H. R. UMBER"
FOOTER = "Volume I of IV"
BACKGROUND = (110, 78, 52)    # brown (R, G, B)
TEXT_COLOR = (232, 220, 200)  # cream
OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cover.jpg")
# ---------------------------------------------------------------------------

W, H = 1200, 1800

SERIF = ["georgia.ttf", "Georgia.ttf", "DejaVuSerif.ttf", "LiberationSerif-Regular.ttf",
         "Times New Roman.ttf", "times.ttf"]
SERIF_ITALIC = ["georgiai.ttf", "Georgia Italic.ttf", "DejaVuSerif-Italic.ttf",
                "LiberationSerif-Italic.ttf", "Times New Roman Italic.ttf", "timesi.ttf"]
FONT_DIRS = [r"C:\Windows\Fonts", "/Library/Fonts", "/System/Library/Fonts/Supplemental",
             "/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/truetype/liberation",
             os.path.expanduser("~/.fonts"), os.path.expanduser("~/Library/Fonts")]


def font(candidates, size):
    for name in candidates:
        for d in FONT_DIRS:
            path = os.path.join(d, name)
            if os.path.exists(path):
                return ImageFont.truetype(path, size)
        try:
            return ImageFont.truetype(name, size)  # let Pillow search
        except OSError:
            pass
    return ImageFont.load_default()


img = Image.new("RGB", (W, H), BACKGROUND)
draw = ImageDraw.Draw(img)
draw.rectangle([60, 60, W - 60, H - 60], outline=TEXT_COLOR, width=4)
draw.rectangle([80, 80, W - 80, H - 80], outline=TEXT_COLOR, width=1)


def centered(y, text, f):
    draw.text((W / 2, y), text, font=f, fill=TEXT_COLOR, anchor="mt")


title_font = font(SERIF, 92)
y = 420
for line in TITLE_LINES:
    centered(y, line, title_font)
    y += 120
draw.line([(W / 2 - 160, y + 40), (W / 2 + 160, y + 40)], fill=TEXT_COLOR, width=2)
centered(y + 90, SUBTITLE, font(SERIF_ITALIC, 52))
centered(H - 300, AUTHOR, font(SERIF, 46))
centered(H - 230, FOOTER, font(SERIF_ITALIC, 38))

img.save(OUTPUT, quality=90)
print("Saved", OUTPUT)
