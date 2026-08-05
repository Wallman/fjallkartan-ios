#!/usr/bin/env python3
"""Generate the fjallkartan app icon (light / dark / tinted 1024pt variants).

Flat, layered fjäll landscape: a cream sky, worn-down blue-grey massifs and a
stack of teal water/mire bands, with a red kryssmarkering (the crossed slats
that mark Swedish winter trails) standing in the foreground.

Usage:  python3 Tools/make_app_icon.py
Writes: fjallkartan/Assets.xcassets/AppIcon.appiconset/*.png
"""

import math
import os
from PIL import Image, ImageDraw

SS = 4                      # supersampling factor
OUT = 1024                  # final icon size in px
S = OUT * SS                # render size

ASSET_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "fjallkartan", "Assets.xcassets", "AppIcon.appiconset",
)

# --- geometry, in normalised 0..1 coordinates -------------------------------
# Everything is bled slightly past the edges so the rounded icon mask never
# clips a seam.

LEFT, RIGHT = -0.05, 1.05
BOTTOM = 1.05


def gauss(x, cx, w):
    return math.exp(-((x - cx) / w) ** 2)


def sheet(fn, samples=320):
    """Polygon: the curve y = fn(x) closed down to the bottom edge."""
    pts = [(LEFT + (RIGHT - LEFT) * k / samples,
            fn(LEFT + (RIGHT - LEFT) * k / samples)) for k in range(samples + 1)]
    return pts + [(RIGHT, BOTTOM), (LEFT, BOTTOM)]


def lens(cx, cy, half_w, half_h, tilt=0.0, samples=64):
    """Slim leaf shape used for the snow patches on the far massif."""
    ca, sa = math.cos(tilt), math.sin(tilt)
    pts = []
    for k in range(samples + 1):
        t = k / samples
        u = (t * 2 - 1) * half_w
        v = half_h * (1 - (u / half_w) ** 2) ** 1.4
        pts.append((u, v))
    for k in range(samples + 1):
        t = 1 - k / samples
        u = (t * 2 - 1) * half_w
        v = -half_h * (1 - (u / half_w) ** 2) ** 1.4 * 0.55
        pts.append((u, v))
    return [(cx + u * ca - v * sa, cy + u * sa + v * ca) for u, v in pts]


# Two worn-down massifs. Swedish fjäll are whale-backed domes, so the ridges
# are broad gaussians rather than alpine spires.
def far_ridge(x):
    return (0.330
            - 0.150 * gauss(x, 0.70, 0.27)
            - 0.048 * gauss(x, 0.24, 0.20)
            - 0.020 * gauss(x, 0.44, 0.10)
            + 0.006 * math.sin(x * 7.0 + 1.2))


def near_ridge(x):
    return (0.450
            - 0.045 * gauss(x, 0.28, 0.30)
            - 0.030 * gauss(x, 0.88, 0.18)
            + 0.005 * math.sin(x * 5.4 - 0.6))


def water_band(y0, amp, freq, phase):
    def fn(x):
        return y0 + amp * (math.sin(x * freq + phase) + 0.4 * math.sin(x * freq * 2.3 - phase))
    return fn


FAR_MASSIF = sheet(far_ridge)
NEAR_MASSIF = sheet(near_ridge)
FOREGROUND = sheet(water_band(0.545, 0.016, 4.2, 0.6))

SNOW_PATCH = lens(0.735, 0.272, 0.115, 0.020, tilt=math.radians(-9))
SNOW_SPECK = lens(0.560, 0.318, 0.040, 0.010, tilt=math.radians(-6))

# --- kryssmarkering ---------------------------------------------------------
# A tall stake carrying two crossed slats. The slats sit at a shallow angle,
# so the cross reads as wider than it is tall even at 16 px.
MARK_X, MARK_Y = 0.330, 0.560
MARK_ARM = 0.240          # half-length of a slat
MARK_THICK = 0.038        # half-thickness of a slat
MARK_ANGLE = 33           # degrees off horizontal
POLE_HALF_W = 0.026


def bar(cx, cy, half_len, half_th, angle):
    """Rectangle of the given length/thickness rotated about its centre."""
    ca, sa = math.cos(angle), math.sin(angle)
    corners = [(-half_len, -half_th), (half_len, -half_th),
               (half_len, half_th), (-half_len, half_th)]
    return [(cx + u * ca - v * sa, cy + u * sa + v * ca) for u, v in corners]


_A = math.radians(MARK_ANGLE)
CROSS_TOP = MARK_Y - (MARK_ARM * math.sin(_A) + MARK_THICK * math.cos(_A))
POLE_TOP = CROSS_TOP - 0.030   # the stake runs a little past the crossed slats
POLE = [(MARK_X - POLE_HALF_W, POLE_TOP), (MARK_X + POLE_HALF_W, POLE_TOP),
        (MARK_X + POLE_HALF_W, BOTTOM), (MARK_X - POLE_HALF_W, BOTTOM)]
CROSS = [bar(MARK_X, MARK_Y, MARK_ARM, MARK_THICK, _A),
         bar(MARK_X, MARK_Y, MARK_ARM, MARK_THICK, -_A)]


# --- drawing helpers --------------------------------------------------------

def px(pt):
    return (pt[0] * S, pt[1] * S)


def poly(points):
    return [px(p) for p in points]


def vertical_gradient(top, bottom):
    img = Image.new("RGB", (1, S))
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        d.point((0, y), tuple(round(top[k] + (bottom[k] - top[k]) * t) for k in range(3)))
    return img.resize((S, S), Image.BILINEAR)


def build(name, palette):
    img = vertical_gradient(*palette["sky"]).convert("RGBA")
    d = ImageDraw.Draw(img)

    d.polygon(poly(FAR_MASSIF), fill=palette["far"] + (255,))
    d.polygon(poly(SNOW_PATCH), fill=palette["snow"] + (255,))
    d.polygon(poly(SNOW_SPECK), fill=palette["snow"] + (255,))
    d.polygon(poly(NEAR_MASSIF), fill=palette["near"] + (255,))
    d.polygon(poly(FOREGROUND), fill=palette["fore"] + (255,))

    marker = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    md = ImageDraw.Draw(marker)
    md.polygon(poly(POLE), fill=palette["pole"] + (255,))
    # each slat is filled and rimmed before the next one goes on top, so the
    # two boards read as physically overlapping rather than as a flat X
    for arm in CROSS:
        md.polygon(poly(arm), fill=palette["cross"] + (255,))
        md.line(poly(arm) + [px(arm[0])], fill=palette["cross_edge"] + (255,),
                width=int(3.0 * SS), joint="curve")
    img.alpha_composite(marker)

    out = img.convert("RGB").resize((OUT, OUT), Image.LANCZOS)
    if palette.get("grayscale"):
        out = out.convert("L").convert("RGB")
    path = os.path.join(ASSET_DIR, name)
    out.save(path, format="PNG")
    print("wrote", path)
    return out


def mac_icons(art):
    """macOS icons are not masked by the system: inset the art into the
    standard 824/1024 rounded-square content box with transparent padding."""
    box, radius = 824, 185
    big = art.resize((box * 2, box * 2), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (box * 8, box * 8), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, box * 8 - 1, box * 8 - 1], radius=radius * 8, fill=255)
    big.putalpha(mask.resize((box * 2, box * 2), Image.LANCZOS))
    canvas = Image.new("RGBA", (OUT * 2, OUT * 2), (0, 0, 0, 0))
    canvas.paste(big, ((OUT * 2 - box * 2) // 2, (OUT * 2 - box * 2) // 2), big)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        p = os.path.join(ASSET_DIR, f"AppIcon-mac-{size}.png")
        canvas.resize((size, size), Image.LANCZOS).save(p, format="PNG")
    print("wrote macOS icon sizes")


LIGHT = {
    "sky": ((246, 228, 190), (250, 240, 214)),
    "far": (150, 175, 176),
    "snow": (216, 231, 226),
    "near": (118, 154, 155),
    "fore": (52, 94, 101),
    "pole": (32, 58, 62),
    "cross": (196, 82, 62),
    "cross_edge": (158, 60, 44),
}

DARK = {
    "sky": ((44, 54, 72), (96, 92, 96)),
    "far": (58, 76, 88),
    "snow": (110, 128, 134),
    "near": (44, 62, 72),
    "fore": (26, 44, 52),
    "pole": (12, 22, 26),
    "cross": (188, 76, 58),
    "cross_edge": (140, 50, 38),
}

TINTED = {
    "sky": ((84, 84, 84), (108, 108, 108)),
    "far": (72, 72, 72),
    "snow": (128, 128, 128),
    "near": (58, 58, 58),
    "fore": (32, 32, 32),
    "pole": (8, 8, 8),
    "cross": (244, 244, 244),
    "cross_edge": (206, 206, 206),
    "grayscale": True,
}

if __name__ == "__main__":
    os.makedirs(ASSET_DIR, exist_ok=True)
    light = build("AppIcon-1024.png", LIGHT)
    build("AppIcon-1024-dark.png", DARK)
    build("AppIcon-1024-tinted.png", TINTED)
    mac_icons(light)
