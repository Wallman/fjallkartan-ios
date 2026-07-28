#!/usr/bin/env python3
"""Generate the fjallkartan app icon (light / dark / tinted 1024pt variants).

The icon is a topographic map sheet: contour lines that follow the same height
field used to build the mountain silhouettes in the foreground.

Usage:  python3 Tools/make_app_icon.py
Writes: fjallkartan/Assets.xcassets/AppIcon.appiconset/*.png
"""

import math
import os
import random
from PIL import Image, ImageDraw, ImageFilter

SS = 4                      # supersampling factor
OUT = 1024                  # final icon size in px
S = OUT * SS                # render size
GRID = 220                  # height-field resolution for the contour tracing

ASSET_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "fjallkartan", "Assets.xcassets", "AppIcon.appiconset",
)

# --- geometry, in normalised 0..1 coordinates -------------------------------

BASE_Y = 1.06   # peaks run past the bottom edge of the icon


class Peak:
    """A fjäll built from two power-curve ridges meeting at the summit.

    x(y) = apex_x +/- width * t**exp, with t the normalised drop from the
    summit. Swedish fjäll are worn-down, whale-backed massifs rather than
    alpine spires, so exp < 1 is used: the profile widens fast just below the
    summit (a rounded dome) and then straightens out towards the base.
    """

    def __init__(self, apex, wl, wr, el=0.62, er=0.58, base=BASE_Y):
        self.apex = apex
        self.wl, self.wr, self.el, self.er, self.base = wl, wr, el, er, base

    def _t(self, y):
        return max(0.0, min(1.0, (y - self.apex[1]) / (self.base - self.apex[1])))

    def left_x(self, y):
        return self.apex[0] - self.wl * self._t(y) ** self.el

    def right_x(self, y):
        return self.apex[0] + self.wr * self._t(y) ** self.er

    def _ys(self, y_to, n):
        """Sample from the summit down to y_to, densest where curvature is."""
        return [self.apex[1] + (y_to - self.apex[1]) * (k / n) ** 1.8
                for k in range(n + 1)]

    def arc(self, side, y_to=None, n=32):
        f = self.left_x if side < 0 else self.right_x
        return [(f(y), y) for y in self._ys(self.base if y_to is None else y_to, n)]

    def outline(self):
        return list(reversed(self.arc(-1))) + self.arc(+1)[1:]

    def snow(self, y0, amp, teeth=6, seed=1):
        """Snow cap: the rounded summit dome closed by a ragged snow line.

        Points above y0 are rock breaking through the snow, points below are
        snow tongues running down the flank; both are jittered so the cap does
        not read as a row of identical spikes.
        """
        rnd = random.Random(seed)
        cap = list(reversed(self.arc(-1, y0, n=20))) + self.arc(+1, y0, n=20)[1:]
        lx, rx = self.left_x(y0), self.right_x(y0)
        line = []
        for k in range(teeth):
            f = (k + 0.5) / teeth + rnd.uniform(-0.3, 0.3) / teeth
            up = k % 2 == 0
            y = (y0 - amp * rnd.uniform(0.55, 1.0) if up
                 else y0 + amp * rnd.uniform(0.35, 0.9))
            x = lx + (rx - lx) * f
            eps = 0.014
            x = min(max(x, self.left_x(y) + eps), self.right_x(y) - eps)
            line.append((x, y))
        return cap + list(reversed(line))

    def lit_face(self, foot_x):
        """Sunlit flank: left ridge plus a fold line running off the summit."""
        return self.arc(-1) + [(foot_x, self.base), self.apex]


FRONT = Peak((0.395, 0.305), wl=0.50, wr=0.60, el=0.76, er=0.70)
BACK = Peak((0.815, 0.480), wl=0.38, wr=0.44, el=0.74, er=0.67)
FAR = Peak((0.070, 0.555), wl=0.30, wr=0.44, el=0.74, er=0.67)

FRONT_PEAK = FRONT.outline()
BACK_PEAK = BACK.outline()
FAR_PEAK = FAR.outline()
FRONT_FACE = FRONT.lit_face(0.33)
SNOW_FRONT = FRONT.snow(0.445, 0.036, teeth=7, seed=7)
SNOW_BACK = BACK.snow(0.585, 0.026, teeth=5, seed=3)
SNOW_FAR = FAR.snow(0.650, 0.022, teeth=5, seed=11)

# --- kryssmarkering ---------------------------------------------------------
# Swedish winter trails are marked with a tall pole carrying a red cross made
# of two crossed slats. The slats are long, thin and set at a shallow angle,
# so the cross is noticeably wider than it is tall.
MARK_X, MARK_Y = 0.228, 0.680
MARK_ARM = 0.115          # half-length of a slat
MARK_THICK = 0.0215       # half-thickness of a slat
MARK_ANGLE = 32           # degrees off horizontal
POLE_HALF_W = 0.0125


def bar(cx, cy, half_len, half_th, angle):
    """Rectangle of the given length/thickness rotated about its centre."""
    ca, sa = math.cos(angle), math.sin(angle)
    corners = [(-half_len, -half_th), (half_len, -half_th),
               (half_len, half_th), (-half_len, half_th)]
    return [(cx + u * ca - v * sa, cy + u * sa + v * ca) for u, v in corners]


_A = math.radians(MARK_ANGLE)
CROSS_TOP = MARK_Y - (MARK_ARM * math.sin(_A) + MARK_THICK * math.cos(_A))
POLE_TOP = CROSS_TOP - 0.026   # the stake runs on past the crossed slats
POLE = [(MARK_X - POLE_HALF_W, POLE_TOP), (MARK_X + POLE_HALF_W, POLE_TOP),
        (MARK_X + POLE_HALF_W, BASE_Y), (MARK_X - POLE_HALF_W, BASE_Y)]
CROSS = [bar(MARK_X, MARK_Y, MARK_ARM, MARK_THICK, _A),
         bar(MARK_X, MARK_Y, MARK_ARM, MARK_THICK, -_A)]

# gaussian bumps (x, y, amplitude, radius) shaping the contour height field
BUMPS = [
    (0.38, 0.74, 1.00, 0.40),
    (0.76, 0.86, 0.72, 0.32),
    (0.06, 0.52, 0.34, 0.22),
    (0.62, 0.30, 0.26, 0.20),
    (0.94, 0.34, 0.22, 0.18),
    (0.20, 0.16, 0.20, 0.19),
]


def height(x, y):
    h = 0.0
    for bx, by, amp, rad in BUMPS:
        d2 = ((x - bx) ** 2 + (y - by) ** 2) / (rad * rad)
        h += amp * math.exp(-d2)
    h += 0.16 * math.sin(x * 5.1 + 0.7) * math.cos(y * 4.3 - 0.4)
    return h


def height_field():
    return [[height(i / (GRID - 1), j / (GRID - 1)) for i in range(GRID)]
            for j in range(GRID)]


def marching_squares(field, level):
    """Return iso-level line segments in normalised coordinates."""
    segs = []
    n = GRID - 1

    def lerp(p, q, vp, vq):
        t = 0.5 if vq == vp else (level - vp) / (vq - vp)
        return (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)

    for j in range(n):
        for i in range(n):
            v = (field[j][i], field[j][i + 1], field[j + 1][i + 1], field[j + 1][i])
            case = sum(1 << k for k in range(4) if v[k] > level)
            if case in (0, 15):
                continue
            p = ((i / n, j / n), ((i + 1) / n, j / n),
                 ((i + 1) / n, (j + 1) / n), (i / n, (j + 1) / n))
            e = {
                0: lerp(p[0], p[1], v[0], v[1]),
                1: lerp(p[1], p[2], v[1], v[2]),
                2: lerp(p[2], p[3], v[2], v[3]),
                3: lerp(p[3], p[0], v[3], v[0]),
            }
            table = {
                1: [(3, 0)], 2: [(0, 1)], 3: [(3, 1)], 4: [(1, 2)],
                5: [(3, 2), (0, 1)], 6: [(0, 2)], 7: [(3, 2)],
                8: [(2, 3)], 9: [(2, 0)], 10: [(0, 3), (1, 2)],
                11: [(2, 1)], 12: [(1, 3)], 13: [(1, 0)], 14: [(0, 3)],
            }
            for a, b in table[case]:
                segs.append((e[a], e[b]))
    return segs


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


def draw_contours(base, field, color, minor_w, major_w, minor_a, major_a):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    step = 0.075
    levels = [step * k for k in range(1, int(1.75 / step) + 1)]
    for idx, lv in enumerate(levels):
        major = idx % 4 == 3
        w = major_w if major else minor_w
        a = major_a if major else minor_a
        rgba = color + (a,)
        for (p, q) in marching_squares(field, lv):
            d.line([px(p), px(q)], fill=rgba, width=int(w * SS), joint="curve")
    base.alpha_composite(layer)


def build(name, palette):
    img = vertical_gradient(*palette["bg"]).convert("RGBA")

    field = height_field()
    draw_contours(img, field, palette["contour"],
                  minor_w=2.6, major_w=5.0,
                  minor_a=palette["contour_a"][0], major_a=palette["contour_a"][1])

    # soft shadow under the ridges so the peaks read at small sizes
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    for outline in (FAR_PEAK, BACK_PEAK, FRONT_PEAK):
        sd.polygon(poly(outline), fill=(0, 0, 0, palette["shadow_a"]))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * SS))
    img.alpha_composite(shadow)

    peaks = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(peaks)
    d.polygon(poly(FAR_PEAK), fill=palette["far"] + (255,))
    d.polygon(poly(SNOW_FAR), fill=palette["snow_far"] + (255,))
    d.polygon(poly(BACK_PEAK), fill=palette["back"] + (255,))
    d.polygon(poly(SNOW_BACK), fill=palette["snow_back"] + (255,))
    d.polygon(poly(FRONT_PEAK), fill=palette["front"] + (255,))
    d.polygon(poly(FRONT_FACE), fill=palette["front_face"] + (255,))
    d.polygon(poly(SNOW_FRONT), fill=palette["snow"] + (255,))
    img.alpha_composite(peaks)

    marker = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    md = ImageDraw.Draw(marker)
    md.polygon(poly(POLE), fill=palette["pole"] + (255,))
    for arm in CROSS:
        md.polygon(poly(arm), fill=palette["cross"] + (255,))
    drop = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dd = ImageDraw.Draw(drop)
    dd.polygon(poly(POLE), fill=(0, 0, 0, 110))
    for arm in CROSS:
        dd.polygon(poly(arm), fill=(0, 0, 0, 110))
    img.alpha_composite(drop.filter(ImageFilter.GaussianBlur(10 * SS)))
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
    "bg": ((252, 249, 236), (228, 219, 186)),
    "contour": (168, 142, 78),
    "contour_a": (110, 165),
    "far": (162, 186, 150),
    "snow_far": (238, 246, 238),
    "back": (104, 142, 106),
    "snow_back": (226, 240, 228),
    "front": (26, 62, 46),
    "front_face": (42, 88, 62),
    "snow": (250, 254, 250),
    "pole": (226, 214, 184),
    "cross": (198, 40, 40),
    "shadow_a": 60,
}

DARK = {
    "bg": ((28, 38, 32), (12, 18, 15)),
    "contour": (86, 128, 100),
    "contour_a": (70, 120),
    "far": (28, 54, 42),
    "snow_far": (116, 152, 128),
    "back": (44, 86, 64),
    "snow_back": (152, 192, 168),
    "front": (84, 140, 104),
    "front_face": (104, 164, 124),
    "snow": (238, 250, 242),
    "pole": (206, 196, 172),
    "cross": (214, 58, 52),
    "shadow_a": 90,
}

TINTED = dict(DARK)
TINTED.update({
    "bg": ((26, 26, 26), (8, 8, 8)),
    "contour": (120, 120, 120),
    "contour_a": (80, 130),
    "far": (66, 66, 66),
    "snow_far": (140, 140, 140),
    "back": (100, 100, 100),
    "snow_back": (180, 180, 180),
    "front": (158, 158, 158),
    "front_face": (188, 188, 188),
    "snow": (252, 252, 252),
    "pole": (250, 250, 250),
    "cross": (108, 108, 108),
    "grayscale": True,
})

if __name__ == "__main__":
    os.makedirs(ASSET_DIR, exist_ok=True)
    light = build("AppIcon-1024.png", LIGHT)
    build("AppIcon-1024-dark.png", DARK)
    build("AppIcon-1024-tinted.png", TINTED)
    mac_icons(light)
