#!/usr/bin/env python3
"""Composes App Store screenshots from raw simulator captures.

Takes the PNGs written by tools/capture_screenshots.sh and places each one in a
rounded device frame on a coloured background, with a headline and subtitle
above it. Output is 1320x2868, the 6.9" iPhone size App Store Connect expects.

    tools/compose_screenshots.py [--raw DIR] [--out DIR] [--lang LANG] [scene ...]
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


def _icon_palette() -> dict:
    """The app icon's own light-mode colours, imported so the screenshots and
    the icon can never drift apart."""
    path = Path(__file__).resolve().parent / "make_app_icon.py"
    spec = importlib.util.spec_from_file_location("make_app_icon", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.LIGHT


PALETTE = _icon_palette()
SKY_LIGHT, SKY_DEEP = (PALETTE["sky"][1], PALETTE["sky"][0])
SNOW = PALETTE["snow"]      # pale ice
FAR = PALETTE["far"]        # blue-grey massif
NEAR = PALETTE["near"]      # teal-grey massif
FORE = PALETTE["fore"]      # deep teal foreground
POLE = PALETTE["pole"]      # near-black teal of the trail marker post
CROSS = PALETTE["cross"]    # red of the kryssmarkering


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def _relative_luminance(colour: tuple[int, int, int]) -> float:
    channels = [c / 255 for c in colour]
    channels = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def contrast_ratio(a: tuple[int, int, int], b: tuple[int, int, int]) -> float:
    light, dark = sorted((_relative_luminance(a), _relative_luminance(b)), reverse=True)
    return (light + 0.05) / (dark + 0.05)

CANVAS = (1320, 2868)
SF_PRO = "/System/Library/Fonts/SFNS.ttf"
# SF Pro has no CJK coverage, so Chinese sets in Hiragino Sans GB instead.
HIRAGINO_GB = "/System/Library/Fonts/Hiragino Sans GB.ttc"
HIRAGINO_FACE = {"Bold": 2, "Semibold": 2, "Medium": 0, "Regular": 0}

DEFAULT_LANGUAGE = "en"
LANGUAGES = ["en", "sv", "nb", "da", "fi", "de", "fr", "it", "es", "nl", "zh-Hans"]

# Widest a caption line may run before it gets scaled down.
TEXT_SAFE_WIDTH = 1150

# Device geometry, as fractions of the canvas.
DEVICE_WIDTH = 0.76
DEVICE_TOP = 0.255
DEVICE_CORNER = 0.125  # 55pt corner radius over a 440pt-wide screen
BEZEL = 9

# Where the caption block starts; balanced against the device frame below it.
CAPTION_TOP = 176

SCENES = [
    {"raw": "map", "out": "01-map",
     "background": (SKY_LIGHT, SKY_DEEP), "ink": POLE, "muted": FORE},
    {"raw": "measure", "out": "02-measure",
     "background": (FORE, POLE), "ink": SKY_LIGHT, "muted": mix(SNOW, NEAR, 0.35)},
    {"raw": "offline", "out": "03-offline",
     "background": (SNOW, FAR), "ink": POLE, "muted": mix(FORE, POLE, 0.3)},
    {"raw": "search", "out": "04-search",
     "background": (SKY_DEEP, mix(SKY_DEEP, CROSS, 0.42)), "ink": POLE,
     "muted": mix(FORE, POLE, 0.3)},
]

# Caption copy per language. The line breaks are deliberate: each one is where
# the headline or subtitle should wrap. A line that still runs too wide is
# scaled down by `fitted_font` rather than spilling off the canvas.
COPY = {
    "en": {
        "map": ("Norway and Sweden\non one seamless map",
                "Official topographic maps from Kartverket\nand Lantm\u00e4teriet, stitched across the border"),
        "measure": ("Trace a route,\nread the distance",
                    "Draw with your finger and get true geodesic\nlength \u2014 accurate this far north"),
        "offline": ("Works where\nthere is no signal",
                    "Download any area in advance and keep\nreading the terrain without coverage"),
        "search": ("Find any peak,\nlake or cabin",
                   "1.6 million Swedish and Norwegian place\nnames, searchable offline"),
    },
    "sv": {
        "map": ("Norge och Sverige\np\u00e5 en s\u00f6ml\u00f6s karta",
                "Officiella topografiska kartor fr\u00e5n Kartverket\noch Lantm\u00e4teriet, sammanfogade \u00f6ver gr\u00e4nsen"),
        "measure": ("Rita en rutt,\nse avst\u00e5ndet",
                    "Dra med fingret och f\u00e5 verkligt geodetiskt\navst\u00e5nd \u2014 korrekt s\u00e5 h\u00e4r l\u00e5ngt norrut"),
        "offline": ("Fungerar d\u00e4r\nt\u00e4ckningen tar slut",
                    "Ladda ner ett omr\u00e5de i f\u00f6rv\u00e4g och forts\u00e4tt\nl\u00e4sa terr\u00e4ngen utan uppkoppling"),
        "search": ("Hitta varje topp,\nsj\u00f6 och stuga",
                   "1,6 miljoner svenska och norska ortnamn,\ns\u00f6kbara utan uppkoppling"),
    },
    "nb": {
        "map": ("Norge og Sverige\np\u00e5 ett s\u00f8ml\u00f8st kart",
                "Offisielle topografiske kart fra Kartverket\nog Lantm\u00e4teriet, sydd sammen over grensen"),
        "measure": ("Tegn en rute,\nles av avstanden",
                    "Dra med fingeren og f\u00e5 ekte geodetisk\nlengde \u2014 riktig s\u00e5 langt nord"),
        "offline": ("Virker der\ndekningen tar slutt",
                    "Last ned et omr\u00e5de p\u00e5 forh\u00e5nd og fortsett\n\u00e5 lese terrenget uten dekning"),
        "search": ("Finn hver topp,\nvann og hytte",
                   "1,6 millioner svenske og norske stedsnavn,\ns\u00f8kbare uten nett"),
    },
    "da": {
        "map": ("Norge og Sverige\np\u00e5 \u00e9t s\u00f8ml\u00f8st kort",
                "Officielle topografiske kort fra Kartverket\nog Lantm\u00e4teriet, syet sammen over gr\u00e6nsen"),
        "measure": ("Tegn en rute,\nafl\u00e6s afstanden",
                    "Tegn med fingeren og f\u00e5 den \u00e6gte geod\u00e6tiske\nl\u00e6ngde \u2014 pr\u00e6cis s\u00e5 langt mod nord"),
        "offline": ("Virker der,\nhvor d\u00e6kningen slipper",
                    "Hent et omr\u00e5de p\u00e5 forh\u00e5nd, og bliv ved med\nat l\u00e6se terr\u00e6net uden d\u00e6kning"),
        "search": ("Find hver top,\ns\u00f8 og hytte",
                   "1,6 millioner svenske og norske stednavne,\nder kan s\u00f8ges offline"),
    },
    "fi": {
        "map": ("Norja ja Ruotsi\nsamalla kartalla",
                "Kartverketin ja Lantm\u00e4terietin viralliset\ntopografiset kartat, saumattomasti yhdess\u00e4"),
        "measure": ("Piirr\u00e4 reitti,\nlue matka",
                    "Ved\u00e4 sormella ja saat todellisen geodeettisen\npituuden \u2014 tarkka n\u00e4inkin pohjoisessa"),
        "offline": ("Toimii siell\u00e4,\nmiss\u00e4 kuuluvuus loppuu",
                    "Lataa alue etuk\u00e4teen ja jatka maaston\nlukemista ilman verkkoyhteytt\u00e4"),
        "search": ("L\u00f6yd\u00e4 jokainen huippu,\nj\u00e4rvi ja tupa",
                   "1,6 miljoonaa ruotsalaista ja norjalaista\npaikannime\u00e4, haettavissa ilman verkkoa"),
    },
    "de": {
        "map": ("Norwegen und Schweden\nauf einer nahtlosen Karte",
                "Amtliche topografische Karten von Kartverket\nund Lantm\u00e4teriet, \u00fcber die Grenze hinweg vereint"),
        "measure": ("Route ziehen,\nDistanz ablesen",
                    "Mit dem Finger zeichnen und die echte geod\u00e4tische\nL\u00e4nge erhalten \u2014 auch hoch im Norden genau"),
        "offline": ("Funktioniert auch\nohne Empfang",
                    "Ein Gebiet vorab herunterladen und das Gel\u00e4nde\nweiterlesen, wo kein Netz mehr ist"),
        "search": ("Jeder Gipfel,\nSee und jede H\u00fctte",
                   "1,6 Millionen schwedische und norwegische\nOrtsnamen, auch offline durchsuchbar"),
    },
    "fr": {
        "map": ("La Norv\u00e8ge et la Su\u00e8de\nsur une carte continue",
                "Les cartes topographiques officielles de Kartverket\net Lantm\u00e4teriet, assembl\u00e9es par-del\u00e0 la fronti\u00e8re"),
        "measure": ("Tracez un itin\u00e9raire,\nlisez la distance",
                    "Dessinez du doigt et obtenez la vraie longueur\ng\u00e9od\u00e9sique \u2014 pr\u00e9cise jusqu'au Grand Nord"),
        "offline": ("Fonctionne l\u00e0 o\u00f9\nle r\u00e9seau s'arr\u00eate",
                    "T\u00e9l\u00e9chargez une zone \u00e0 l'avance et continuez\n\u00e0 lire le terrain sans couverture"),
        "search": ("Chaque sommet,\nlac et refuge",
                   "1,6 million de noms de lieux su\u00e9dois et\nnorv\u00e9giens, consultables hors ligne"),
    },
    "it": {
        "map": ("Norvegia e Svezia\nsu un'unica mappa",
                "Le mappe topografiche ufficiali di Kartverket\ne Lantm\u00e4teriet, unite oltre il confine"),
        "measure": ("Traccia un percorso,\nleggi la distanza",
                    "Disegna con il dito e ottieni la vera distanza\ngeodetica \u2014 precisa anche all'estremo nord"),
        "offline": ("Funziona dove\nnon c'\u00e8 campo",
                    "Scarica un'area in anticipo e continua\na leggere il terreno senza copertura"),
        "search": ("Ogni cima,\nlago e rifugio",
                   "1,6 milioni di toponimi svedesi e norvegesi,\nconsultabili offline"),
    },
    "es": {
        "map": ("Noruega y Suecia\nen un solo mapa",
                "Mapas topogr\u00e1ficos oficiales de Kartverket\ny Lantm\u00e4teriet, unidos a trav\u00e9s de la frontera"),
        "measure": ("Traza la ruta,\nlee la distancia",
                    "Dibuja con el dedo y obt\u00e9n la distancia\ngeod\u00e9sica real \u2014 precisa en el extremo norte"),
        "offline": ("Funciona donde\nno hay cobertura",
                    "Descarga cualquier zona por adelantado y sigue\nleyendo el terreno sin conexi\u00f3n"),
        "search": ("Cada cima,\nlago y caba\u00f1a",
                   "1,6 millones de top\u00f3nimos suecos y noruegos,\ndisponibles sin conexi\u00f3n"),
    },
    "nl": {
        "map": ("Noorwegen en Zweden\nop \u00e9\u00e9n naadloze kaart",
                "Offici\u00eble topografische kaarten van Kartverket\nen Lantm\u00e4teriet, naadloos over de grens heen"),
        "measure": ("Teken een route,\nlees de afstand",
                    "Teken met je vinger en krijg de echte geodetische\nlengte \u2014 ook hoog in het noorden nauwkeurig"),
        "offline": ("Werkt waar\ngeen bereik is",
                    "Download vooraf een gebied en blijf het\nterrein lezen zonder verbinding"),
        "search": ("Elke top,\nelk meer en elke hut",
                   "1,6 miljoen Zweedse en Noorse plaatsnamen,\nook offline doorzoekbaar"),
    },
    "zh-Hans": {
        "map": ("\u632a\u5a01\u4e0e\u745e\u5178\n\u540c\u5728\u4e00\u5f20\u5730\u56fe\u4e0a",
                "Kartverket \u4e0e Lantm\u00e4teriet \u7684\u5b98\u65b9\u5730\u5f62\u56fe\uff0c\n\u8de8\u8d8a\u56fd\u754c\u65e0\u7f1d\u62fc\u63a5"),
        "measure": ("\u624b\u6307\u4e00\u5212\uff0c\n\u8ddd\u79bb\u5373\u73b0",
                    "\u7528\u624b\u6307\u63cf\u7ed8\u8def\u7ebf\uff0c\u5f97\u5230\u771f\u5b9e\u7684\u5927\u5730\u7ebf\u8ddd\u79bb\uff0c\n\u5728\u9ad8\u7eac\u5ea6\u5730\u533a\u4f9d\u7136\u7cbe\u51c6"),
        "offline": ("\u6ca1\u6709\u4fe1\u53f7\uff0c\n\u7167\u6837\u80fd\u7528",
                    "\u63d0\u524d\u4e0b\u8f7d\u4efb\u610f\u533a\u57df\uff0c\n\u5728\u65e0\u7f51\u7edc\u8986\u76d6\u5904\u7ee7\u7eed\u8bfb\u56fe"),
        "search": ("\u6bcf\u4e00\u5ea7\u5c71\u5cf0\n\u90fd\u6709\u540d\u5b57",
                   "160 \u4e07\u4e2a\u745e\u5178\u4e0e\u632a\u5a01\u5730\u540d\uff0c\n\u79bb\u7ebf\u4ea6\u53ef\u641c\u7d22"),
    },
}


def font(size: int, weight: str, language: str = DEFAULT_LANGUAGE) -> ImageFont.FreeTypeFont:
    if language.startswith("zh"):
        return ImageFont.truetype(HIRAGINO_GB, size, index=HIRAGINO_FACE[weight])
    face = ImageFont.truetype(SF_PRO, size)
    face.set_variation_by_name(weight)
    return face


def fitted_font(draw: ImageDraw.ImageDraw, text: str, size: int, weight: str,
                language: str) -> ImageFont.FreeTypeFont:
    """The largest size at or below `size` that keeps every line inside the
    safe width. Languages set longer than English (German, Finnish) would
    otherwise run off the canvas."""
    for candidate in range(size, int(size * 0.66), -2):
        face = font(candidate, weight, language)
        if all(draw.textlength(line, font=face) <= TEXT_SAFE_WIDTH
               for line in text.split("\n")):
            return face
    return font(int(size * 0.66), weight, language)


def vertical_gradient(size: tuple[int, int], top, bottom) -> Image.Image:
    """A one-pixel-wide gradient stretched to the canvas."""
    height = size[1]
    strip = Image.new("RGB", (1, height))
    for y in range(height):
        strip.putpixel((0, y), mix(top, bottom, y / max(height - 1, 1)))
    return strip.resize(size, Image.BILINEAR)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [(0, 0), (size[0] - 1, size[1] - 1)], radius=radius, fill=255
    )
    return mask


def draw_centered(draw: ImageDraw.ImageDraw, text: str, y: int, face, fill: str,
                  line_gap: int) -> int:
    """Draws centred lines from `y` downwards and returns the next free y."""
    for line in text.split("\n"):
        _, top, _, bottom = draw.textbbox((0, 0), line, font=face)
        width = draw.textlength(line, font=face)
        draw.text(((CANVAS[0] - width) / 2, y - top), line, font=face, fill=fill)
        y += (bottom - top) + line_gap
    return y


def check_contrast(scene: dict) -> None:
    """Caption text has to stay readable against its own background."""
    behind = mix(*scene["background"], CAPTION_TOP / CANVAS[1])
    for role, minimum in (("ink", 4.5), ("muted", 3.5)):
        ratio = contrast_ratio(scene[role], behind)
        if ratio < minimum:
            raise SystemExit(
                f"{scene['out']}: {role} contrast is only {ratio:.1f}:1 (need {minimum}:1)"
            )


def compose(scene: dict, raw_dir: Path, out_dir: Path,
            language: str = DEFAULT_LANGUAGE) -> Path:
    check_contrast(scene)
    headline, subtitle = COPY[language][scene["raw"]]
    shot = Image.open(raw_dir / f"{scene['raw']}.png").convert("RGB")

    canvas = vertical_gradient(CANVAS, *scene["background"]).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    y = draw_centered(draw, headline, CAPTION_TOP,
                      fitted_font(draw, headline, 96, "Bold", language),
                      scene["ink"], line_gap=26)
    y += 30
    y = draw_centered(draw, subtitle, y,
                      fitted_font(draw, subtitle, 41, "Medium", language),
                      scene["muted"], line_gap=16)

    # Device frame
    screen_w = round(CANVAS[0] * DEVICE_WIDTH)
    screen_h = round(screen_w * shot.height / shot.width)
    radius = round(screen_w * DEVICE_CORNER)
    shot = shot.resize((screen_w, screen_h), Image.LANCZOS).convert("RGBA")
    shot.putalpha(rounded_mask(shot.size, radius))

    frame_w, frame_h = screen_w + BEZEL * 2, screen_h + BEZEL * 2
    frame = Image.new("RGBA", (frame_w, frame_h), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle(
        [(0, 0), (frame_w - 1, frame_h - 1)], radius=radius + BEZEL, fill=(24, 24, 26, 255)
    )
    frame.alpha_composite(shot, (BEZEL, BEZEL))

    left = (CANVAS[0] - frame_w) // 2
    top = round(CANVAS[1] * DEVICE_TOP)
    if y > top:
        raise SystemExit(
            f"{language}/{scene['out']}: caption runs into the device frame ({y}px)"
        )

    shadow = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [(left, top + 26), (left + frame_w, top + frame_h + 26)],
        radius=radius + BEZEL,
        fill=(0, 0, 0, 105),
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(34)))
    canvas.alpha_composite(frame, (left, top))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{scene['out']}.png"
    canvas.convert("RGB").save(path, "PNG")
    return path


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, default=root / "marketing" / "raw",
                        help="captures directory; per-language subdirectories are used")
    parser.add_argument("--out", type=Path, default=root / "marketing" / "appstore",
                        help="output directory; per-language subdirectories are created")
    parser.add_argument("--lang", action="append", choices=LANGUAGES, metavar="LANG",
                        help=f"language to compose, repeatable (default: all of "
                             f"{', '.join(LANGUAGES)})")
    parser.add_argument("scenes", nargs="*", help="raw scene names to compose (default: all)")
    args = parser.parse_args()

    wanted = set(args.scenes)
    for language in args.lang or LANGUAGES:
        for scene in SCENES:
            if wanted and scene["raw"] not in wanted:
                continue
            print(compose(scene, args.raw / language, args.out / language, language))


if __name__ == "__main__":
    main()
