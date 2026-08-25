#!/usr/bin/env python3
"""Convert symbology from a QGIS .qlr (Layer Definition) file into a MapLibre
GL style document, for the subset of QGIS renderers used by Lantmateriet's
Topografi 50 style (categorizedSymbol + RuleRenderer; SimpleLine/SimpleFill/
SimpleMarker/FontMarker symbol layers).

Usage:
    python3 qlr_to_maplibre_style.py <qlr-file> --source <martin-source-id> \
        --tiles-url http://localhost:3131/<source-id> \
        [--layer <gpkg-layer-name> ...] -o style.json

If --layer is omitted, every layer found in the .qlr is converted (skipping
ones whose renderer/symbol-layer types aren't supported yet -- these are
listed on stderr so they can be added incrementally).
"""
import argparse
import re
import sys
import xml.etree.ElementTree as ET

MM_TO_PX = 3.7795275591  # 96 dpi, matches typical QGIS on-screen mm rendering

QGIS_LINE_STYLE_DASH = {
    "dash": None,  # uses customdash if use_custom_dash=1, else a default dash
    "dot": [1, 2],
    "dash dot": [4, 2, 1, 2],
    "dash dot dot": [4, 2, 1, 2, 1, 2],
}


def qcolor_to_rgba(value):
    """'196,60,57,255,rgb:...' -> 'rgba(196,60,57,1)'"""
    if not value:
        return None
    parts = value.split(",")
    r, g, b, a = (int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))
    return f"rgba({r},{g},{b},{a / 255:.3f})"


def opt(layer_el, name, default=None):
    for o in layer_el.findall("./Option/Option"):
        if o.get("name") == name:
            return o.get("value")
    return default


def parse_simple_line(layer_el):
    color = qcolor_to_rgba(opt(layer_el, "line_color"))
    width_mm = float(opt(layer_el, "line_width", "0.26") or 0.26)
    style = opt(layer_el, "line_style", "solid")
    use_custom = opt(layer_el, "use_custom_dash", "0") == "1"
    customdash = opt(layer_el, "customdash")
    paint = {
        "line-color": color,
        "line-width": round(width_mm * MM_TO_PX, 2),
    }
    dasharray = None
    if style != "solid":
        if use_custom and customdash:
            segs = [float(x) for x in customdash.split(";")]
            dasharray = [round(s / max(width_mm, 0.01), 2) for s in segs]
        elif style in QGIS_LINE_STYLE_DASH and QGIS_LINE_STYLE_DASH[style]:
            dasharray = QGIS_LINE_STYLE_DASH[style]
    if dasharray:
        paint["line-dasharray"] = dasharray
    return {"type": "line", "paint": paint}


def parse_simple_fill(layer_el):
    fill_color = qcolor_to_rgba(opt(layer_el, "color"))
    outline_color = qcolor_to_rgba(opt(layer_el, "outline_color"))
    outline_width_mm = float(opt(layer_el, "outline_width", "0.26") or 0.26)
    return {
        "type": "fill",
        "paint": {
            "fill-color": fill_color,
            "fill-outline-color": outline_color,
        },
        "_outline_width_px": round(outline_width_mm * MM_TO_PX, 2),
    }


def parse_simple_marker(layer_el):
    color = qcolor_to_rgba(opt(layer_el, "color"))
    size_mm = float(opt(layer_el, "size", "2") or 2)
    return {
        "type": "circle",
        "paint": {
            "circle-color": color,
            "circle-radius": round(size_mm * MM_TO_PX / 2, 2),
        },
    }


def parse_font_marker(layer_el, font_family):
    chr_ = opt(layer_el, "chr", "")
    # The font ships with a legacy Windows "Symbol" cmap (platform 3, encoding
    # 0), where ASCII code N is really stored at PUA codepoint 0xF000+N. We
    # re-expose those same glyphs through a standard Unicode cmap subtable at
    # that PUA codepoint (see tools/fix_symbol_font_cmap.py), so the text
    # field must reference the shifted codepoint, not the raw QGIS char.
    if chr_:
        chr_ = chr(0xF000 + ord(chr_[0])) + chr_[1:]
    color = qcolor_to_rgba(opt(layer_el, "color"))
    size_mm = float(opt(layer_el, "size", "3") or 3)
    return {
        "type": "symbol",
        "layout": {
            "text-field": chr_,
            "text-font": [f"{font_family} Regular"],
            "text-size": round(size_mm * MM_TO_PX, 1),
            "text-allow-overlap": True,
            "text-ignore-placement": True,
        },
        "paint": {"text-color": color},
        "_glyph": True,
    }


SYMBOL_PARSERS = {
    "SimpleLine": parse_simple_line,
    "SimpleFill": parse_simple_fill,
    "SimpleMarker": parse_simple_marker,
    "FontMarker": lambda el: parse_font_marker(el, "LMTopografisymboler"),
}


def convert_symbol(symbol_el):
    """A QGIS <symbol> can stack several symbol <layer>s; MapLibre needs one
    style layer per paint type, so keep only the first layer we can render
    (good enough for line/fill; markers are rarely stacked in this style)."""
    for layer_el in symbol_el.findall("layer"):
        cls = layer_el.get("class")
        parser = SYMBOL_PARSERS.get(cls)
        if parser:
            return parser(layer_el), cls
    return None, None


def sanitize_id(*parts):
    s = "-".join(str(p) for p in parts)
    return re.sub(r"[^a-zA-Z0-9_-]+", "_", s)


def convert_categorized(renderer_el, gpkg_layer, source_id):
    attr = renderer_el.get("attr")
    symbols = {s.get("name"): s for s in renderer_el.find("symbols").findall("symbol")}
    out_layers = []
    unsupported = []
    for cat in renderer_el.find("categories").findall("category"):
        sym_name = cat.get("symbol")
        value = cat.get("value")
        label = cat.get("label", "")
        symbol_el = symbols.get(sym_name)
        if symbol_el is None:
            continue
        style, cls = convert_symbol(symbol_el)
        if style is None:
            unsupported.append((label, "no supported symbol layer"))
            continue
        style.pop("_outline_width_px", None)
        style.pop("_glyph", None)
        layer = {
            "id": sanitize_id(gpkg_layer, attr, value),
            "type": style["type"],
            "source": source_id,
            "source-layer": gpkg_layer,
            "filter": ["==", ["to-string", ["get", attr]], str(value)],
            "paint": style.get("paint", {}),
        }
        if "layout" in style:
            layer["layout"] = style["layout"]
        layer["metadata"] = {"qgis:label": label}
        out_layers.append(layer)
    return out_layers, unsupported


def convert_rule_renderer(renderer_el, gpkg_layer, source_id):
    """Best-effort: only translate simple `"attr" = value` / `"attr" IN (...)`
    filters (the common case in this style); anything else is reported as
    unsupported so it can be handled by hand."""
    symbols = {s.get("name"): s for s in renderer_el.find("symbols").findall("symbol")}
    out_layers = []
    unsupported = []
    rules_el = renderer_el.find("rules")
    if rules_el is None:
        return out_layers, unsupported
    for rule in rules_el.findall(".//rule"):
        label = rule.get("label", "")
        filt = rule.get("filter", "")
        sym_name = rule.get("symbol")
        symbol_el = symbols.get(sym_name)
        mb_filter = qgis_filter_to_maplibre(filt)
        if symbol_el is None or mb_filter is None:
            unsupported.append((label, filt or "(no filter)"))
            continue
        style, cls = convert_symbol(symbol_el)
        if style is None:
            unsupported.append((label, f"unsupported symbol layer class"))
            continue
        style.pop("_outline_width_px", None)
        style.pop("_glyph", None)
        layer = {
            "id": sanitize_id(gpkg_layer, rule.get("key", sym_name)),
            "type": style["type"],
            "source": source_id,
            "source-layer": gpkg_layer,
            "filter": mb_filter,
            "paint": style.get("paint", {}),
        }
        if "layout" in style:
            layer["layout"] = style["layout"]
        layer["metadata"] = {"qgis:label": label}
        out_layers.append(layer)
    return out_layers, unsupported


_EQ_RE = re.compile(r'^"([\w]+)"\s*=\s*(-?\d+(?:\.\d+)?|\'[^\']*\')$')
_IN_RE = re.compile(r'^"([\w]+)"\s*IN\s*\(\s*(.+?)\s*\)$', re.IGNORECASE)


def _split_top_level_and(expr):
    """Split expr on ' AND ' at paren-depth 0, so AND chains of any length
    (and IN (...) lists, which contain commas/parens but no nested AND) work."""
    parts = []
    depth = 0
    i = 0
    start = 0
    n = len(expr)
    while i < n:
        c = expr[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif depth == 0 and expr[i : i + 5].upper() == " AND ":
            parts.append(expr[start:i].strip())
            i += 5
            start = i
            continue
        i += 1
    parts.append(expr[start:].strip())
    return parts


def qgis_filter_to_maplibre(expr):
    if not expr:
        return None
    expr = expr.strip()
    # Only handle "attr" = val / "attr" IN (...) conditions joined by AND
    # (any chain length); give up (return None => reported as unsupported)
    # on anything richer, e.g. scale denominators, string functions, OR
    # chains -- those need manual review.
    parts = _split_top_level_and(expr)
    conditions = []
    for part in parts:
        m_eq = _EQ_RE.match(part)
        m_in = _IN_RE.match(part)
        if m_eq:
            attr, val = m_eq.groups()
            val = val.strip("'")
            conditions.append(["==", ["to-string", ["get", attr]], str(val)])
        elif m_in:
            attr, vals = m_in.groups()
            values = [v.strip().strip("'") for v in vals.split(",")]
            conditions.append(["in", ["to-string", ["get", attr]], ["literal", values]])
        else:
            return None
    if len(conditions) == 1:
        return conditions[0]
    return ["all"] + conditions


def find_maplayers(root, wanted_layers=None):
    for maplayer in root.iter("maplayer"):
        datasource = maplayer.findtext("datasource", "")
        m = re.search(r"layername=(\w+)", datasource)
        if not m:
            continue
        gpkg_layer = m.group(1)
        if wanted_layers and gpkg_layer not in wanted_layers:
            continue
        yield gpkg_layer, maplayer


def build_style(qlr_path, source_id, tiles_url, wanted_layers=None, glyphs_url=None):
    tree = ET.parse(qlr_path)
    root = tree.getroot()
    # Groups of MapLibre layers, one group per QGIS maplayer, collected in QGIS's
    # legend document order (top-of-legend first).
    layer_groups = []
    report = []
    for gpkg_layer, maplayer in find_maplayers(root, wanted_layers):
        renderer = maplayer.find("renderer-v2")
        if renderer is None:
            report.append((gpkg_layer, "no renderer-v2 (label-only layer?)"))
            continue
        rtype = renderer.get("type")
        if rtype == "categorizedSymbol":
            layers, unsupported = convert_categorized(renderer, gpkg_layer, source_id)
        elif rtype == "RuleRenderer":
            layers, unsupported = convert_rule_renderer(renderer, gpkg_layer, source_id)
        else:
            report.append((gpkg_layer, f"unsupported renderer type {rtype}"))
            continue
        layer_groups.append(layers)
        for label, reason in unsupported:
            report.append((gpkg_layer, f"rule '{label}' skipped: {reason}"))

    # QGIS's legend lists layers top-of-panel (drawn last, on top) to
    # bottom-of-panel (drawn first). MapLibre's "layers" array is the opposite:
    # first entry paints first (bottom), last entry paints last (on top). Reverse
    # the per-layer groups here (keeping each layer's own internal rule order
    # intact) so terrain fills like "mark" end up near the bottom of the stack
    # instead of painting opaquely over every road/line/label drawn before them.
    all_layers = [layer for group in reversed(layer_groups) for layer in group]

    # QGIS's rule "key" is tied to the referenced symbol, not the individual
    # rule, so distinct rules that share a symbol (e.g. "Motorväg" vs
    # "Motorväg, Underfart") can produce the exact same generated id. A later
    # duplicate id silently overwrites the earlier layer in both MapLibre GL
    # JS (hard validation error) and MapLibre Native (last-writer-wins), losing
    # real, differently-filtered layers. Disambiguate with a numeric suffix.
    seen_ids: dict[str, int] = {}
    for layer in all_layers:
        base_id = layer["id"]
        count = seen_ids.get(base_id, 0)
        seen_ids[base_id] = count + 1
        if count > 0:
            layer["id"] = f"{base_id}-{count + 1}"

    style = {
        "version": 8,
        "name": "Topografi 50 (from QGIS .qlr)",
        "sources": {
            source_id: {
                "type": "vector",
                "tiles": [f"{tiles_url}/{{z}}/{{x}}/{{y}}"],
                "minzoom": 0,
                "maxzoom": 14,
            }
        },
        "glyphs": glyphs_url or "http://localhost:3131/font/{fontstack}/{range}",
        "layers": [
            {"id": "background", "type": "background", "paint": {"background-color": "#f7f3ea"}}
        ]
        + all_layers,
    }
    return style, report


if __name__ == "__main__":
    import json

    ap = argparse.ArgumentParser()
    ap.add_argument("qlr")
    ap.add_argument("--source", required=True, help="Martin source id, e.g. poc")
    ap.add_argument("--tiles-url", required=True, help="e.g. http://localhost:3131/poc")
    ap.add_argument("--layer", action="append", help="Restrict to this gpkg layer (repeatable)")
    ap.add_argument("--glyphs-url")
    ap.add_argument("-o", "--out", default="style.json")
    args = ap.parse_args()

    style, report = build_style(
        args.qlr, args.source, args.tiles_url, wanted_layers=args.layer, glyphs_url=args.glyphs_url
    )
    with open(args.out, "w") as f:
        json.dump(style, f, indent=2, ensure_ascii=False)
    print(f"Wrote {args.out} with {len(style['layers']) - 1} style layers", file=sys.stderr)
    if report:
        print(f"\n{len(report)} skipped items:", file=sys.stderr)
        for gpkg_layer, reason in report:
            print(f"  [{gpkg_layer}] {reason}", file=sys.stderr)
