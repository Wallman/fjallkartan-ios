#!/usr/bin/env python3
"""Build Swedish slope ("bratthet") raster tiles from Lantmäteriet höjddata.

The app already shows NVE's Norwegian steepness layer. This produces the
Swedish half of that picture, in the *same* colour scale, so the two meet
seamlessly at the border.

Source
------
Lantmäteriet STAC "hojd" API (https://api.lantmateriet.se/stac-hojd/v1),
collections `mhm-NN_M` -- Markhöjdmodell, 1 m ground grid as GeoTIFF/COG,
licensed CC BY 4.0. The STAC catalogue is public; the asset downloads on
dl1.lantmateriet.se need HTTP Basic auth (LANTMATERIET_USERNAME/PASSWORD).

Why 8 m and not the native 1 m
------------------------------
Slope at 1 m resolves stream banks, boulders and road cuts as "steep". That is
real micro-relief but it is not avalanche terrain, and NVE's ~10 m DTM shows
none of it -- rendering it would scatter red speckle across Swedish lowlands
that stops dead at the Norwegian border. Measured on a gentle-terrain sample,
1 m flags 10x more ground as >=30 degrees than 8 m does. So we read the COG's
prebuilt 8 m overview (verified to be area-averaged, not decimated) via HTTP
range requests: ~9 GB for the whole country instead of 717 GB.

Colour scale (NVE "Bratthet med utløp 2024", sampled from its own legend)
------------------------------------------------------------------------
    < 30       fully transparent
    30 - 35    255,255,0
    35 - 40    255,170,0
    40 - 45    255,85,0
    45 - 50    255,0,0
    50 - 90    115,0,0

NVE publishes a green 27-30 class in its slope-only service, but the
runout composite the app actually uses omits it. We omit it too.

Slope is computed with Horn's 3x3 operator in SWEREF99 TM (metric) and only
*then* reprojected to WebMercator. Doing it the other way round would inflate
slope by 1/cos(latitude) -- a factor of ~2.4 at 65 degrees north.

Usage
-----
    export LANTMATERIET_USERNAME=... LANTMATERIET_PASSWORD=...

    # 1. cache the 8 m elevation grid (~9 GB, resumable)
    python3 tools/build_sweden_slope_tiles.py fetch

    # 2. render tiles into out/slope/{z}/{y}/{x}.png
    python3 tools/build_sweden_slope_tiles.py tiles

    # 3. check we agree with NVE where the two datasets overlap at the border
    python3 tools/build_sweden_slope_tiles.py verify

    # 4. publish to R2 (needs R2_* env vars, see upload_gpkg_tiles_to_r2.py)
    python3 tools/build_sweden_slope_tiles.py upload --bucket tiles --prefix slope/v1

Requires: rasterio, numpy, pillow  (pip install rasterio numpy pillow)
          boto3 only for `upload`.
"""

from __future__ import annotations

import argparse
import io
import json
import math
import os
import random
import sys
import threading
import time
import warnings
import urllib.error
import urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import rasterio
from PIL import Image
from rasterio.enums import Resampling
from rasterio.errors import NotGeoreferencedWarning
from rasterio.transform import from_origin
from rasterio.warp import reproject, transform_bounds

# We hand reproject() plain ndarrays plus an explicit transform/crs, which is
# supported but makes rasterio warn about the arrays not carrying a geotransform.
warnings.filterwarnings("ignore", category=NotGeoreferencedWarning)

STAC_ROOT = "https://api.lantmateriet.se/stac-hojd/v1"

# Reference services used by the `verify` stage.
NVE_TILE_URL = (
    "https://gis3.nve.no/arcgis/rest/services/wmts/"
    "Bratthet_med_utlop_2024/MapServer/tile/{z}/{y}/{x}"
)
# Kartverket's topo cache is blank outside Norway, which makes its alpha channel
# a usable "is this Norway?" mask. NVE's own tiles cannot serve that purpose:
# they are equally transparent for "below 30 degrees" and for "not covered".
KARTVERKET_TILE_URL = (
    "https://cache.kartverket.no/v1/wmts/1.0.0/topo/default/webmercator/{z}/{y}/{x}.png"
)
# NVE paints modelled runout in three blues. Sweden has no equivalent product,
# so those pixels are excluded from the comparison rather than counted as misses.
NVE_RUNOUT_RGB = [(0, 77, 168), (76, 155, 255), (154, 177, 230)]

# Slope class breaks in degrees, and the RGB the class renders as. Index 0 is
# "below 30 degrees" and is always fully transparent.
BREAKS = [30.0, 35.0, 40.0, 45.0, 50.0]
PALETTE = [
    (0, 0, 0),
    (255, 255, 0),
    (255, 170, 0),
    (255, 85, 0),
    (255, 0, 0),
    (115, 0, 0),
]

# Working grid. SWEREF99 TM (the horizontal part of the items' EPSG:5845), at
# 10 m. Item bounds are always multiples of 2500 m, so a 10 m grid divides them
# exactly and neighbouring cached rasters abut without overlap or seams -- which
# an 8 m grid would not (2500 / 8 = 312.5).
GRID_CRS = "EPSG:3006"
GRID_RES = 10.0
GRID_ORIGIN_X = 0.0
GRID_ORIGIN_Y = 8_000_000.0

# Resolution of the overview we read. 8 m is the closest available to GRID_RES.
SOURCE_OVERVIEW_RES = 8.0

TILE_SIZE = 256
WEBMERCATOR_SPAN = 20037508.342789244
NODATA = -9999.0

MAX_HTTP_RETRIES = 8
STAC_CONCURRENCY = 3  # the API returns 429 if you enumerate harder than this


# --------------------------------------------------------------------------
# STAC catalogue
# --------------------------------------------------------------------------

def http_json(url: str) -> dict:
    """GET a JSON document, retrying 429/503 with exponential backoff."""
    last = None
    for attempt in range(MAX_HTTP_RETRIES):
        try:
            with urllib.request.urlopen(url, timeout=300) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code not in (429, 500, 502, 503, 504):
                raise
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            last = exc
        time.sleep(min(60.0, 2.0**attempt + random.random() * 2.0))
    raise RuntimeError(f"giving up on {url}: {last}")


def list_collections() -> list[str]:
    doc = http_json(f"{STAC_ROOT}/collections")
    return sorted(c["id"] for c in doc["collections"] if c["id"].startswith("mhm-"))


@dataclass(frozen=True)
class Item:
    id: str
    collection: str
    href: str

    @property
    def cache_name(self) -> str:
        return f"{self.collection}/{self.id}.tif"


def list_items(collection: str, cache_dir: Path) -> list[Item]:
    """Enumerate a collection's items, memoising the listing on disk."""
    index = cache_dir / "index" / f"{collection}.json"
    if index.exists():
        raw = json.loads(index.read_text())
    else:
        raw = {}
        url = f"{STAC_ROOT}/collections/{collection}/items?limit=500"
        while url:
            doc = http_json(url)
            for feature in doc["features"]:
                raw[feature["id"]] = feature["assets"]["data"]["href"]
            url = next((l["href"] for l in doc.get("links", []) if l["rel"] == "next"), None)
        index.parent.mkdir(parents=True, exist_ok=True)
        index.write_text(json.dumps(raw))
    return [Item(id=k, collection=collection, href=v) for k, v in sorted(raw.items())]


# --------------------------------------------------------------------------
# Stage 1 -- fetch the 8 m grid onto the canonical 10 m grid
# --------------------------------------------------------------------------

def pick_overview(factors: list[int]) -> int | None:
    """Index of the overview closest to SOURCE_OVERVIEW_RES, or None for full res.

    Overview depth varies between items -- most go 2/4/8/16/32, some stop
    earlier -- so this must be derived per item rather than hardcoded.
    """
    if not factors:
        return None
    wanted = int(SOURCE_OVERVIEW_RES)
    usable = [(i, f) for i, f in enumerate(factors) if f <= wanted]
    if not usable:
        return None
    return max(usable, key=lambda pair: pair[1])[0]


def grid_window(left: float, bottom: float, right: float, top: float):
    """Snap a bounding box outwards to whole canonical grid cells."""
    col0 = math.floor((left - GRID_ORIGIN_X) / GRID_RES)
    col1 = math.ceil((right - GRID_ORIGIN_X) / GRID_RES)
    row0 = math.floor((GRID_ORIGIN_Y - top) / GRID_RES)
    row1 = math.ceil((GRID_ORIGIN_Y - bottom) / GRID_RES)
    return col0, row0, col1 - col0, row1 - row0


def grid_transform(col: int, row: int):
    return from_origin(
        GRID_ORIGIN_X + col * GRID_RES,
        GRID_ORIGIN_Y - row * GRID_RES,
        GRID_RES,
        GRID_RES,
    )


def fetch_item(item: Item, cache_dir: Path) -> str:
    """Read one item's 8 m overview and store it on the canonical grid."""
    out = cache_dir / "dem" / item.cache_name
    if out.exists() and out.stat().st_size > 0:
        return "cached"
    out.parent.mkdir(parents=True, exist_ok=True)

    url = "/vsicurl/" + item.href
    with rasterio.open(url) as probe:
        level = pick_overview(probe.overviews(1))
    opener = rasterio.open(url) if level is None else rasterio.open(url, OVERVIEW_LEVEL=level)
    with opener as src:
        source = src.read(1, masked=True)
        source_transform = src.transform
        bounds = src.bounds

    data = np.ma.filled(source.astype("float32"), NODATA)
    col, row, width, height = grid_window(*bounds)
    dst_transform = grid_transform(col, row)
    resampled = np.full((height, width), NODATA, dtype="float32")
    reproject(
        source=data,
        destination=resampled,
        src_transform=source_transform,
        src_crs=GRID_CRS,
        src_nodata=NODATA,
        dst_transform=dst_transform,
        dst_crs=GRID_CRS,
        dst_nodata=NODATA,
        resampling=Resampling.average,
    )

    profile = {
        "driver": "GTiff",
        "dtype": "float32",
        "count": 1,
        "width": width,
        "height": height,
        "crs": GRID_CRS,
        "transform": dst_transform,
        "nodata": NODATA,
        "compress": "deflate",
        "predictor": 3,
        "tiled": False,
    }
    tmp = out.with_suffix(".tmp")
    with rasterio.open(tmp, "w", **profile) as dst:
        dst.write(resampled, 1)
    tmp.replace(out)
    return "fetched"


def stage_fetch(args, collections: list[str]) -> None:
    cache_dir = Path(args.cache_dir).expanduser()
    items: list[Item] = []
    print(f"enumerating {len(collections)} collections...", flush=True)
    with ThreadPoolExecutor(max_workers=STAC_CONCURRENCY) as pool:
        for found in pool.map(lambda c: list_items(c, cache_dir), collections):
            items.extend(found)
    if args.limit:
        items = items[: args.limit]
    print(f"{len(items):,} items", flush=True)

    done = failed = 0
    lock = threading.Lock()

    def run(item: Item):
        nonlocal done, failed
        try:
            result = fetch_item(item, cache_dir)
        except Exception as exc:  # noqa: BLE001 - one bad tile must not stop the run
            with lock:
                failed += 1
            return f"FAIL {item.id}: {exc}"
        with lock:
            done += 1
            if done % 250 == 0:
                print(f"  {done:,}/{len(items):,} ({failed} failed)", flush=True)
        return None

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for message in pool.map(run, items):
            if message:
                print(message, file=sys.stderr, flush=True)
    print(f"done: {done:,} items, {failed} failed")


# --------------------------------------------------------------------------
# Stage 2 -- slope, classify, tile
# --------------------------------------------------------------------------

class Mosaic:
    """Random access to the cached rasters as one virtual grid.

    They all share the canonical grid, so assembling a window is an integer
    paste rather than a resample.
    """

    def __init__(self, cache_dir: Path, cache_size: int = 256):
        self.paths: list[Path] = sorted((cache_dir / "dem").rglob("*.tif"))
        self.extents: list[tuple[int, int, int, int, Path]] = []
        self._arrays: OrderedDict[Path, np.ndarray] = OrderedDict()
        self._cache_size = cache_size
        self._lock = threading.Lock()
        manifest = cache_dir / "mosaic.json"
        if manifest.exists():
            payload = json.loads(manifest.read_text())
            if payload.get("count") == len(self.paths):
                self.extents = [
                    (e[0], e[1], e[2], e[3], Path(e[4])) for e in payload["extents"]
                ]
        if not self.extents:
            for path in self.paths:
                with rasterio.open(path) as src:
                    col = int(round((src.transform.c - GRID_ORIGIN_X) / GRID_RES))
                    row = int(round((GRID_ORIGIN_Y - src.transform.f) / GRID_RES))
                    self.extents.append((col, row, src.width, src.height, path))
            manifest.write_text(
                json.dumps(
                    {
                        "count": len(self.paths),
                        "extents": [[c, r, w, h, str(p)] for c, r, w, h, p in self.extents],
                    }
                )
            )
        self.bounds = self._compute_bounds()

    def _compute_bounds(self):
        if not self.extents:
            return None
        col0 = min(e[0] for e in self.extents)
        row0 = min(e[1] for e in self.extents)
        col1 = max(e[0] + e[2] for e in self.extents)
        row1 = max(e[1] + e[3] for e in self.extents)
        return col0, row0, col1, row1

    def _array(self, path: Path) -> np.ndarray:
        with self._lock:
            cached = self._arrays.get(path)
            if cached is not None:
                self._arrays.move_to_end(path)
                return cached
        with rasterio.open(path) as src:
            data = src.read(1)
        with self._lock:
            self._arrays[path] = data
            while len(self._arrays) > self._cache_size:
                self._arrays.popitem(last=False)
        return data

    def read(self, col: int, row: int, width: int, height: int) -> np.ndarray:
        out = np.full((height, width), NODATA, dtype="float32")
        for scol, srow, swidth, sheight, path in self.extents:
            ocol0 = max(col, scol)
            orow0 = max(row, srow)
            ocol1 = min(col + width, scol + swidth)
            orow1 = min(row + height, srow + sheight)
            if ocol0 >= ocol1 or orow0 >= orow1:
                continue
            data = self._array(path)
            out[orow0 - row : orow1 - row, ocol0 - col : ocol1 - col] = data[
                orow0 - srow : orow1 - srow, ocol0 - scol : ocol1 - scol
            ]
        return out


def horn_slope(dem: np.ndarray, resolution: float) -> np.ndarray:
    """Slope in degrees, Horn's 3x3 operator -- the same one gdaldem uses.

    Returns an array two rows and columns smaller than the input.
    """
    z = dem
    dzdx = (
        (z[:-2, 2:] + 2 * z[1:-1, 2:] + z[2:, 2:])
        - (z[:-2, :-2] + 2 * z[1:-1, :-2] + z[2:, :-2])
    ) / (8 * resolution)
    dzdy = (
        (z[2:, :-2] + 2 * z[2:, 1:-1] + z[2:, 2:])
        - (z[:-2, :-2] + 2 * z[:-2, 1:-1] + z[:-2, 2:])
    ) / (8 * resolution)
    return np.degrees(np.arctan(np.hypot(dzdx, dzdy)))


def classify(dem: np.ndarray, resolution: float) -> np.ndarray:
    """DEM window -> slope class indices, cropped by the 1 px slope halo."""
    valid = dem != NODATA
    work = np.where(valid, dem, np.nan)
    with np.errstate(invalid="ignore"):
        slope = horn_slope(work, resolution)
        classes = np.digitize(slope, BREAKS).astype(np.uint8)
    # NaN sorts above every break, so mask it back to "transparent" explicitly.
    classes[~np.isfinite(slope)] = 0
    inner = valid[1:-1, 1:-1]
    classes[~inner] = 0
    return classes


def tile_bounds(z: int, x: int, y: int) -> tuple[float, float, float, float]:
    span = 2 * WEBMERCATOR_SPAN / (2**z)
    left = -WEBMERCATOR_SPAN + x * span
    top = WEBMERCATOR_SPAN - y * span
    return left, top - span, left + span, top


def lonlat_to_tile(lon: float, lat: float, z: int) -> tuple[int, int]:
    n = 2**z
    x = int((lon + 180.0) / 360.0 * n)
    lat = max(min(lat, 85.05112878), -85.05112878)
    rad = math.radians(lat)
    y = int((1.0 - math.log(math.tan(rad) + 1.0 / math.cos(rad)) / math.pi) / 2.0 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))


def encode_png(classes: np.ndarray) -> bytes:
    image = Image.fromarray(classes, mode="P")
    flat: list[int] = []
    for rgb in PALETTE:
        flat.extend(rgb)
    image.putpalette(flat + [0] * (768 - len(flat)))
    # Class 0 is the only transparent entry; the rest are fully opaque.
    image.info["transparency"] = bytes([0] + [255] * (len(PALETTE) - 1))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True, bits=4)
    return buffer.getvalue()


def render_tile(mosaic: Mosaic, z: int, x: int, y: int) -> np.ndarray | None:
    """Classified 256x256 tile in WebMercator, or None if nothing is steep."""
    left, bottom, right, top = tile_bounds(z, x, y)
    # Sample the edges too: the projection is not affine, so corners alone can
    # under-cover the footprint at these latitudes.
    try:
        src_left, src_bottom, src_right, src_top = transform_bounds(
            "EPSG:3857", GRID_CRS, left, bottom, right, top, densify_pts=21
        )
    except Exception:  # noqa: BLE001 - tiles outside the projection's domain
        return None

    margin = 3 * GRID_RES
    col, row, width, height = grid_window(
        src_left - margin, src_bottom - margin, src_right + margin, src_top + margin
    )
    if width <= 3 or height <= 3:
        return None
    if disjoint_from_mosaic(mosaic, col, row, width, height):
        return None

    dem = mosaic.read(col, row, width, height)
    if not np.any(dem != NODATA):
        return None

    classes = classify(dem, GRID_RES)
    if not classes.any():
        return None

    # classify() dropped one pixel all round, so shift the transform to match.
    src_transform = grid_transform(col + 1, row + 1)
    destination = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.uint8)
    dst_transform = from_origin(
        left, top, (right - left) / TILE_SIZE, (top - bottom) / TILE_SIZE
    )
    reproject(
        source=classes,
        destination=destination,
        src_transform=src_transform,
        src_crs=GRID_CRS,
        dst_transform=dst_transform,
        dst_crs="EPSG:3857",
        # Nearest only: blending class indices would invent colours that are
        # not in the palette.
        resampling=Resampling.nearest,
    )
    return destination if destination.any() else None


def disjoint_from_mosaic(mosaic: Mosaic, col: int, row: int, width: int, height: int) -> bool:
    if mosaic.bounds is None:
        return True
    bcol0, brow0, bcol1, brow1 = mosaic.bounds
    return col + width <= bcol0 or col >= bcol1 or row + height <= brow0 or row >= brow1


def tile_path(out_dir: Path, z: int, x: int, y: int) -> Path:
    # z/y/x mirrors the key layout already used in the R2 bucket.
    return out_dir / str(z) / str(y) / f"{x}.png"


def base_tiles(mosaic: Mosaic, zoom: int) -> set[tuple[int, int]]:
    """Every tile at `zoom` that overlaps cached data."""
    tiles: set[tuple[int, int]] = set()
    for col, row, width, height, _ in mosaic.extents:
        left = GRID_ORIGIN_X + col * GRID_RES
        top = GRID_ORIGIN_Y - row * GRID_RES
        right = left + width * GRID_RES
        bottom = top - height * GRID_RES
        west, south, east, north = transform_bounds(
            GRID_CRS, "EPSG:4326", left, bottom, right, top, densify_pts=21
        )
        x0, y0 = lonlat_to_tile(west, north, zoom)
        x1, y1 = lonlat_to_tile(east, south, zoom)
        for x in range(min(x0, x1), max(x0, x1) + 1):
            for y in range(min(y0, y1), max(y0, y1) + 1):
                tiles.add((x, y))
    return tiles


def stage_tiles(args) -> None:
    cache_dir = Path(args.cache_dir).expanduser()
    out_dir = Path(args.out).expanduser()
    mosaic = Mosaic(cache_dir)
    if not mosaic.extents:
        sys.exit(f"no cached rasters under {cache_dir / 'dem'} -- run `fetch` first")
    print(f"{len(mosaic.extents):,} cached rasters", flush=True)

    targets = sorted(base_tiles(mosaic, args.max_zoom))
    print(f"z{args.max_zoom}: {len(targets):,} candidate tiles", flush=True)

    written = skipped = 0
    lock = threading.Lock()

    def run(xy):
        nonlocal written, skipped
        x, y = xy
        path = tile_path(out_dir, args.max_zoom, x, y)
        if path.exists() and not args.overwrite:
            return
        classes = render_tile(mosaic, args.max_zoom, x, y)
        with lock:
            if classes is None:
                skipped += 1
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(encode_png(classes))
                written += 1
            total = written + skipped
            if total % 2000 == 0:
                print(f"  {total:,}/{len(targets):,} ({written:,} written)", flush=True)

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(run, targets))
    print(f"z{args.max_zoom}: {written:,} tiles written, {skipped:,} empty", flush=True)

    for z in range(args.max_zoom - 1, args.min_zoom - 1, -1):
        written = build_overview_zoom(out_dir, z, args.overwrite)
        print(f"z{z}: {written:,} tiles written", flush=True)


def build_overview_zoom(out_dir: Path, z: int, overwrite: bool) -> int:
    """Build zoom z by combining the four children from z+1.

    Children are combined with a per-2x2-block maximum: at low zoom a steep
    face must stay visible rather than being averaged into its flat
    surroundings, and max keeps the output inside the palette.
    """
    child_dir = out_dir / str(z + 1)
    if not child_dir.is_dir():
        return 0
    parents: set[tuple[int, int]] = set()
    for y_dir in child_dir.iterdir():
        if not y_dir.is_dir():
            continue
        y = int(y_dir.name)
        for png in y_dir.glob("*.png"):
            parents.add((int(png.stem) // 2, y // 2))

    written = 0
    for x, y in sorted(parents):
        path = tile_path(out_dir, z, x, y)
        if path.exists() and not overwrite:
            continue
        merged = np.zeros((TILE_SIZE * 2, TILE_SIZE * 2), dtype=np.uint8)
        found = False
        for dx in (0, 1):
            for dy in (0, 1):
                child = tile_path(out_dir, z + 1, x * 2 + dx, y * 2 + dy)
                if not child.exists():
                    continue
                with Image.open(child) as image:
                    merged[
                        dy * TILE_SIZE : (dy + 1) * TILE_SIZE,
                        dx * TILE_SIZE : (dx + 1) * TILE_SIZE,
                    ] = np.array(image.convert("P"), dtype=np.uint8)
                found = True
        if not found:
            continue
        blocks = merged.reshape(TILE_SIZE, 2, TILE_SIZE, 2)
        downsampled = blocks.max(axis=(1, 3)).astype(np.uint8)
        if not downsampled.any():
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(encode_png(downsampled))
        written += 1
    return written


# --------------------------------------------------------------------------
# Stage 3 -- verify against NVE across the border
# --------------------------------------------------------------------------

def coverage_mask(mosaic: Mosaic, z: int, x: int, y: int) -> np.ndarray:
    """Which pixels of a tile the Swedish DEM actually has data for."""
    left, bottom, right, top = tile_bounds(z, x, y)
    src_left, src_bottom, src_right, src_top = transform_bounds(
        "EPSG:3857", GRID_CRS, left, bottom, right, top, densify_pts=21
    )
    margin = 3 * GRID_RES
    col, row, width, height = grid_window(
        src_left - margin, src_bottom - margin, src_right + margin, src_top + margin
    )
    dem = mosaic.read(col, row, width, height)
    out = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.uint8)
    reproject(
        source=(dem != NODATA).astype(np.uint8),
        destination=out,
        src_transform=grid_transform(col, row),
        src_crs=GRID_CRS,
        dst_transform=from_origin(
            left, top, (right - left) / TILE_SIZE, (top - bottom) / TILE_SIZE
        ),
        dst_crs="EPSG:3857",
        resampling=Resampling.nearest,
    )
    return out > 0


def fetch_rgba(url: str) -> np.ndarray | None:
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                payload = response.read()
            with Image.open(io.BytesIO(payload)) as image:
                return np.array(image.convert("RGBA"))
        except Exception:  # noqa: BLE001
            time.sleep(2.0**attempt)
    return None


def to_classes(rgba: np.ndarray) -> np.ndarray:
    """RGBA -> class index, or -1 for any colour outside our palette."""
    out = np.full(rgba.shape[:2], -1, dtype=np.int8)
    for index, rgb in enumerate(PALETTE):
        match = np.all(rgba[:, :, :3] == rgb, axis=-1)
        if index == 0:
            match &= rgba[:, :, 3] == 0
        out[match] = index
    return out


def select_verify_tiles(out_dir: Path, zoom: int, sample: int) -> list[tuple[int, int]]:
    """Pick tiles worth comparing: the westernmost ones in each row.

    Overlap with NVE only exists in the strip where the Swedish model reaches
    past the border, so comparing arbitrary tiles would spend two HTTP requests
    each to discover there is nothing to compare. Norway is west of Sweden, so
    the leading edge of our own coverage in each row is a good proxy for the
    border without needing to fetch anything first.
    """
    by_row: dict[int, list[int]] = {}
    for path in (out_dir / str(zoom)).glob("*/*.png"):
        by_row.setdefault(int(path.parent.name), []).append(int(path.stem))
    if not by_row:
        return []
    per_row = max(1, sample // max(1, len(by_row)))
    tiles: list[tuple[int, int]] = []
    for y, xs in sorted(by_row.items()):
        for x in sorted(xs)[:per_row]:
            tiles.append((y, x))
    if len(tiles) > sample:
        step = len(tiles) / sample
        tiles = [tiles[int(i * step)] for i in range(sample)]
    return tiles


def stage_verify(args) -> None:
    """Measure class agreement with NVE where Sweden and Norway overlap.

    Lantmäteriet's model reaches a few kilometres past the border, which gives
    a strip where both products describe the same ground. Comparison is
    restricted to that strip -- outside it, "flat" and "not covered" are both
    transparent on both sides and any agreement number would be meaningless.
    """
    mosaic = Mosaic(Path(args.cache_dir).expanduser())
    out_dir = Path(args.out).expanduser()
    candidates = select_verify_tiles(out_dir, args.max_zoom, args.sample)
    if not candidates:
        sys.exit(f"no z{args.max_zoom} tiles under {out_dir} -- run `tiles` first")
    print(f"examining {len(candidates)} tiles along the western edge", flush=True)

    confusion = np.zeros((len(PALETTE), len(PALETTE)), dtype=np.int64)
    compared = 0
    for y, x in candidates:
        path = tile_path(out_dir, args.max_zoom, x, y)
        norway = fetch_rgba(KARTVERKET_TILE_URL.format(z=args.max_zoom, y=y, x=x))
        nve = fetch_rgba(NVE_TILE_URL.format(z=args.max_zoom, y=y, x=x))
        if norway is None or nve is None:
            continue
        nve_class = to_classes(nve)
        with Image.open(path) as image:
            ours = to_classes(np.array(image.convert("RGBA")))

        usable = coverage_mask(mosaic, args.max_zoom, x, y)
        usable &= norway[:, :, 3] > 0
        usable &= (nve_class >= 0) & (ours >= 0)
        for rgb in NVE_RUNOUT_RGB:
            usable &= ~np.all(nve[:, :, :3] == rgb, axis=-1)
        if usable.sum() < args.min_overlap:
            continue

        compared += 1
        a = nve_class[usable].astype(int)
        b = ours[usable].astype(int)
        np.add.at(confusion, (a, b), 1)
        print(
            f"  z{args.max_zoom}/{y}/{x}: n={usable.sum():6d} "
            f"exact={100 * (a == b).mean():5.1f}%",
            flush=True,
        )
        if compared >= args.max_compared:
            break

    total = confusion.sum()
    if not total:
        sys.exit("no overlapping pixels found -- pick tiles nearer the border")
    exact = np.trace(confusion)
    within_one = sum(
        confusion[i, j]
        for i in range(len(PALETTE))
        for j in range(len(PALETTE))
        if abs(i - j) <= 1
    )
    print(f"\n{compared} tiles, {total:,} comparable pixels")
    print(f"exact class agreement : {100 * exact / total:.1f}%")
    print(f"within one class      : {100 * within_one / total:.1f}%")
    print(f"steep (>=30) NVE {100 * confusion[1:, :].sum() / total:.2f}% "
          f"vs SE {100 * confusion[:, 1:].sum() / total:.2f}%")
    print("confusion (rows NVE, cols SE):")
    print(confusion)
    if 100 * exact / total < args.min_agreement:
        sys.exit(f"FAIL: below --min-agreement {args.min_agreement}%")
    print("OK")


# --------------------------------------------------------------------------
# Stage 4 -- publish
# --------------------------------------------------------------------------

def stage_upload(args) -> None:
    import boto3
    from botocore.config import Config

    account = os.environ.get("R2_ACCOUNT_ID")
    access_key = os.environ.get("R2_ACCESS_KEY_ID")
    secret_key = os.environ.get("R2_SECRET_ACCESS_KEY")
    if not (account and access_key and secret_key):
        sys.exit("R2_ACCOUNT_ID, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY must be set")

    prefix = args.prefix
    if prefix and not prefix.endswith("/"):
        prefix += "/"

    client = boto3.client(
        "s3",
        endpoint_url=f"https://{account}.r2.cloudflarestorage.com",
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        config=Config(
            signature_version="s3v4",
            retries={"max_attempts": 5, "mode": "adaptive"},
            max_pool_connections=args.jobs * 2,
        ),
        region_name="auto",
    )

    out_dir = Path(args.out).expanduser()
    files = sorted(out_dir.rglob("*.png"))
    print(f"{len(files):,} tiles to upload", flush=True)
    done = 0
    lock = threading.Lock()

    def put(path: Path):
        nonlocal done
        relative = path.relative_to(out_dir)
        key = f"{prefix}{relative.as_posix()}"
        client.put_object(
            Bucket=args.bucket,
            Key=key,
            Body=path.read_bytes(),
            ContentType="image/png",
            CacheControl="public, max-age=31536000, immutable",
        )
        with lock:
            done += 1
            if done % 1000 == 0:
                print(f"  {done:,}/{len(files):,}", flush=True)

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for future in as_completed([pool.submit(put, f) for f in files]):
            future.result()
    print(f"uploaded {done:,} tiles")


# --------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build Swedish slope tiles matching NVE's colour scale.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("stage", choices=("fetch", "tiles", "verify", "upload"))
    parser.add_argument(
        "--collections",
        default="all",
        help="'all' (default) or a comma-separated list of mhm suffixes, e.g. 75_6,75_7",
    )
    parser.add_argument("--cache-dir", default="~/.cache/fjallkartan-hojd")
    parser.add_argument("--out", default="out/slope")
    parser.add_argument("--min-zoom", type=int, default=5)
    parser.add_argument(
        "--max-zoom",
        type=int,
        default=13,
        help="13 is where one tile pixel is about one source cell; deeper zooms "
             "add no detail and are left to the client to upsample",
    )
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--limit", type=int, default=0, help="cap items, for smoke tests")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--bucket", help="R2 bucket (upload)")
    parser.add_argument(
        "--prefix", default="slope/v1", help="R2 key prefix (upload)"
    )
    parser.add_argument(
        "--min-overlap",
        type=int,
        default=500,
        help="verify: ignore tiles with fewer comparable pixels than this",
    )
    parser.add_argument(
        "--min-agreement",
        type=float,
        default=85.0,
        help="verify: exit non-zero below this percentage of exact class agreement",
    )
    parser.add_argument(
        "--sample",
        type=int,
        default=400,
        help="verify: how many candidate tiles to examine",
    )
    parser.add_argument(
        "--max-compared",
        type=int,
        default=60,
        help="verify: stop once this many tiles have contributed pixels",
    )
    args = parser.parse_args()

    if args.stage == "fetch":
        user = os.environ.get("LANTMATERIET_USERNAME")
        password = os.environ.get("LANTMATERIET_PASSWORD")
        if not (user and password):
            sys.exit("LANTMATERIET_USERNAME and LANTMATERIET_PASSWORD must be set")
        os.environ["GDAL_HTTP_USERPWD"] = f"{user}:{password}"
        os.environ.setdefault("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
        os.environ.setdefault("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", ".tif")

        if args.collections == "all":
            collections = list_collections()
        else:
            collections = [
                c if c.startswith("mhm-") else f"mhm-{c}"
                for c in args.collections.split(",")
                if c.strip()
            ]
        stage_fetch(args, collections)
    elif args.stage == "tiles":
        stage_tiles(args)
    elif args.stage == "verify":
        stage_verify(args)
    else:
        if not args.bucket:
            sys.exit("--bucket is required for upload")
        stage_upload(args)


if __name__ == "__main__":
    main()
