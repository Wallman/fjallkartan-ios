#!/usr/bin/env python3
"""Build the offline place-name search database bundled with the app.

Sources
-------
Sweden  Lantmäteriet "Ortnamn" GeoPackage (EPSG:3006 / SWEREF99 TM).
Norway  Kartverket SSR "Stedsnavn for vanlig bruk" GML (EPSG:25833 / EUREF89 UTM33).
        https://kartkatalog.geonorge.no/metadata/30caed2f-454e-44be-b5cc-26bb5c0110ca

All reprojection to WGS84 is delegated to PROJ via pyproj.

Output
------
A single SQLite file:

    place(id, kind, rank, lat, lon, country, muni, name)
    alias(id, place_id, name, lang)
    place_fts  -- contentless FTS5 over both name columns

A place with Norwegian, Lule Sámi and Kven forms is found by any of them but
appears once in the results. The display name lives in `place`; only the 1.2%
of places with more than one official name get `alias` rows. Both share one
FTS rowid space: a place's own id for its display name, ALIAS_OFFSET upwards
for the rest, so a match resolves with a single left join.
Coordinates are integer hundred-thousandths of a degree (~1 m), well below the
precision of the sources.

Usage
-----
    python3 tools/build_places_db.py --se ortnamn_se.gpkg --no ssr.gml \
        --out fjallkartan/Resources/places.sqlite
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import struct
import sys
import time
import zipfile
from typing import Iterable, Iterator, NamedTuple
from xml.etree import ElementTree

from pyproj import Geod, Transformer

SWEDEN, NORWAY = 0, 1

# Alias ids start above any place id so that `place_fts.rowid` can address a
# display name and an alias without ambiguity.
ALIAS_OFFSET = 1_000_000_000

# ---------------------------------------------------------------------------
# Category model
# ---------------------------------------------------------------------------

KINDS = [
    "settlement",   # 0  towns, villages, farms, houses
    "terrain",      # 1  peaks, ridges, valleys, slopes
    "water",        # 2  lakes, bays, parts of lakes
    "watercourse",  # 3  rivers, streams, rapids, waterfalls
    "wetland",      # 4  bogs, mires
    "glacier",      # 5
    "nature",       # 6  national parks, reserves
    "cultural",     # 7  cultural sites, churches
    "infrastructure",  # 8 roads, cabins, installations
    "other",        # 9
]
KIND_ID = {name: i for i, name in enumerate(KINDS)}

# Lantmäteriet `detaljtyp` -> shared category.
SE_KIND = {
    "BEBTÄTTX": "settlement",
    "BEBTX": "settlement",
    "TERRTX": "terrain",
    "VATTTX": "water",
    "VATTDELTX": "water",
    "VATTDRTX": "watercourse",
    "SANKTX": "wetland",
    "GLACIÄRTX": "glacier",
    "NATTX": "nature",
    "KULTURTX": "cultural",
    "KYRKATX": "cultural",
    "ANLTX": "infrastructure",
}

# `traktnamn` are property-register district names, not places.
SE_SKIP = ("TRAKTTX",)

# Kartverket `navneobjekthovedgruppe` -> shared category.
NO_GROUP_KIND = {
    "bebyggelse": "settlement",
    "terreng": "terrain",
    "ferskvann": "water",
    "sjø": "water",
    "markslag": "nature",
    "kultur": "cultural",
}

# `infrastruktur` is Norwegian street and address naming -- 139,781 names
# ending in -vegen, -gata, -stien, -terrasse -- which is 7.5% of the database
# and of no use on a mountain map. `offentligAdministrasjon` is the "X kommune"
# entries, which already appear as the subtitle of every result. Skipped before
# the category is looked up, so neither needs a NO_GROUP_KIND entry.
NO_SKIP_GROUPS = frozenset({"infrastruktur", "offentligAdministrasjon"})

# `navneobjektgruppe` refines the main group where it is more specific.
NO_SUBGROUP_KIND = {
    "rennendeVann": "watercourse",
    "våtmark": "wetland",
    "isOgPermafrost": "glacier",
    "verne-OgBruksområder": "nature",
    "bartFjell": "terrain",
    "løsmasseavsetninger": "terrain",
}

# Display priority: lower sorts first when relevance ties.
#
# Kartverket grades every Norwegian name (`viktighetA`..`viktighetM` -> 0..12,
# mean 3.54, median 3). Lantmäteriet ships no importance field at all, so the
# Swedish values below are derived from `detaljtyp` and are effectively a
# boolean: 99.4% of Swedish places take the default. That default therefore has
# to sit at Norway's *median* rather than at some arbitrary point on the scale
# -- when it sat at 7, near the bottom of Norway's range, a border search
# returned 60 Norwegian hits and no Swedish ones, because every Swedish place
# carried a ~22 point handicap it could only repay by being ~180 km closer.
SE_RANK = {"BEBTÄTTX": 0, "KYRKATX": 5}
SE_DEFAULT_RANK = 3

# SSR grades every name viktighetA (most important) .. viktighetM.
def no_rank(sortering: str | None) -> int:
    if sortering and sortering.startswith("viktighet") and len(sortering) == 10:
        return max(0, min(12, ord(sortering[-1].upper()) - ord("A")))
    return 7

# Language codes, normalised across both countries.
SE_LANG = {
    "SV": "sv", "FI": "fi", "TF": "fit",  # meänkieli / tornedalsfinska
    "NS": "se", "LS": "smj", "US": "sju", "SS": "sma",
}
NO_LANG = {
    "norsk": "no", "nordsamisk": "se", "lulesamisk": "smj",
    "sørsamisk": "sma", "skoltesamisk": "sms", "pitesamisk": "sje",
    "umesamisk": "sju", "kvensk": "fkv", "engelsk": "en",
    "svensk": "sv", "finsk": "fi", "russisk": "ru",
}


# Official SCB register codes; Lantmäteriet ships only the numeric codes.
# Source: https://api.scb.se/OV0104/v1/doris/sv/ssd/BE/BE0101/BE0101A/BefolkningNy
SE_LAN = {
    "01": "Stockholms län", "03": "Uppsala län", "04": "Södermanlands län",
    "05": "Östergötlands län", "06": "Jönköpings län", "07": "Kronobergs län",
    "08": "Kalmar län", "09": "Gotlands län", "10": "Blekinge län", "12": "Skåne län",
    "13": "Hallands län", "14": "Västra Götalands län", "17": "Värmlands län",
    "18": "Örebro län", "19": "Västmanlands län", "20": "Dalarnas län",
    "21": "Gävleborgs län", "22": "Västernorrlands län", "23": "Jämtlands län",
    "24": "Västerbottens län", "25": "Norrbottens län",
}

SE_KOMMUN = {
    "0114": "Upplands Väsby", "0115": "Vallentuna", "0117": "Österåker", "0120": "Värmdö",
    "0123": "Järfälla", "0125": "Ekerö", "0126": "Huddinge", "0127": "Botkyrka",
    "0128": "Salem", "0136": "Haninge", "0138": "Tyresö", "0139": "Upplands-Bro",
    "0140": "Nykvarn", "0160": "Täby", "0162": "Danderyd", "0163": "Sollentuna",
    "0180": "Stockholm", "0181": "Södertälje", "0182": "Nacka", "0183": "Sundbyberg",
    "0184": "Solna", "0186": "Lidingö", "0187": "Vaxholm", "0188": "Norrtälje",
    "0191": "Sigtuna", "0192": "Nynäshamn", "0305": "Håbo", "0319": "Älvkarleby",
    "0330": "Knivsta", "0331": "Heby", "0360": "Tierp", "0380": "Uppsala",
    "0381": "Enköping", "0382": "Östhammar", "0428": "Vingåker", "0461": "Gnesta",
    "0480": "Nyköping", "0481": "Oxelösund", "0482": "Flen", "0483": "Katrineholm",
    "0484": "Eskilstuna", "0486": "Strängnäs", "0488": "Trosa", "0509": "Ödeshög",
    "0512": "Ydre", "0513": "Kinda", "0560": "Boxholm", "0561": "Åtvidaberg",
    "0562": "Finspång", "0563": "Valdemarsvik", "0580": "Linköping", "0581": "Norrköping",
    "0582": "Söderköping", "0583": "Motala", "0584": "Vadstena", "0586": "Mjölby",
    "0604": "Aneby", "0617": "Gnosjö", "0642": "Mullsjö", "0643": "Habo",
    "0662": "Gislaved", "0665": "Vaggeryd", "0680": "Jönköping", "0682": "Nässjö",
    "0683": "Värnamo", "0684": "Sävsjö", "0685": "Vetlanda", "0686": "Eksjö",
    "0687": "Tranås", "0760": "Uppvidinge", "0761": "Lessebo", "0763": "Tingsryd",
    "0764": "Alvesta", "0765": "Älmhult", "0767": "Markaryd", "0780": "Växjö",
    "0781": "Ljungby", "0821": "Högsby", "0834": "Torsås", "0840": "Mörbylånga",
    "0860": "Hultsfred", "0861": "Mönsterås", "0862": "Emmaboda", "0880": "Kalmar",
    "0881": "Nybro", "0882": "Oskarshamn", "0883": "Västervik", "0884": "Vimmerby",
    "0885": "Borgholm", "0980": "Gotland", "1060": "Olofström", "1080": "Karlskrona",
    "1081": "Ronneby", "1082": "Karlshamn", "1083": "Sölvesborg", "1214": "Svalöv",
    "1230": "Staffanstorp", "1231": "Burlöv", "1233": "Vellinge", "1256": "Östra Göinge",
    "1257": "Örkelljunga", "1260": "Bjuv", "1261": "Kävlinge", "1262": "Lomma",
    "1263": "Svedala", "1264": "Skurup", "1265": "Sjöbo", "1266": "Hörby", "1267": "Höör",
    "1270": "Tomelilla", "1272": "Bromölla", "1273": "Osby", "1275": "Perstorp",
    "1276": "Klippan", "1277": "Åstorp", "1278": "Båstad", "1280": "Malmö", "1281": "Lund",
    "1282": "Landskrona", "1283": "Helsingborg", "1284": "Höganäs", "1285": "Eslöv",
    "1286": "Ystad", "1287": "Trelleborg", "1290": "Kristianstad", "1291": "Simrishamn",
    "1292": "Ängelholm", "1293": "Hässleholm", "1315": "Hylte", "1380": "Halmstad",
    "1381": "Laholm", "1382": "Falkenberg", "1383": "Varberg", "1384": "Kungsbacka",
    "1401": "Härryda", "1402": "Partille", "1407": "Öckerö", "1415": "Stenungsund",
    "1419": "Tjörn", "1421": "Orust", "1427": "Sotenäs", "1430": "Munkedal",
    "1435": "Tanum", "1438": "Dals-Ed", "1439": "Färgelanda", "1440": "Ale",
    "1441": "Lerum", "1442": "Vårgårda", "1443": "Bollebygd", "1444": "Grästorp",
    "1445": "Essunga", "1446": "Karlsborg", "1447": "Gullspång", "1452": "Tranemo",
    "1460": "Bengtsfors", "1461": "Mellerud", "1462": "Lilla Edet", "1463": "Mark",
    "1465": "Svenljunga", "1466": "Herrljunga", "1470": "Vara", "1471": "Götene",
    "1472": "Tibro", "1473": "Töreboda", "1480": "Göteborg", "1481": "Mölndal",
    "1482": "Kungälv", "1484": "Lysekil", "1485": "Uddevalla", "1486": "Strömstad",
    "1487": "Vänersborg", "1488": "Trollhättan", "1489": "Alingsås", "1490": "Borås",
    "1491": "Ulricehamn", "1492": "Åmål", "1493": "Mariestad", "1494": "Lidköping",
    "1495": "Skara", "1496": "Skövde", "1497": "Hjo", "1498": "Tidaholm",
    "1499": "Falköping", "1715": "Kil", "1730": "Eda", "1737": "Torsby", "1760": "Storfors",
    "1761": "Hammarö", "1762": "Munkfors", "1763": "Forshaga", "1764": "Grums",
    "1765": "Årjäng", "1766": "Sunne", "1780": "Karlstad", "1781": "Kristinehamn",
    "1782": "Filipstad", "1783": "Hagfors", "1784": "Arvika", "1785": "Säffle",
    "1814": "Lekeberg", "1860": "Laxå", "1861": "Hallsberg", "1862": "Degerfors",
    "1863": "Hällefors", "1864": "Ljusnarsberg", "1880": "Örebro", "1881": "Kumla",
    "1882": "Askersund", "1883": "Karlskoga", "1884": "Nora", "1885": "Lindesberg",
    "1904": "Skinnskatteberg", "1907": "Surahammar", "1960": "Kungsör",
    "1961": "Hallstahammar", "1962": "Norberg", "1980": "Västerås", "1981": "Sala",
    "1982": "Fagersta", "1983": "Köping", "1984": "Arboga", "2021": "Vansbro",
    "2023": "Malung-Sälen", "2026": "Gagnef", "2029": "Leksand", "2031": "Rättvik",
    "2034": "Orsa", "2039": "Älvdalen", "2061": "Smedjebacken", "2062": "Mora",
    "2080": "Falun", "2081": "Borlänge", "2082": "Säter", "2083": "Hedemora",
    "2084": "Avesta", "2085": "Ludvika", "2101": "Ockelbo", "2104": "Hofors",
    "2121": "Ovanåker", "2132": "Nordanstig", "2161": "Ljusdal", "2180": "Gävle",
    "2181": "Sandviken", "2182": "Söderhamn", "2183": "Bollnäs", "2184": "Hudiksvall",
    "2260": "Ånge", "2262": "Timrå", "2280": "Härnösand", "2281": "Sundsvall",
    "2282": "Kramfors", "2283": "Sollefteå", "2284": "Örnsköldsvik", "2303": "Ragunda",
    "2305": "Bräcke", "2309": "Krokom", "2313": "Strömsund", "2321": "Åre", "2326": "Berg",
    "2361": "Härjedalen", "2380": "Östersund", "2401": "Nordmaling", "2403": "Bjurholm",
    "2404": "Vindeln", "2409": "Robertsfors", "2417": "Norsjö", "2418": "Malå",
    "2421": "Storuman", "2422": "Sorsele", "2425": "Dorotea", "2460": "Vännäs",
    "2462": "Vilhelmina", "2463": "Åsele", "2480": "Umeå", "2481": "Lycksele",
    "2482": "Skellefteå", "2505": "Arvidsjaur", "2506": "Arjeplog", "2510": "Jokkmokk",
    "2513": "Överkalix", "2514": "Kalix", "2518": "Övertorneå", "2521": "Pajala",
    "2523": "Gällivare", "2560": "Älvsbyn", "2580": "Luleå", "2581": "Piteå",
    "2582": "Boden", "2583": "Haparanda", "2584": "Kiruna",
}


class Place(NamedTuple):
    kind: int
    rank: int
    lat: int          # micro-degrees
    lon: int
    country: int
    adm: str | None   # kommun / kommune
    region: str | None  # län / fylke
    names: list[tuple[str, str]]  # (spelling, language); first is primary


# Coordinates are stored as COORD_SCALE-ths of a degree. 1e5 is ~1.1 m, far
# finer than a label point is meaningful, and it keeps every value inside
# SQLite's 3-byte integer range (max 8,388,607) where 1e6 needed 4 bytes --
# 2 bytes per place across two columns.
COORD_SCALE = 100_000


def micro(value: float) -> int:
    return int(round(value * COORD_SCALE))


# ---------------------------------------------------------------------------
# Sweden
# ---------------------------------------------------------------------------

_ENVELOPE_SIZE = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}


def gpkg_point(blob: bytes) -> tuple[float, float] | None:
    """Return (x, y) from a GeoPackage POINT blob."""
    if not blob or len(blob) < 8 or blob[:2] != b"GP":
        return None
    flags = blob[3]
    offset = 8 + _ENVELOPE_SIZE[(flags >> 1) & 0x07]
    wkb = blob[offset:]
    if len(wkb) < 21:
        return None
    order = "<" if wkb[0] == 1 else ">"
    if struct.unpack(order + "I", wkb[1:5])[0] != 1:  # not a point
        return None
    return struct.unpack(order + "dd", wkb[5:21])


def read_sweden(path: str) -> Iterator[Place]:
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    rows = db.execute(
        "SELECT ortnamn, geom, ekoordinat, nkoordinat, detaljtyp, sprak, "
        "       kommunkod, lanskod "
        "FROM ortnamn WHERE ortnamn IS NOT NULL AND ortnamn <> '' "
        f"  AND detaljtyp NOT IN ({','.join('?' * len(SE_SKIP))})",
        tuple(SE_SKIP),
    ).fetchall()

    transformer = Transformer.from_crs("EPSG:3006", "EPSG:4326", always_xy=True)
    eastings, northings = [], []
    for name, blob, east, north, *_ in rows:
        point = gpkg_point(blob)
        if point is None:
            point = (east, north)
        eastings.append(point[0])
        northings.append(point[1])
    lons, lats = transformer.transform(eastings, northings)

    for i, (name, _blob, _e, _n, detaljtyp, sprak, kommun, lan) in enumerate(rows):
        lat, lon = lats[i], lons[i]
        if not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
            continue
        # The GeoPackage carries only numeric codes; resolve them to names so
        # results read the same way as the Norwegian ones. The county name is
        # kept in full ("Dalarnas län") because the bare stem is a genitive
        # and does not stand on its own.
        yield Place(
            kind=KIND_ID[SE_KIND.get(detaljtyp, "other")],
            rank=SE_RANK.get(detaljtyp, SE_DEFAULT_RANK),
            lat=micro(lat),
            lon=micro(lon),
            country=SWEDEN,
            adm=SE_KOMMUN.get(kommun or ""),
            region=SE_LAN.get(lan or ""),
            names=[(name.strip(), SE_LANG.get(sprak, "sv"))],
        )
    db.close()


# ---------------------------------------------------------------------------
# Norway
# ---------------------------------------------------------------------------

APP = "{https://skjema.geonorge.no/SOSI/produktspesifikasjon/StedsnavnForVanligBruk/20231001}"
GML = "{http://www.opengis.net/gml/3.2}"

# A place carries several spellings; these orderings decide which one is shown
# and which are kept as searchable aliases. Anything absent is not current and
# is dropped entirely.
SPELLING_RANK = {
    "vedtatt": 0,          # resolved by formal decision
    "vedtattNavneledd": 1, # decision covers part of the name
    "godkjent": 2,
    "internasjonal": 3,
    "privat": 4,
    "uvurdert": 5,         # in use but never formally assessed
}
NAME_STATUS_RANK = {
    "hovednavn": 0,        # main name
    "sidenavn": 1,         # parallel name, typically another language
    "undernavn": 2,        # subordinate name
}


def _coords(element: ElementTree.Element) -> tuple[float, float] | None:
    """Representative easting/northing for any SSR geometry."""
    texts: list[str] = []
    for tag in (f"{GML}pos", f"{GML}posList"):
        texts.extend(node.text or "" for node in element.iter(tag))
    values: list[float] = []
    for text in texts:
        values.extend(float(v) for v in text.split())
    if len(values) < 2:
        return None
    xs = values[0::2]
    ys = values[1::2]
    if len(xs) == 1:
        return xs[0], ys[0]
    # Midpoint of the extent is a stable, cheap label anchor for lines/areas.
    return (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2


def _text(element: ElementTree.Element, tag: str) -> str | None:
    node = element.find(tag)
    return node.text.strip() if node is not None and node.text else None


def _parse_sted(sted: ElementTree.Element) -> tuple | None:
    point = _coords(sted)
    if point is None:
        return None

    priority = (_text(sted, f"{APP}språkprioritering") or "norsk").split("-")

    # (name_status_rank, language_rank, spelling_rank, name, language)
    collected: list[tuple[int, int, int, str, str]] = []
    for holder in sted.findall(f"{APP}stedsnavn"):
        for navn in holder.findall(f"{APP}Stedsnavn"):
            status_rank = NAME_STATUS_RANK.get(_text(navn, f"{APP}navnestatus") or "")
            if status_rank is None:
                continue
            language = _text(navn, f"{APP}språk") or "norsk"
            try:
                language_rank = priority.index(language)
            except ValueError:
                language_rank = len(priority)
            for wrapper in navn.findall(f"{APP}skrivemåte"):
                for spelling in wrapper.findall(f"{APP}Skrivemåte"):
                    written = _text(spelling, f"{APP}komplettskrivemåte")
                    spelling_rank = SPELLING_RANK.get(
                        _text(spelling, f"{APP}skrivemåtestatus") or "")
                    if not written or spelling_rank is None:
                        continue
                    collected.append(
                        (status_rank, language_rank, spelling_rank, written, language))
    if not collected:
        return None

    collected.sort()
    names = [(written, language) for _s, _l, _p, written, language in collected]

    group = _text(sted, f"{APP}navneobjekthovedgruppe") or ""
    subgroup = _text(sted, f"{APP}navneobjektgruppe") or ""
    if group in NO_SKIP_GROUPS:
        return None
    kind = NO_SUBGROUP_KIND.get(subgroup) or NO_GROUP_KIND.get(group, "other")

    kommune = sted.find(f"{APP}kommune/{APP}Kommune")
    adm = _text(kommune, f"{APP}kommunenavn") if kommune is not None else None
    region = _text(kommune, f"{APP}fylkesnavn") if kommune is not None else None

    rank = no_rank(_text(sted, f"{APP}sortering"))
    return KIND_ID[kind], rank, adm, region, names, point[0], point[1]


def read_norway(path: str, batch: int = 20_000) -> Iterator[Place]:
    """Stream SSR, reprojecting in batches.

    Accepts either the raw .gml or the .zip as downloaded from Geonorge; the
    zip is streamed so the 2.6 GB GML never has to be written to disk.
    """
    transformer = Transformer.from_crs("EPSG:25833", "EPSG:4326", always_xy=True)
    pending: list[tuple] = []

    def flush() -> Iterator[Place]:
        if not pending:
            return
        lons, lats = transformer.transform([p[5] for p in pending],
                                           [p[6] for p in pending])
        for i, (kind, rank, adm, region, names, _x, _y) in enumerate(pending):
            lat, lon = lats[i], lons[i]
            if not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
                continue
            seen: set[str] = set()
            unique: list[tuple[str, str]] = []
            for written, language in names:
                folded = written.casefold()
                if folded in seen:
                    continue
                seen.add(folded)
                unique.append((written, NO_LANG.get(language, "no")))
            yield Place(kind, rank, micro(lat), micro(lon),
                        NORWAY, adm, region, unique)
        pending.clear()

    archive = None
    if path.lower().endswith(".zip"):
        archive = zipfile.ZipFile(path)
        members = [n for n in archive.namelist() if n.lower().endswith(".gml")]
        if not members:
            raise SystemExit(f"no .gml inside {path}")
        stream: object = archive.open(members[0])
    else:
        stream = open(path, "rb")

    try:
        for _event, element in ElementTree.iterparse(stream, events=("end",)):
            if element.tag != f"{APP}Sted":
                continue
            parsed = _parse_sted(element)
            if parsed is not None:
                pending.append(parsed)
            element.clear()
            if len(pending) >= batch:
                yield from flush()
        yield from flush()
    finally:
        stream.close()
        if archive is not None:
            archive.close()


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

SCHEMA = """
PRAGMA journal_mode = OFF;
PRAGMA synchronous  = OFF;
PRAGMA page_size    = 4096;

CREATE TABLE municipality (
    id      INTEGER PRIMARY KEY,
    name    TEXT,
    region  TEXT,
    country INTEGER NOT NULL
);

CREATE TABLE language (
    id   INTEGER PRIMARY KEY,
    code TEXT NOT NULL
);

CREATE TABLE place (
    id      INTEGER PRIMARY KEY,
    kind    INTEGER NOT NULL,
    rank    INTEGER NOT NULL,
    lat     INTEGER NOT NULL,   -- COORD_SCALE-ths of a degree, WGS84
    lon     INTEGER NOT NULL,
    country INTEGER NOT NULL,   -- 0 = SE, 1 = NO
    muni    INTEGER,            -- -> municipality.id
    name    TEXT NOT NULL       -- the name to display
);

-- Only the 1.2% of places that carry more than one official name. Holding the
-- display name in `place` instead of giving every place a row here removed
-- ~26 MB of per-row overhead: the names themselves were 19.7 MB of a 46.1 MB
-- table, the rest being rowids, back-links and row headers.
CREATE TABLE alias (
    id       INTEGER PRIMARY KEY,   -- offset by ALIAS_OFFSET, see below
    place_id INTEGER NOT NULL,
    name     TEXT NOT NULL,
    lang     INTEGER                -- -> language.id
);

CREATE VIRTUAL TABLE place_fts USING fts5(
    name,
    content = '',
    columnsize = 0,      -- no bm25; ranking is done in the app
    detail = none,       -- no positions needed, only "does this name match"
    tokenize = "unicode61 remove_diacritics 2"
);

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
"""


class Interner:
    """Maps repeated attribute values onto small integer ids."""

    def __init__(self) -> None:
        self.ids: dict[tuple, int] = {}
        self.rows: list[tuple] = []

    def id_for(self, key: tuple | None, row: tuple) -> int | None:
        if key is None:
            return None
        existing = self.ids.get(key)
        if existing is not None:
            return existing
        new_id = len(self.ids) + 1
        self.ids[key] = new_id
        self.rows.append((new_id,) + row)
        return new_id


def drop_duplicates(db: sqlite3.Connection, radius_m: float = 1000.0) -> int:
    """Delete same-name places sitting within `radius_m` of each other.

    Both registers label a long feature at several points, and the two of them
    overlap along the border, so one lake or stream can arrive as a dozen
    identical entries a few hundred metres apart. They add nothing to a search
    -- the user sees the same word repeated with the same subtitle -- so only
    the most important of each cluster is kept.

    Distances are geodesic, via PROJ. A degree box alone would be wrong: a
    degree of longitude is 62 km at 56°N but 25 km at 71°N, so a fixed box
    would cluster far more aggressively in the north than in the south.
    """
    rows = db.execute("SELECT id, name, kind, rank, lat, lon FROM place").fetchall()
    by_name: dict[str, list[tuple]] = {}
    for row in rows:
        by_name.setdefault(row[1], []).append(row)

    # Cheap bounding box first, so PROJ only sees plausible pairs. The margin
    # is the widest a degree gets over the covered latitudes, with room to
    # spare; anything it lets through is rejected on the real distance below.
    lat_margin = int(radius_m / 111_000 * COORD_SCALE) + 1
    lon_margin = int(radius_m / 40_000 * COORD_SCALE) + 1
    pairs: list[tuple[int, int]] = []
    lon1: list[float] = []
    lat1: list[float] = []
    lon2: list[float] = []
    lat2: list[float] = []
    for group in by_name.values():
        if len(group) < 2:
            continue
        ordered = sorted(group, key=lambda r: r[4])
        for i, left in enumerate(ordered):
            for right in ordered[i + 1:]:
                if right[4] - left[4] > lat_margin:
                    break
                if abs(right[5] - left[5]) > lon_margin:
                    continue
                pairs.append((left[0], right[0]))
                lon1.append(left[5] / COORD_SCALE); lat1.append(left[4] / COORD_SCALE)
                lon2.append(right[5] / COORD_SCALE); lat2.append(right[4] / COORD_SCALE)
    if not pairs:
        return 0

    _, _, distances = Geod(ellps="WGS84").inv(lon1, lat1, lon2, lat2)

    # Union-find: A near B and B near C collapses the whole chain, which is
    # what a string of label points along one river needs.
    parent: dict[int, int] = {}

    def find(node: int) -> int:
        parent.setdefault(node, node)
        while parent[node] != node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    for (left, right), metres in zip(pairs, distances):
        if metres > radius_m:
            continue
        root_left, root_right = find(left), find(right)
        if root_left != root_right:
            parent[root_left] = root_right

    clusters: dict[int, list[int]] = {}
    for node in parent:
        clusters.setdefault(find(node), []).append(node)

    # Keep the most important, then the most map-worthy category, so a village
    # outlives the bay it was named after.
    ranking = {row[0]: (row[3], row[2], row[0]) for row in rows}
    doomed = [
        (place_id,)
        for members in clusters.values()
        for place_id in sorted(members, key=lambda p: ranking[p])[1:]
    ]
    db.executemany("DELETE FROM alias WHERE place_id = ?", doomed)
    db.executemany("DELETE FROM place WHERE id = ?", doomed)
    return len(doomed)


def build(sources: Iterable[Iterator[Place]], out_path: str, scope: set[int] | None) -> None:
    if os.path.exists(out_path):
        os.remove(out_path)
    directory = os.path.dirname(os.path.abspath(out_path))
    os.makedirs(directory, exist_ok=True)

    db = sqlite3.connect(out_path)
    db.executescript(SCHEMA)

    municipalities = Interner()
    languages = Interner()

    place_id = 0
    alias_id = ALIAS_OFFSET
    places: list[tuple] = []
    aliases: list[tuple] = []

    def commit() -> None:
        db.executemany("INSERT INTO place VALUES (?,?,?,?,?,?,?,?)", places)
        db.executemany("INSERT INTO alias VALUES (?,?,?,?)", aliases)
        places.clear(); aliases.clear()

    for source in sources:
        for place in source:
            if scope is not None and place.kind not in scope:
                continue
            place_id += 1

            muni = municipalities.id_for(
                (place.country, place.adm, place.region) if place.adm or place.region else None,
                (place.adm, place.region, place.country),
            )

            # `names` is ordered with the display name first. It lives in
            # `place` and takes the place's own id as its FTS rowid; the rest
            # go to `alias`, whose ids start above every place id so a single
            # rowid space covers both. The index itself is built at the end,
            # once the duplicate pass has settled which places survive.
            display_name, _ = place.names[0]
            for name, lang in place.names[1:]:
                alias_id += 1
                lang_id = languages.id_for((lang,) if lang else None, (lang,))
                aliases.append((alias_id, place_id, name, lang_id))

            places.append((place_id, place.kind, place.rank, place.lat,
                           place.lon, place.country, muni, display_name))

            if len(places) >= 50_000:
                commit()
    commit()

    removed = drop_duplicates(db)

    # Built now rather than during the stream, so the deleted rows never enter
    # the index and no contentless-FTS delete dance is needed.
    db.execute("INSERT INTO place_fts(rowid, name) SELECT id, name FROM place")
    db.execute("INSERT INTO place_fts(rowid, name) SELECT id, name FROM alias")

    db.executemany("INSERT INTO municipality VALUES (?,?,?,?)", municipalities.rows)
    db.executemany("INSERT INTO language VALUES (?,?)", languages.rows)
    db.executescript("""
        INSERT INTO place_fts(place_fts) VALUES ('optimize');
    """)

    kept = db.execute("SELECT COUNT(*) FROM place").fetchone()[0]
    kept_aliases = db.execute("SELECT COUNT(*) FROM alias").fetchone()[0]
    kept_se, kept_no = (
        db.execute("SELECT COUNT(*) FROM place WHERE country = ?", (country,)).fetchone()[0]
        for country in (SWEDEN, NORWAY)
    )
    db.executemany("INSERT INTO meta VALUES (?,?)", [
        ("built", time.strftime("%Y-%m-%d")),
        ("places", str(kept)),
        ("names", str(kept + kept_aliases)),
        ("coord_scale", str(COORD_SCALE)),
        ("places_se", str(kept_se)),
        ("places_no", str(kept_no)),
        ("kinds", ",".join(KINDS)),
        ("attribution_se", "© Lantmäteriet, Ortnamn"),
        ("attribution_no", "© Kartverket, Sentralt stedsnavnregister"),
    ])
    db.commit()
    db.execute("VACUUM")
    db.close()

    size = os.path.getsize(out_path) / 1e6
    print(f"  places  {kept:>9,}  (SE {kept_se:,} / NO {kept_no:,})")
    print(f"  dupes   {removed:>9,}  removed within 1 km")
    print(f"  names   {kept + kept_aliases:>9,}  ({kept_aliases:,} aliases)")
    print(f"  size    {size:>9.1f} MB  -> {out_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--se", help="Lantmäteriet Ortnamn GeoPackage")
    parser.add_argument("--no", dest="no_", help="Kartverket SSR GML")
    parser.add_argument("--out", default="fjallkartan/Resources/places.sqlite")
    parser.add_argument("--scope", default="all",
                        help="'all', or comma-separated categories to keep, "
                             f"from: {', '.join(KINDS)}")
    args = parser.parse_args()

    if not args.se and not args.no_:
        parser.error("give at least one of --se / --no")

    scope: set[int] | None = None
    if args.scope != "all":
        names = [s.strip() for s in args.scope.split(",") if s.strip()]
        unknown = [n for n in names if n not in KIND_ID]
        if unknown:
            parser.error(f"unknown categories: {', '.join(unknown)}")
        scope = {KIND_ID[n] for n in names}

    sources = []
    if args.se:
        print(f"Sweden  {args.se}")
        sources.append(read_sweden(args.se))
    if args.no_:
        print(f"Norway  {args.no_}")
        sources.append(read_norway(args.no_))

    started = time.time()
    build(sources, args.out, scope)
    print(f"  took    {time.time() - started:>9.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
