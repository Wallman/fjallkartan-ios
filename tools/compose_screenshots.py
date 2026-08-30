#!/usr/bin/env python3
"""Composes App Store screenshots from raw simulator captures.

Takes the PNGs written by tools/capture_screenshots.sh and places each one in a
rounded device frame on a coloured background, with a headline and subtitle
above it. Two device profiles are supported: "iphone" (1320x2868, the 6.9"
iPhone size) and "ipad" (2064x2752, the 13" iPad size), both App Store
Connect screenshot sizes. Both device profiles' raw captures are
language-neutral (raw/ and raw-ipad/ respectively) and reused for every
language's composed screenshot.

    tools/compose_screenshots.py [--raw-root DIR] [--out DIR] [--lang LANG]
        [--device iphone|ipad] [scene ...]

Output goes straight into the layout fastlane's deliver expects — one directory
per App Store locale, every device flat inside it — so there is no staging step
between composing and uploading. deliver picks the display family from each
PNG's pixel dimensions rather than its name or folder, which is what lets both
devices share a directory; it orders within a family alphanumerically, so the
`01-`..`05-` scene prefixes give the intended order and the non-default device
takes a name prefix to keep its own five contiguous.
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

SF_PRO = "/System/Library/Fonts/SFNS.ttf"
# SF Pro has no CJK coverage, so Chinese sets in Hiragino Sans GB instead.
HIRAGINO_GB = "/System/Library/Fonts/Hiragino Sans GB.ttc"
HIRAGINO_FACE = {"Bold": 2, "Semibold": 2, "Medium": 0, "Regular": 0}

DEFAULT_LANGUAGE = "en"
LANGUAGES = ["en", "sv", "nb", "da", "fi", "de", "fr", "it", "es", "nl", "zh-Hans"]

# Repo language tag -> App Store Connect locale, used for the output directory
# names. Apple's codes are not guessable: `no` not `nb`, `sv` not `sv-SE`, but
# `de-DE` not `de`. deliver refuses a directory name it doesn't recognise, so a
# wrong code fails the upload rather than quietly skipping that language.
DELIVER_LOCALES = {
    "en": "en-US",
    "sv": "sv",
    "nb": "no",
    "da": "da",
    "fi": "fi",
    "de": "de-DE",
    "nl": "nl-NL",
    "fr": "fr-FR",
    "it": "it",
    "es": "es-ES",
    "zh-Hans": "zh-Hans",
}

BEZEL = 9

# Where the caption block starts; balanced against the device frame below it.
CAPTION_TOP = 176

# Per-device canvas size and device-frame geometry (fractions of the canvas).
# The iPad captures are far less elongated than the iPhone's (13" iPad Pro
# screen ratio ~1.33 vs ~2.17 for the 6.9" iPhone), so a narrower device
# width keeps the frame from running into the caption above it.
DEVICES = {
    "iphone": {
        "canvas": (1320, 2868),
        "raw_dir_name": "raw",
        "per_locale_raw": False,
        # Filename prefix inside the locale directory. The default device takes
        # none so its scenes sort first; the other is prefixed, which also keeps
        # each family's five screenshots contiguous in deliver's ordering.
        "out_prefix": "",
        "device_width": 0.76,
        "device_top": 0.255,
        "device_corner": 0.125,  # 55pt corner radius over a 440pt-wide screen
        "text_safe_width": 1150,
    },
    "ipad": {
        "canvas": (2064, 2752),
        "raw_dir_name": "raw-ipad",
        "per_locale_raw": False,
        "out_prefix": "ipad-",
        "device_width": 0.69,
        "device_top": 0.266,
        "device_corner": 0.045,  # 18pt corner radius over a 1024pt-wide screen
        "text_safe_width": 1850,
    },
}
DEFAULT_DEVICE = "iphone"

SCENES = [
    {"raw": "map", "out": "01-map",
     "background": (SKY_LIGHT, SKY_DEEP), "ink": POLE, "muted": FORE},
    {"raw": "offline", "out": "02-offline",
     "background": (SNOW, FAR), "ink": POLE, "muted": mix(FORE, POLE, 0.3)},
    {"raw": "measure", "out": "03-measure",
     "background": (FORE, POLE), "ink": SKY_LIGHT, "muted": mix(SNOW, NEAR, 0.35)},
    {"raw": "search", "out": "04-search",
     "background": (SKY_DEEP, mix(SKY_DEEP, CROSS, 0.42)), "ink": POLE,
     "muted": mix(FORE, POLE, 0.3)},
    {"raw": "slope", "out": "05-slope",
     "background": (mix(SKY_LIGHT, CROSS, 0.16), mix(CROSS, POLE, 0.45)), "ink": POLE,
     "muted": mix(FORE, POLE, 0.3)},
]

# Caption copy per language. The line breaks are deliberate: each one is where
# the headline or subtitle should wrap. A line that still runs too wide is
# scaled down by `fitted_font` rather than spilling off the canvas.
COPY = {
    "en": {
        "map": ("Norway and Sweden\non one seamless map",
                "The official topographic maps of both\ncountries, stitched across the border"),
        "measure": ("Trace a route,\nsee the climb",
                    "Geodesic distance, ascent and descent with an\nelevation profile \u2014 and save the route for later"),
        "offline": ("Works where\nthere is no signal",
                    "Download any area in advance and keep\nreading the terrain without coverage"),
        "search": ("Find any peak,\nlake or cabin",
                   "1.6 million Swedish and Norwegian place\nnames, searchable offline"),
        "slope": ("Spot steep terrain\nbefore you go",
                  "Avalanche-terrain steepness for Norway and\nSweden, shaded over the topographic map"),
    },
    "sv": {
        "map": ("Norge och Sverige\np\u00e5 en s\u00f6ml\u00f6s karta",
                "Officiella topografiska kartor fr\u00e5n Kartverket\noch Lantm\u00e4teriet, sammanfogade \u00f6ver gr\u00e4nsen"),
        "measure": ("Rita en rutt,\nse stigningen",
                    "Geodetiskt avst\u00e5nd, stigning och fall med\nh\u00f6jdprofil \u2014 och spara rutten till senare"),
        "offline": ("Fungerar d\u00e4r\nt\u00e4ckningen tar slut",
                    "Ladda ner ett omr\u00e5de i f\u00f6rv\u00e4g och forts\u00e4tt\nl\u00e4sa terr\u00e4ngen utan uppkoppling"),
        "search": ("Hitta varje topp,\nsj\u00f6 och stuga",
                   "1,6 miljoner svenska och norska ortnamn,\ns\u00f6kbara utan uppkoppling"),
        "slope": ("Se brant terr\u00e4ng\ninnan du ger dig ut",
                  "Terr\u00e4nglutning f\u00f6r lavinbed\u00f6mning i Norge och\nSverige, ovanp\u00e5 den topografiska kartan"),
    },
    "nb": {
        "map": ("Norge og Sverige\np\u00e5 ett s\u00f8ml\u00f8st kart",
                "Offisielle topografiske kart fra Kartverket\nog Lantm\u00e4teriet, sydd sammen over grensen"),
        "measure": ("Tegn en rute,\nse stigningen",
                    "Geodetisk avstand, stigning og fall med\nh\u00f8ydeprofil \u2014 og lagre ruten til senere"),
        "offline": ("Virker der\ndekningen tar slutt",
                    "Last ned et omr\u00e5de p\u00e5 forh\u00e5nd og fortsett\n\u00e5 lese terrenget uten dekning"),
        "search": ("Finn hver topp,\nvann og hytte",
                   "1,6 millioner svenske og norske stedsnavn,\ns\u00f8kbare uten nett"),
        "slope": ("Se bratt terreng\nf\u00f8r du drar ut",
                  "Bratthetskart for lavineterreng i Norge og\nSverige, lagt over det topografiske kartet"),
    },
    "da": {
        "map": ("Norge og Sverige\np\u00e5 \u00e9t s\u00f8ml\u00f8st kort",
                "Officielle topografiske kort fra Kartverket\nog Lantm\u00e4teriet, syet sammen over gr\u00e6nsen"),
        "measure": ("Tegn en rute,\nse stigningen",
                    "Geod\u00e6tisk afstand, stigning og fald med\nh\u00f8jdeprofil \u2014 og gem ruten til senere"),
        "offline": ("Virker der,\nhvor d\u00e6kningen slipper",
                    "Hent et omr\u00e5de p\u00e5 forh\u00e5nd, og bliv ved med\nat l\u00e6se terr\u00e6net uden d\u00e6kning"),
        "search": ("Find hver top,\ns\u00f8 og hytte",
                   "1,6 millioner svenske og norske stednavne,\nder kan s\u00f8ges offline"),
        "slope": ("Se stejlt terr\u00e6n,\nf\u00f8r du tager af sted",
                  "Stejlhedskort til lavineterr\u00e6n i Norge og\nSverige, lagt oven p\u00e5 det topografiske kort"),
    },
    "fi": {
        "map": ("Norja ja Ruotsi\nsamalla kartalla",
                "Kartverketin ja Lantm\u00e4terietin viralliset\ntopografiset kartat, saumattomasti yhdess\u00e4"),
        "measure": ("Piirr\u00e4 reitti,\nn\u00e4e nousut",
                    "Geodeettinen matka, nousu ja lasku sek\u00e4\nkorkeusprofiili \u2014 ja tallenna reitti talteen"),
        "offline": ("Toimii siell\u00e4,\nmiss\u00e4 kuuluvuus loppuu",
                    "Lataa alue etuk\u00e4teen ja jatka maaston\nlukemista ilman verkkoyhteytt\u00e4"),
        "search": ("L\u00f6yd\u00e4 jokainen huippu,\nj\u00e4rvi ja tupa",
                   "1,6 miljoonaa ruotsalaista ja norjalaista\npaikannime\u00e4, haettavissa ilman verkkoa"),
        "slope": ("N\u00e4e jyrk\u00e4t rinteet\nennen l\u00e4ht\u00f6\u00e4",
                  "Lumivy\u00f6rymaaston jyrkkyys Norjassa ja\nRuotsissa, topografisen kartan p\u00e4\u00e4ll\u00e4"),
    },
    "de": {
        "map": ("Norwegen und Schweden\nauf einer nahtlosen Karte",
                "Die amtlichen topografischen Karten beider\nL\u00e4nder, \u00fcber die Grenze hinweg vereint"),
        "measure": ("Route ziehen,\nAnstieg sehen",
                    "Geod\u00e4tische Distanz, Auf- und Abstieg mit\nH\u00f6henprofil \u2014 und die Route sichern"),
        "offline": ("Funktioniert auch\nohne Empfang",
                    "Ein Gebiet vorab herunterladen und das Gel\u00e4nde\nweiterlesen, wo kein Netz mehr ist"),
        "search": ("Jeder Gipfel,\nSee und jede H\u00fctte",
                   "1,6 Millionen schwedische und norwegische\nOrtsnamen, auch offline durchsuchbar"),
        "slope": ("Steiles Gel\u00e4nde\nvorher erkennen",
                  "Hangneigung f\u00fcr Lawinengel\u00e4nde in Norwegen und\nSchweden, \u00fcber die topografische Karte gelegt"),
    },
    "fr": {
        "map": ("La Norv\u00e8ge et la Su\u00e8de\nsur une carte continue",
                "Les cartes topographiques officielles des deux\npays, assembl\u00e9es par-del\u00e0 la fronti\u00e8re"),
        "measure": ("Tracez un itin\u00e9raire,\nvoyez le d\u00e9nivel\u00e9",
                    "Distance g\u00e9od\u00e9sique, mont\u00e9e et descente avec\nprofil altim\u00e9trique \u2014 et enregistrez l'itin\u00e9raire"),
        "offline": ("Fonctionne l\u00e0 o\u00f9\nle r\u00e9seau s'arr\u00eate",
                    "T\u00e9l\u00e9chargez une zone \u00e0 l'avance et continuez\n\u00e0 lire le terrain sans couverture"),
        "search": ("Chaque sommet,\nlac et refuge",
                   "1,6 million de noms de lieux su\u00e9dois et\nnorv\u00e9giens, consultables hors ligne"),
        "slope": ("Rep\u00e9rez les pentes\navant de partir",
                  "L'inclinaison du terrain avalancheux en Norv\u00e8ge\net en Su\u00e8de, par-dessus la carte topographique"),
    },
    "it": {
        "map": ("Norvegia e Svezia\nsu un'unica mappa",
                "Le mappe topografiche ufficiali di entrambi\ni paesi, unite oltre il confine"),
        "measure": ("Traccia un percorso,\nvedi il dislivello",
                    "Distanza geodetica, salita e discesa con profilo\naltimetrico \u2014 e salva il percorso"),
        "offline": ("Funziona dove\nnon c'\u00e8 campo",
                    "Scarica un'area in anticipo e continua\na leggere il terreno senza copertura"),
        "search": ("Ogni cima,\nlago e rifugio",
                   "1,6 milioni di toponimi svedesi e norvegesi,\nconsultabili offline"),
        "slope": ("Vedi i pendii ripidi\nprima di partire",
                  "La pendenza del terreno valanghivo in Norvegia\ne Svezia, sopra la mappa topografica"),
    },
    "es": {
        "map": ("Noruega y Suecia\nen un solo mapa",
                "Los mapas topogr\u00e1ficos oficiales de ambos\npa\u00edses, unidos a trav\u00e9s de la frontera"),
        "measure": ("Traza la ruta,\nmira el desnivel",
                    "Distancia geod\u00e9sica, ascenso y descenso con\nperfil de altitud \u2014 y guarda la ruta"),
        "offline": ("Funciona donde\nno hay cobertura",
                    "Descarga cualquier zona por adelantado y sigue\nleyendo el terreno sin conexi\u00f3n"),
        "search": ("Cada cima,\nlago y caba\u00f1a",
                   "1,6 millones de top\u00f3nimos suecos y noruegos,\ndisponibles sin conexi\u00f3n"),
        "slope": ("Detecta las pendientes\nantes de salir",
                  "La inclinaci\u00f3n del terreno de aludes en Noruega\ny Suecia, sobre el mapa topogr\u00e1fico"),
    },
    "nl": {
        "map": ("Noorwegen en Zweden\nop \u00e9\u00e9n naadloze kaart",
                "De offici\u00eble topografische kaarten van beide\nlanden, naadloos over de grens heen"),
        "measure": ("Teken een route,\nzie de klim",
                    "Geodetische afstand, stijging en daling met\nhoogteprofiel \u2014 en bewaar de route"),
        "offline": ("Werkt waar\ngeen bereik is",
                    "Download vooraf een gebied en blijf het\nterrein lezen zonder verbinding"),
        "search": ("Elke top,\nelk meer en elke hut",
                   "1,6 miljoen Zweedse en Noorse plaatsnamen,\nook offline doorzoekbaar"),
        "slope": ("Zie steil terrein\nvoordat je vertrekt",
                  "Hellingshoek voor lawineterrein in Noorwegen\nen Zweden, over de topografische kaart"),
    },
    "zh-Hans": {
        "map": ("\u632a\u5a01\u4e0e\u745e\u5178\n\u540c\u5728\u4e00\u5f20\u5730\u56fe\u4e0a",
                "\u4e24\u56fd\u7684\u5b98\u65b9\u5730\u5f62\u56fe\uff0c\n\u8de8\u8d8a\u56fd\u754c\u65e0\u7f1d\u62fc\u63a5"),
        "measure": ("\u624b\u6307\u4e00\u5212\uff0c\n\u770b\u89c1\u722c\u5347",
                    "\u771f\u5b9e\u7684\u5927\u5730\u7ebf\u8ddd\u79bb\u3001\u7d2f\u8ba1\u722c\u5347\u4e0e\u4e0b\u964d\uff0c\n\u9644\u5e26\u9ad8\u5ea6\u5256\u9762\u56fe\uff0c\u5e76\u53ef\u4fdd\u5b58\u8def\u7ebf"),
        "offline": ("\u6ca1\u6709\u4fe1\u53f7\uff0c\n\u7167\u6837\u80fd\u7528",
                    "\u63d0\u524d\u4e0b\u8f7d\u4efb\u610f\u533a\u57df\uff0c\n\u5728\u65e0\u7f51\u7edc\u8986\u76d6\u5904\u7ee7\u7eed\u8bfb\u56fe"),
        "search": ("\u6bcf\u4e00\u5ea7\u5c71\u5cf0\n\u90fd\u6709\u540d\u5b57",
                   "160 \u4e07\u4e2a\u745e\u5178\u4e0e\u632a\u5a01\u5730\u540d\uff0c\n\u79bb\u7ebf\u4ea6\u53ef\u641c\u7d22"),
        "slope": ("\u51fa\u53d1\u4e4b\u524d\uff0c\n\u5148\u770b\u6e05\u9661\u5761",
                  "\u632a\u5a01\u4e0e\u745e\u5178\u7684\u96ea\u5d29\u5730\u5f62\u5761\u5ea6\u5206\u7ea7\uff0c\n\u76f4\u63a5\u53e0\u52a0\u5728\u5730\u5f62\u56fe\u4e0a"),
    },
}


def font(size: int, weight: str, language: str = DEFAULT_LANGUAGE) -> ImageFont.FreeTypeFont:
    if language.startswith("zh"):
        return ImageFont.truetype(HIRAGINO_GB, size, index=HIRAGINO_FACE[weight])
    face = ImageFont.truetype(SF_PRO, size)
    face.set_variation_by_name(weight)
    return face


def fitted_font(draw: ImageDraw.ImageDraw, text: str, size: int, weight: str,
                language: str, text_safe_width: int) -> ImageFont.FreeTypeFont:
    """The largest size at or below `size` that keeps every line inside the
    safe width. Languages set longer than English (German, Finnish) would
    otherwise run off the canvas."""
    for candidate in range(size, int(size * 0.66), -2):
        face = font(candidate, weight, language)
        if all(draw.textlength(line, font=face) <= text_safe_width
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
                  line_gap: int, canvas_width: int) -> int:
    """Draws centred lines from `y` downwards and returns the next free y."""
    for line in text.split("\n"):
        _, top, _, bottom = draw.textbbox((0, 0), line, font=face)
        width = draw.textlength(line, font=face)
        draw.text(((canvas_width - width) / 2, y - top), line, font=face, fill=fill)
        y += (bottom - top) + line_gap
    return y


def check_contrast(scene: dict, canvas_height: int) -> None:
    """Caption text has to stay readable against its own background."""
    behind = mix(*scene["background"], CAPTION_TOP / canvas_height)
    for role, minimum in (("ink", 4.5), ("muted", 3.5)):
        ratio = contrast_ratio(scene[role], behind)
        if ratio < minimum:
            raise SystemExit(
                f"{scene['out']}: {role} contrast is only {ratio:.1f}:1 (need {minimum}:1)"
            )


def compose(scene: dict, raw_dir: Path, out_dir: Path, device: dict,
            language: str = DEFAULT_LANGUAGE) -> Path:
    canvas_size = device["canvas"]
    check_contrast(scene, canvas_size[1])
    headline, subtitle = COPY[language][scene["raw"]]
    shot = Image.open(raw_dir / f"{scene['raw']}.png").convert("RGB")

    canvas = vertical_gradient(canvas_size, *scene["background"]).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    y = draw_centered(draw, headline, CAPTION_TOP,
                      fitted_font(draw, headline, 108, "Bold", language, device["text_safe_width"]),
                      scene["ink"], line_gap=28, canvas_width=canvas_size[0])
    y += 30
    y = draw_centered(draw, subtitle, y,
                      fitted_font(draw, subtitle, 46, "Medium", language, device["text_safe_width"]),
                      scene["muted"], line_gap=18, canvas_width=canvas_size[0])

    # Device frame
    screen_w = round(canvas_size[0] * device["device_width"])
    screen_h = round(screen_w * shot.height / shot.width)
    radius = round(screen_w * device["device_corner"])
    shot = shot.resize((screen_w, screen_h), Image.LANCZOS).convert("RGBA")
    shot.putalpha(rounded_mask(shot.size, radius))

    frame_w, frame_h = screen_w + BEZEL * 2, screen_h + BEZEL * 2
    frame = Image.new("RGBA", (frame_w, frame_h), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle(
        [(0, 0), (frame_w - 1, frame_h - 1)], radius=radius + BEZEL, fill=(24, 24, 26, 255)
    )
    frame.alpha_composite(shot, (BEZEL, BEZEL))

    left = (canvas_size[0] - frame_w) // 2
    top = round(canvas_size[1] * device["device_top"])
    if y > top:
        raise SystemExit(
            f"{language}/{scene['out']}: caption runs into the device frame ({y}px)"
        )

    shadow = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [(left, top + 26), (left + frame_w, top + frame_h + 26)],
        radius=radius + BEZEL,
        fill=(0, 0, 0, 105),
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(34)))
    canvas.alpha_composite(frame, (left, top))

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{device['out_prefix']}{scene['out']}.png"
    canvas.convert("RGB").save(path, "PNG")
    return path


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-root", type=Path, default=root / "marketing",
                        help="directory containing raw/ and raw-ipad/ capture folders")
    parser.add_argument("--out", type=Path, default=root / "fastlane" / "screenshots",
                        help="output directory; one subdirectory per App Store "
                             "locale is created, ready for fastlane deliver")
    parser.add_argument("--lang", action="append", choices=LANGUAGES, metavar="LANG",
                        help=f"language to compose, repeatable (default: all of "
                             f"{', '.join(LANGUAGES)})")
    parser.add_argument("--device", action="append", choices=list(DEVICES),
                        metavar="DEVICE",
                        help=f"device profile to compose, repeatable (default: all of "
                             f"{', '.join(DEVICES)})")
    parser.add_argument("scenes", nargs="*", help="raw scene names to compose (default: all)")
    args = parser.parse_args()

    wanted = set(args.scenes)
    for device_name in args.device or list(DEVICES):
        device = DEVICES[device_name]
        raw_base = args.raw_root / device["raw_dir_name"]
        for language in args.lang or LANGUAGES:
            raw_dir = raw_base / language if device["per_locale_raw"] else raw_base
            out_dir = args.out / DELIVER_LOCALES[language]
            for scene in SCENES:
                if wanted and scene["raw"] not in wanted:
                    continue
                print(compose(scene, raw_dir, out_dir, device, language))


if __name__ == "__main__":
    main()
