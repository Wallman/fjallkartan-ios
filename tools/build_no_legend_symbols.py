#!/usr/bin/env python3
"""Build the Norwegian legend symbols from Kartverket's official symbol font.

The bundled legend_no.pdf cannot be reused the way legend_se.pdf can: its point
symbols are ~7x7 pixel screenshots blown up onto 145-223 px canvases, so there is
no vector art in it to recover. Instead this rebuilds each symbol from the source
Kartverket themselves publish:

    https://dokument.geonorge.no/tegneregler/spesifikasjon-for-skjermkartografi/2.2/skjermkartografi.zip

which contains `Skjermkartografi.otf` plus the 397-page "Spesifikasjon for
skjermkartografi" (FKB and N50-N5000 Kartdata, v2.2, 2025-04-01). That
specification gives, for every symbol, the exact glyph code point, the RGB
colour, the size in points, and for line symbols the stroke width, dash pattern,
eccentric offsets and marker spacing. Every number below is quoted from it, with
the page it came from, so the legend provably matches the tiles rather than
approximating them.

Licence: NLOD 2.0 / open data. Attribution "© Kartverket" is required and is
shown in the legend footer.

Usage:
    python3 tools/build_no_legend_symbols.py fetch     # download + unzip source
    python3 tools/build_no_legend_symbols.py preview   # PNGs in /tmp
    python3 tools/build_no_legend_symbols.py assets    # write the asset catalog
"""

from __future__ import annotations

import io
import json
import shutil
import sys
import urllib.request
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import fitz  # PyMuPDF

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "fjallkartan" / "Assets.xcassets" / "LegendNO"
PREVIEW = Path("/tmp/legend_no_symbols")
CACHE = Path("/tmp/kartverket-skjermkartografi")
SOURCE_ZIP = "https://dokument.geonorge.no/tegneregler/spesifikasjon-for-skjermkartografi/2.2/skjermkartografi.zip"
FONT = CACHE / "Skjermkartografi.otf"

# Canvas sizes. Line symbols get the same 38 pt width the Swedish extraction
# produced so both countries' rows line up in the list; point symbols get a
# square box a little larger than the biggest symbol (helipad at 9.75 pt).
LINE_BOX = (38.0, 11.0)
POINT_BOX = (10.5, 10.5)


def rgb(hex_colour: str) -> tuple[float, float, float]:
    value = hex_colour.lstrip("#")
    return tuple(int(value[i : i + 2], 16) / 255 for i in (0, 2, 4))


@dataclass
class Stroke:
    """One stroked line layer, drawn across the full width of the box."""

    colour: str
    width: float
    dashes: str | None = None
    offset: float = 0.0


@dataclass
class Marker:
    """A glyph repeated along the line at a fixed spacing."""

    codepoint: int
    size: float
    colour: str
    spacing: float


@dataclass
class Glyph:
    """A single centred glyph from Skjermkartografi.otf."""

    codepoint: int
    size: float
    colour: str


@dataclass
class Letter:
    """A centred letter from a standard PDF font.

    Kartverket specifies the parking "P" as Arial Black (ARIBLK.TTF), which is
    proprietary and cannot be redistributed. Helvetica-Bold is one of the PDF
    base-14 fonts, so it is referenced rather than embedded and every Apple
    platform substitutes its own face. Slightly lighter than Arial Black; the
    only place in either legend where the artwork is not Kartverket's own.
    """

    text: str
    size: float
    colour: str


@dataclass
class Symbol:
    name: str
    spec_page: int  # 1-based page of the specification PDF
    layers: list = field(default_factory=list)
    box: tuple[float, float] = POINT_BOX


# Layers are listed in draw order: background first. The specification lists the
# principal glyph first and its white backing second, but the backing has to go
# underneath — an "Ubetjent turisthytte" is an open square that would show the
# map through it otherwise.
SYMBOLS: list[Symbol] = [
    # --- Trails and routes (page numbers are the printed "Side" number) ---
    Symbol(
        "trail_marked",  # Merket sti (sti, JA)
        306,
        [Stroke("#7F7F7F", 0.75, "[5 2] 0")],
        LINE_BOX,
    ),
    Symbol(
        "trail_unmarked",  # Umerket sti (sti, NEI)
        307,
        [Stroke("#7F7F7F", 0.75, "[3 2] 0")],
        LINE_BOX,
    ),
    Symbol(
        # Traktorveg, gang- og sykkelveg: "Heltrukken nesten hvit strek over
        # 2 eksentriske gra streker".
        "tractor_road",
        306,
        [
            Stroke("#6E6E6E", 0.75, "[4 2] 0", offset=0.75),
            Stroke("#6E6E6E", 0.75, offset=-0.75),
            Stroke("#FFFFFE", 0.75),
        ],
        LINE_BOX,
    ),
    Symbol(
        # Barmarkslo/ype: as above but with an orange centre line.
        "offroad_route",
        305,
        [
            Stroke("#6E6E6E", 0.75, "[4 2] 0", offset=0.75),
            Stroke("#6E6E6E", 0.75, offset=-0.75),
            Stroke("#FFAA00", 0.75),
        ],
        LINE_BOX,
    ),
    Symbol(
        # Lyslo/ype: "Heltrukket gul linje med tynn rod stipling over".
        "floodlit_trail",
        290,
        [Stroke("#FAEB00", 1.5), Stroke("#C31E28", 0.75, "[5 2] 0")],
        LINE_BOX,
    ),
    Symbol(
        "ski_lift",  # Skitrekk
        292,
        [Stroke("#C31E28", 0.375), Marker(78, 3.0, "#C31E28", 15.0)],
        LINE_BOX,
    ),
    Symbol(
        "reindeer_fence",  # Reingjerde
        291,
        [Stroke("#010101", 0.375), Marker(119, 3.0, "#010101", 30.0)],
        LINE_BOX,
    ),
    Symbol(
        "pier",  # Kai og brygge
        288,
        [Stroke("#010101", 0.375)],
        LINE_BOX,
    ),
    # --- Cabins and shelter ---
    # Blue is the "Last" (locked) variant, which is what the printed legend
    # shows for the three tourist cabins; the open shelters below are the red
    # "Ulast" variant. Red means anyone can walk in, blue means it is locked.
    Symbol("cabin_staffed", 281, [Glyph(110, 6.0, "#5A87DE")]),
    Symbol("cabin_self_service", 284, [Glyph(110, 6.0, "#FFFFFE"), Glyph(109, 6.0, "#5A87DE")]),
    Symbol("cabin_unstaffed", 285, [Glyph(110, 6.0, "#FFFFFE"), Glyph(108, 6.0, "#5A87DE")]),
    # Rastebu and Gapahuk are deliberately identical: the specification assigns
    # both unicode 74 at #FF0033 and 3.75 pt. legend_no.pdf reusing one bitmap
    # for the two rows was correct, not a defect.
    Symbol("rest_cabin", 282, [Glyph(74, 3.75, "#FF0033")]),
    Symbol("lean_to", 283, [Glyph(74, 3.75, "#FF0033")]),
    # --- Facilities ---
    Symbol("campsite", 268, [Glyph(74, 6.0, "#FFFFFF"), Glyph(75, 8.25, "#FF0033")]),
    Symbol("parking", 270, [Glyph(85, 6.0, "#0070FF"), Letter("P", 3.75, "#FFFFFE")]),
    Symbol("helipad", 273, [Glyph(94, 9.75, "#FFFFFE"), Glyph(103, 9.75, "#010101")]),
]


def command_fetch() -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    print(f"downloading {SOURCE_ZIP}")
    with urllib.request.urlopen(SOURCE_ZIP) as response:
        payload = response.read()
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        for member in archive.namelist():
            archive.extract(member, CACHE)
            print(f"  {member} ({archive.getinfo(member).file_size} B)")
    if not FONT.exists():
        sys.exit(f"expected {FONT.name} in the archive")
    print(f"cached in {CACHE}")


def require_font() -> fitz.Font:
    if not FONT.exists():
        sys.exit(f"missing {FONT}; run: python3 {Path(__file__).name} fetch")
    return fitz.Font(fontfile=str(FONT))


_INK_CACHE: dict[tuple[str, str, float], fitz.Rect] = {}


def ink_bbox(fontname: str, fontfile: str | None, char: str, size: float) -> fitz.Rect:
    """Bounding box of a glyph's actual ink, relative to its baseline origin.

    Measured by rendering rather than read from the font: `Font.glyph_bbox`
    reports the font-wide box for every glyph in Skjermkartografi.otf, and these
    are pictograms of very different heights sharing one em, so metrics-based
    placement leaves them visibly off-centre in their chips.
    """
    key = (fontname, char, size)
    if key in _INK_CACHE:
        return _INK_CACHE[key]

    pad = size * 3
    probe = fitz.open()
    page = probe.new_page(width=pad * 2, height=pad * 2)
    if fontfile:
        page.insert_font(fontname=fontname, fontfile=fontfile)
    page.insert_text(fitz.Point(pad, pad), char, fontsize=size, fontname=fontname)

    zoom = 16
    pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), colorspace=fitz.csGRAY)
    ink = pix.samples.translate(bytes(1 if value < 250 else 0 for value in range(256)))
    rows = [ink[y * pix.width : (y + 1) * pix.width] for y in range(pix.height)]
    inked = [(y, row) for y, row in enumerate(rows) if 1 in row]
    probe.close()
    if not inked:
        raise ValueError(f"glyph {char!r} in {fontname} rendered blank")

    box = fitz.Rect(
        min(row.find(1) for _, row in inked) / zoom - pad,
        inked[0][0] / zoom - pad,
        (max(row.rfind(1) for _, row in inked) + 1) / zoom - pad,
        (inked[-1][0] + 1) / zoom - pad,
    )
    _INK_CACHE[key] = box
    return box


def centred_origin(
    fontname: str, fontfile: str | None, char: str, size: float, box: tuple[float, float]
) -> fitz.Point:
    """Baseline origin that centres the glyph's ink in the box."""
    width, height = box
    bbox = ink_bbox(fontname, fontfile, char, size)
    return fitz.Point((width - bbox.width) / 2 - bbox.x0, (height - bbox.height) / 2 - bbox.y0)


def draw_symbol(symbol: Symbol) -> fitz.Document:
    width, height = symbol.box
    out = fitz.open()
    page = out.new_page(width=width, height=height)
    page.insert_font(fontname="skjerm", fontfile=str(FONT))
    middle = height / 2

    for layer in symbol.layers:
        if isinstance(layer, Stroke):
            y = middle + layer.offset
            shape = page.new_shape()
            shape.draw_line(fitz.Point(0, y), fitz.Point(width, y))
            shape.finish(color=rgb(layer.colour), width=layer.width, dashes=layer.dashes)
            shape.commit()

        elif isinstance(layer, Marker):
            char = chr(layer.codepoint)
            # Centre the run of markers so the symbol reads the same regardless
            # of how the spacing divides into the swatch width.
            count = max(1, int(width // layer.spacing) + 1)
            span = (count - 1) * layer.spacing
            start = (width - span) / 2
            for index in range(count):
                origin = centred_origin("skjerm", str(FONT), char, layer.size, (0.0, height))
                page.insert_text(
                    fitz.Point(start + index * layer.spacing + origin.x, origin.y),
                    char,
                    fontsize=layer.size,
                    fontname="skjerm",
                    color=rgb(layer.colour),
                )

        elif isinstance(layer, Glyph):
            char = chr(layer.codepoint)
            page.insert_text(
                centred_origin("skjerm", str(FONT), char, layer.size, symbol.box),
                char,
                fontsize=layer.size,
                fontname="skjerm",
                color=rgb(layer.colour),
            )

        elif isinstance(layer, Letter):
            page.insert_text(
                centred_origin("hebo", None, layer.text, layer.size, symbol.box),
                layer.text,
                fontsize=layer.size,
                fontname="hebo",
                color=rgb(layer.colour),
            )

        else:
            sys.exit(f"{symbol.name}: unknown layer {layer!r}")

    return out


def command_preview() -> None:
    require_font()
    PREVIEW.mkdir(parents=True, exist_ok=True)
    for symbol in SYMBOLS:
        out = draw_symbol(symbol)
        out[0].get_pixmap(dpi=72 * 24, alpha=True).save(PREVIEW / f"{symbol.name}.png")
        out.close()
    print(f"wrote {len(SYMBOLS)} previews to {PREVIEW}")


def contents_json(filename: str) -> dict:
    return {
        "images": [{"filename": filename, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True},
    }


def command_assets() -> None:
    require_font()
    if ASSETS.exists():
        shutil.rmtree(ASSETS)
    ASSETS.mkdir(parents=True)
    (ASSETS / "Contents.json").write_text(
        json.dumps(
            {"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}},
            indent=2,
        )
        + "\n"
    )

    total = 0
    for symbol in SYMBOLS:
        imageset = ASSETS / f"{symbol.name}.imageset"
        imageset.mkdir()
        out = draw_symbol(symbol)
        out.subset_fonts(verbose=False)
        target = imageset / f"{symbol.name}.pdf"
        out.save(target, garbage=4, deflate=True, clean=True)
        out.close()
        total += target.stat().st_size
        (imageset / "Contents.json").write_text(
            json.dumps(contents_json(f"{symbol.name}.pdf"), indent=2) + "\n"
        )
    print(f"wrote {len(SYMBOLS)} imagesets to {ASSETS} ({total / 1024:.0f} kB)")


def main() -> None:
    command = sys.argv[1] if len(sys.argv) > 1 else "preview"
    commands = {"fetch": command_fetch, "preview": command_preview, "assets": command_assets}
    if command not in commands:
        sys.exit(f"unknown command: {command!r} (expected {', '.join(commands)})")
    commands[command]()


if __name__ == "__main__":
    main()
