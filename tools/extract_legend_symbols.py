#!/usr/bin/env python3
"""Extract the Swedish legend symbols from Lantmateriet's legend into vector PDFs.

`tools/legend_se_source.pdf` is Lantmateriet's own legend sheet, which the app
used to render wholesale via PDFKit. It is kept here as a build input only; it
is deliberately outside `fjallkartan/` so it is no longer copied into the app
bundle.

That sheet is a single 314x414 pt page whose symbols are all real
vector art (63 drawings plus two glyphs from Lantmateriet's embedded
"LMTopografisymboler" font). Rendering that page as one image in the app is what
makes the legend illegible: the type lands at ~7 pt on a phone and ignores
Dynamic Type.

This script clips each symbol cell out of the page into its own single-page PDF,
which Xcode can then rasterise at any size ("Preserve Vector Data"). Clipping,
rather than re-drawing the symbols by hand, is what guarantees the legend still
matches the actual Lantmateriet tiles pixel for pixel.

Usage:
    python3 tools/extract_legend_symbols.py preview   # PNGs in /tmp for eyeballing
    python3 tools/extract_legend_symbols.py assets    # write the asset catalog
"""

from __future__ import annotations

import json
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

import fitz  # PyMuPDF

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "legend_se_source.pdf"
ASSETS = REPO / "fjallkartan" / "Assets.xcassets" / "LegendSE"
PREVIEW = Path("/tmp/legend_se_symbols")

# Every symbol cell, in source-page points (origin top-left).
#
# The clips are deliberately tight: a symbol drawn 34 pt wide inside a 40 pt box
# has to survive being scaled down to a ~44 pt row chip, so stray whitespace is
# wasted resolution. Line symbols keep the full 34..71 pt drawing width because
# their dash pattern is the whole point; point symbols are cropped to a square-ish
# box centred on the mark.
#
# Rows that the source crams together ("Raststuga; vindskydd; kata") are split
# into one entry per mark, since a shared row is exactly what makes the printed
# legend hard to read on a phone.


@dataclass(frozen=True)
class Symbol:
    name: str
    x0: float
    y0: float
    x1: float
    y1: float

    @property
    def rect(self) -> fitz.Rect:
        return fitz.Rect(self.x0, self.y0, self.x1, self.y1)


SYMBOLS: list[Symbol] = [
    # --- Trails and routes (full-width line symbols) ---
    # Starts at 71.2, below the 0.709 pt stroke of the wind shelter drawn at the
    # end of this row: that shelter is its own entry further down the list.
    Symbol("trail_summer_marked", 33.5, 71.2, 71.5, 74.0),
    Symbol("trail_summer_winter_marked", 33.5, 82.0, 71.5, 95.0),
    Symbol("trail_winter_marked", 33.5, 102.0, 71.5, 107.5),
    # Starts at 122.0 so the "mandatory" snowmobile badge (which ends at 121.5)
    # cannot bleed into the plain-trail variant.
    Symbol("trail_snowmobile", 33.5, 122.0, 71.5, 126.0),
    Symbol("trail_snowmobile_mandatory", 33.5, 115.0, 71.5, 126.0),
    Symbol("trail_summer_only_marked", 33.5, 136.0, 71.5, 141.0),
    Symbol("trail_recommended_unmarked", 33.5, 154.0, 71.5, 159.0),
    Symbol("trail_poorly_marked", 33.5, 169.5, 71.5, 175.0),
    Symbol("trail_reindeer_husbandry", 33.5, 185.5, 71.5, 190.5),
    Symbol("trail_boat", 33.5, 203.0, 71.5, 208.0),
    Symbol("area_no_tent_or_fire", 33.5, 218.5, 71.5, 224.0),
    Symbol("trail_boat_portage", 33.5, 236.0, 71.5, 241.0),
    Symbol("trail_ski", 33.5, 249.5, 71.5, 261.0),
    # --- Barriers ---
    Symbol("reindeer_fence", 33.5, 267.0, 62.8, 275.5),
    Symbol("reindeer_corral", 62.8, 267.0, 72.0, 275.5),
    # --- Huts and shelter ---
    Symbol("mountain_lodge", 47.0, 286.5, 57.0, 295.5),
    Symbol("rest_cabin", 37.4, 303.5, 45.9, 312.5),
    Symbol("wind_shelter", 48.9, 303.5, 56.4, 312.5),
    Symbol("sami_cot", 57.1, 303.5, 65.6, 312.5),
    Symbol("tourist_hut", 39.5, 322.3, 48.5, 330.3),
    Symbol("solitary_cabin", 54.5, 322.3, 63.5, 330.3),
    Symbol("blast_shelter", 45.5, 391.0, 57.5, 405.0),
    # --- Facilities ---
    Symbol("parking", 46.0, 339.5, 56.0, 349.5),
    Symbol("helipad", 36.6, 357.0, 48.2, 369.5),
    Symbol("emergency_phone", 54.1, 356.5, 64.1, 366.5),
    Symbol("bridge", 38.8, 375.5, 48.7, 385.0),
    Symbol("ford", 54.0, 375.5, 64.0, 385.0),
]


# The two symbols the source draws as glyphs from Lantmateriet's embedded
# "LMTopografisymboler" font rather than as paths.
GLYPH_FONT = "LMTopografisymboler"


def load_page() -> tuple[fitz.Document, fitz.Page]:
    if not SOURCE.exists():
        sys.exit(f"missing source PDF: {SOURCE}")
    doc = fitz.open(SOURCE)
    return doc, doc[0]


def glyph_font_buffer(doc: fitz.Document) -> bytes:
    for xref, ext, _type, name, _ref, _enc in doc.get_page_fonts(0):
        if GLYPH_FONT in name and ext != "n/a":
            return doc.extract_font(xref)[3]
    sys.exit(f"{GLYPH_FONT} not found in {SOURCE}")


def stripped_document(doc: fitz.Document) -> fitz.Document:
    """A copy of the source with every label redacted away.

    Two symbols ("Helikopterplats" and "Skyddsvarn") are glyphs from the embedded
    LMTopografisymboler subset, not paths, so they cannot be replayed: that
    subset carries no cmap, so its 122 glyphs are reachable only by glyph id and
    insert_text() has no way to address them. Those two are therefore clipped
    from the page like the old `reference` did. Redacting the Verdana labels
    first lets subset_fonts() drop four unused font subsets afterwards, which is
    the difference between an 80 kB symbol and a 17 kB one.
    """
    out = fitz.open()
    out.insert_pdf(doc)
    page = out[0]
    for block in page.get_text("dict")["blocks"]:
        if block["type"] != 0:
            continue
        for line in block["lines"]:
            for span in line["spans"]:
                if GLYPH_FONT not in span["font"]:
                    page.add_redact_annot(fitz.Rect(span["bbox"]))
    page.apply_redactions(
        images=fitz.PDF_REDACT_IMAGE_NONE,
        graphics=fitz.PDF_REDACT_LINE_ART_NONE,
        text=fitz.PDF_REDACT_TEXT_REMOVE,
    )
    return out


def clip_from(symbol: Symbol, doc: fitz.Document) -> fitz.Document:
    """Extract the symbol by embedding `doc`'s page and cropping to the symbol."""
    clip = symbol.rect
    out = fitz.open()
    page = out.new_page(width=clip.width, height=clip.height)
    page.show_pdf_page(fitz.Rect(0, 0, clip.width, clip.height), doc, 0, clip=clip)
    return out


def reference(symbol: Symbol, doc: fitz.Document) -> fitz.Document:
    """The fidelity oracle: crop straight out of the untouched source page."""
    return clip_from(symbol, doc)


def overlaps(rect: fitz.Rect, clip: fitz.Rect) -> bool:
    """Inclusive overlap test that survives degenerate rectangles.

    fitz.Rect.intersects() reports False whenever either rectangle is empty, and
    every horizontal line symbol here has a zero-height bounding box, so using it
    silently dropped all the trail lines.
    """
    return (
        rect.x0 <= clip.x1
        and rect.x1 >= clip.x0
        and rect.y0 <= clip.y1
        and rect.y1 >= clip.y0
    )


def draw_oriented_rect(shape: fitz.Shape, rect: fitz.Rect, orientation: int) -> None:
    """Draw a rectangle preserving its winding direction.

    Shape.draw_rect() always emits the same vertex order, which throws away the
    orientation PDF uses to decide, under the nonzero winding rule, whether a
    nested subpath is a hole or a fill. "Fjallstation" is three nested rectangles
    whose middle ring is a hole purely because it is wound the other way.
    """
    corners = [
        fitz.Point(rect.x0, rect.y0),
        fitz.Point(rect.x1, rect.y0),
        fitz.Point(rect.x1, rect.y1),
        fitz.Point(rect.x0, rect.y1),
    ]
    if orientation > 0:
        corners.reverse()
    shape.draw_polyline(corners + [corners[0]])


def extract(symbol: Symbol, source: "Source") -> fitz.Document:
    """Return a single-page PDF containing just this symbol, still as vectors.

    Path symbols are rebuilt by replaying only the paths that fall inside the
    clip: same vectors, ~1% of the bytes of embedding the whole page. Symbols
    whose art is a font glyph can't be replayed, so those fall back to cropping
    the stripped page.
    """
    clip = symbol.rect
    if any(overlaps(box, clip) for box in source.glyph_boxes):
        return clip_from(symbol, source.stripped)

    out = fitz.open()
    page = out.new_page(width=clip.width, height=clip.height)
    shift = fitz.Point(-clip.x0, -clip.y0)

    def moved(point: fitz.Point) -> fitz.Point:
        return point + shift

    # Replayed in source order so overprinted paths (the white centre line of
    # "batdrag", say) still land on top of what they are meant to cover.
    for path in source.drawings:
        if not overlaps(path["rect"], clip):
            continue
        shape = page.new_shape()
        for item in path["items"]:
            kind = item[0]
            if kind == "l":
                shape.draw_line(moved(item[1]), moved(item[2]))
            elif kind == "c":
                shape.draw_bezier(moved(item[1]), moved(item[2]), moved(item[3]), moved(item[4]))
            elif kind == "re":
                draw_oriented_rect(shape, item[1] + fitz.Rect(shift, shift), item[2])
            elif kind == "qu":
                shape.draw_quad(item[1] * fitz.Matrix(1, 0, 0, 1, shift.x, shift.y))
            else:
                sys.exit(f"{symbol.name}: unsupported path item {kind!r}")
        shape.finish(
            color=path.get("color"),
            fill=path.get("fill"),
            width=path.get("width") or 0,
            dashes=path.get("dashes"),
            closePath=path.get("closePath", False),
            even_odd=path.get("even_odd", False),
            lineCap=max(path.get("lineCap") or (0,)),
            lineJoin=path.get("lineJoin") or 0,
            fill_opacity=path.get("fill_opacity") if path.get("fill_opacity") is not None else 1,
            stroke_opacity=path.get("stroke_opacity") if path.get("stroke_opacity") is not None else 1,
        )
        shape.commit()

    return out


def glyph_boxes(page: fitz.Page) -> list:
    """Bounding boxes of everything on the page drawn with the symbol font."""
    boxes = []
    for block in page.get_text("dict")["blocks"]:
        if block["type"] != 0:
            continue
        for line in block["lines"]:
            for span in line["spans"]:
                if GLYPH_FONT in span["font"]:
                    boxes.append(fitz.Rect(span["bbox"]))
    return boxes


@dataclass
class Source:
    doc: fitz.Document
    drawings: list
    glyph_boxes: list
    stripped: fitz.Document


def build_source() -> Source:
    doc, page = load_page()
    return Source(
        doc=doc,
        drawings=page.get_drawings(),
        glyph_boxes=glyph_boxes(page),
        stripped=stripped_document(doc),
    )


def command_preview() -> None:
    source = build_source()
    PREVIEW.mkdir(parents=True, exist_ok=True)
    for symbol in SYMBOLS:
        out = extract(symbol, source)
        # 24x so a 5 pt mark lands at ~120 px and clipping mistakes are obvious.
        out[0].get_pixmap(dpi=72 * 24, alpha=True).save(PREVIEW / f"{symbol.name}.png")
        out.close()
    print(f"wrote {len(SYMBOLS)} previews to {PREVIEW}")


def command_verify() -> None:
    """Compare the replayed vectors against the embed-and-crop reference.

    A symbol that fails here is one where replaying the path list lost something
    the original content stream did, which would mean the legend no longer
    matches the tiles.
    """
    source = build_source()
    dpi = 72 * 8
    worst = 0.0
    failures = []
    for symbol in SYMBOLS:
        mine = extract(symbol, source)
        theirs = reference(symbol, source.doc)
        a = mine[0].get_pixmap(dpi=dpi, alpha=False)
        b = theirs[0].get_pixmap(dpi=dpi, alpha=False)
        if (a.width, a.height) != (b.width, b.height):
            failures.append((symbol.name, "size mismatch"))
            continue
        diff = sum(abs(x - y) for x, y in zip(a.samples, b.samples)) / (len(a.samples) * 255)
        worst = max(worst, diff)
        status = "ok" if diff < 0.005 else "DIFFERS"
        if diff >= 0.005:
            failures.append((symbol.name, f"{diff:.4%}"))
        print(f"{status:8} {diff:8.4%}  {symbol.name}")
        mine.close()
        theirs.close()
    print(f"\nworst difference {worst:.4%}")
    if failures:
        print("failures:")
        for name, why in failures:
            print(f"  {name}: {why}")
        sys.exit(1)
    print("all symbols match the reference clip")


def contents_json(filename: str) -> dict:
    return {
        "images": [{"filename": filename, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True},
    }


def command_assets() -> None:
    source = build_source()
    if ASSETS.exists():
        shutil.rmtree(ASSETS)
    ASSETS.mkdir(parents=True)
    (ASSETS / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}}, indent=2) + "\n"
    )

    total = 0
    for symbol in SYMBOLS:
        imageset = ASSETS / f"{symbol.name}.imageset"
        imageset.mkdir()
        out = extract(symbol, source)
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
    commands = {"preview": command_preview, "verify": command_verify, "assets": command_assets}
    if command not in commands:
        sys.exit(f"unknown command: {command!r} (expected {', '.join(commands)})")
    commands[command]()


if __name__ == "__main__":
    main()
