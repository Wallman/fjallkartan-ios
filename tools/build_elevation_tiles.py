#!/usr/bin/env python3
"""Build elevation raster tiles for route elevation profiles.

The app measures distance along a freehand route; to also report ascent and
descent it needs a terrain height for any coordinate in Scandinavia. Rather
than calling an elevation web service at runtime, we prebake the heights into
ordinary XYZ tiles and serve them from the same R2 bucket as the slope layer.
That keeps elevation working offline (the tiles ride along in an offline
region), removes per-request latency and rate limits, and means the app has a
single code path for both countries.

Source (Norway)
---------------
Kartverket's national height model, published as an open ArcGIS ImageServer:

    https://hoydedata.no/arcgis/rest/services/NHM_DTM_25833/ImageServer

1 m ground resolution, EPSG:25833, `serviceDataType` esriImageServiceDataType-
Elevation. No authentication, no key: the WCS twin of the same data declares
`Fees: free` and `AccessConstraints: None`. This is the very dataset behind
ws.geonorge.no/hoydedata/v1/punkt -- an `identify` call at (8.5, 61.5) returns
1489.86, byte for byte what the point API returns -- so the tiles and the
public API cannot disagree.

Both countries' elevation data is CC BY 4.0 open data, which permits
redistributing these derived tiles as long as the source is credited.

Source (Sweden)
---------------
Lantmäteriet publishes no equivalent height service, so Sweden is built from
the same local DEM cache `build_sweden_slope_tiles.py` already downloads for
the slope layer (`fetch` stage, ~9 GB, Markhöjdmodell 8 m overviews pasted
onto a canonical 10 m SWEREF99 TM grid). We import that script's `Mosaic`
rather than re-implementing it, so the two layers cannot drift onto different
grids.

Unlike slope, the warp to WebMercator is **bilinear**: heights are quantities
that interpolate meaningfully, where slope classes are labels that must not be
blended. And unlike slope, nothing has to be computed before the warp --
Mercator distorts distance, which corrupts a gradient, but a height is the
same number in any projection.

Why export straight to WebMercator
----------------------------------
`build_sweden_slope_tiles.py` is careful to compute slope in a metric CRS
*before* warping, because Mercator inflates distances by 1/cos(latitude) and
would flatten every slope. Elevation has no such problem: a height is a height
regardless of the projection it is drawn in. So we let the ImageServer do the
reprojection and hand us pixels already on the WebMercator tile grid, which
removes the local mosaic/warp machinery entirely.

Why 2048 px blocks
------------------
The service advertises maxImageWidth/Height of 4096, but a reprojected 4096
export reliably 502s after 60 s. 2048 returns in under two seconds, so we
fetch one block per `zoom - 3` tile and slice it into 8x8 output tiles. For
the whole of Norway that is on the order of a thousand requests rather than
one per tile.

Encoding
--------
RGBA8 PNG, one metre precision:

    value = round(metres) + 32768
    R = value >> 8,  G = value & 0xFF,  B = 0,  A = 255
    no data -> (0, 0, 0, 0)

Metre precision is deliberate. Decimetres would put white noise in the low
byte and roughly triple the PNG size, and the client already has to apply a
several-metre hysteresis when accumulating ascent so that DTM noise is not
counted as climbing. Keeping B and A constant costs nothing after PNG
filtering, and RGBA8 is the one pixel format iOS decodes without ceremony.

Note that sea is a legitimate 0 m, not no-data; only genuinely uncovered
ground comes back as no-data. Kartverket's point API disagrees here on
purpose -- it answers with sea *depth* over water -- so `verify` only compares
against the terrain sources listed in TERRAIN_DATAKILDER.

Usage
-----
    # 1. render tiles into out/elevation/{z}/{y}/{x}.png (resumable)
    python3 tools/build_elevation_tiles.py tiles --country no
    python3 tools/build_elevation_tiles.py tiles --country se   # needs the slope cache

    # 2. check the tiles against each country's official point service
    python3 tools/build_elevation_tiles.py verify --country no
    python3 tools/build_elevation_tiles.py verify --country se  # needs LANTMATERIET_*

    # 3. publish to R2 (needs R2_* env vars, see upload_gpkg_tiles_to_r2.py)
    python3 tools/build_elevation_tiles.py upload --bucket tiles --prefix elevation/v1

Requires: numpy, pillow, pyproj  (pip install numpy pillow pyproj)
          rasterio for --country se, boto3 only for `upload`.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import math
import os
import random
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

WEBMERCATOR_SPAN = 20037508.342789244
TILE_SIZE = 256

# One fetch covers BLOCK_TILES x BLOCK_TILES output tiles.
BLOCK_TILES = 8
BLOCK_PIXELS = BLOCK_TILES * TILE_SIZE  # 2048

NODATA = -9999.0
ELEVATION_OFFSET = 32768

USER_AGENT = "fjallkartan-elevation-tiles/1.0 (+https://github.com/Wallman/fjallkartan-ios)"

GEONORGE_PUNKT = "https://ws.geonorge.no/hoydedata/v1/punkt"
GEONORGE_MAX_POINTS = 50

# `/punkt` answers with "the best available height *or depth*", so over water it
# reports bathymetry from `dybdekurver` -- a fjord comes back as -450 m where the
# terrain model correctly says 0 m at the sea surface. Comparing the two measures
# nothing, so verification only trusts the sources that describe ground.
TERRAIN_DATAKILDER = {"dtm1", "dom1", "hoydekurver", "innsjohoyde"}

# Lantmäteriet "Markhöjd Direkt". Basic auth with the same Geotorget credentials
# the slope build uses for dl1, a GeoJSON geometry as the body, and SWEREF99 TM
# only -- EPSG:4326 is rejected outright. Takes up to 1000 points at a time,
# which makes it a far cheaper oracle than Geonorge's 50.
MARKHOJD_URL = "https://api.lantmateriet.se/distribution/produkter/markhojd/v1/hojd"
MARKHOJD_MAX_POINTS = 1000
SWEREF99_TM = "urn:ogc:def:crs:EPSG::3006"


# --------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Source:
    """One country's elevation data.

    Either `image_server` (fetched on demand) or `cache_dir` (a local mosaic
    built by build_sweden_slope_tiles.py) is set, never both.
    """

    key: str
    name: str
    attribution: str
    image_server: str | None = None
    native_epsg: int | None = None
    cache_dir: str | None = None

    @property
    def is_mosaic(self) -> bool:
        return self.cache_dir is not None


SOURCES = {
    "no": Source(
        key="no",
        name="Kartverket NHM DTM",
        image_server="https://hoydedata.no/arcgis/rest/services/NHM_DTM_25833/ImageServer",
        native_epsg=25833,
        attribution="© Kartverket (CC BY 4.0)",
    ),
    "se": Source(
        key="se",
        name="Lantmäteriet Markhöjdmodell",
        cache_dir="~/.cache/fjallkartan-hojd",
        native_epsg=3006,
        attribution="© Lantmäteriet (CC BY 4.0)",
    ),
}


# --------------------------------------------------------------------------
# Tile arithmetic
# --------------------------------------------------------------------------

def tile_bounds(z: int, x: int, y: int) -> tuple[float, float, float, float]:
    """(left, bottom, right, top) of an XYZ tile in EPSG:3857 metres."""
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


def mercator_to_lonlat(x: float, y: float) -> tuple[float, float]:
    lon = x / WEBMERCATOR_SPAN * 180.0
    lat = math.degrees(2.0 * math.atan(math.exp(y / WEBMERCATOR_SPAN * math.pi)) - math.pi / 2.0)
    return lon, lat


def pixel_center(bounds: tuple[float, float, float, float],
                 size: int,
                 row: int,
                 col: int) -> tuple[float, float]:
    """Lon/lat of the centre of one pixel of a raster covering `bounds`."""
    left, _, right, top = bounds
    span = right - left
    x = left + (col + 0.5) * span / size
    y = top - (row + 0.5) * span / size
    return mercator_to_lonlat(x, y)


# --------------------------------------------------------------------------
# Coverage
# --------------------------------------------------------------------------

def service_extent_3857(source: Source) -> tuple[float, float, float, float]:
    """The service's own advertised extent, densified and reprojected to 3857.

    The extent is a rectangle in the native UTM CRS, and its WebMercator
    envelope is not the transform of its four corners -- the edges bow. So we
    walk the perimeter rather than trusting the corners.
    """
    from pyproj import Transformer

    meta = http_json(f"{source.image_server}?f=json")
    extent = meta["extent"]
    xmin, ymin = float(extent["xmin"]), float(extent["ymin"])
    xmax, ymax = float(extent["xmax"]), float(extent["ymax"])

    transformer = Transformer.from_crs(
        f"EPSG:{source.native_epsg}", "EPSG:3857", always_xy=True
    )
    steps = 64
    xs = [xmin + (xmax - xmin) * i / steps for i in range(steps + 1)]
    ys = [ymin + (ymax - ymin) * i / steps for i in range(steps + 1)]
    perimeter_x: list[float] = []
    perimeter_y: list[float] = []
    for x in xs:
        perimeter_x.extend([x, x])
        perimeter_y.extend([ymin, ymax])
    for y in ys:
        perimeter_x.extend([xmin, xmax])
        perimeter_y.extend([y, y])

    px, py = transformer.transform(perimeter_x, perimeter_y)
    finite = [(a, b) for a, b in zip(px, py) if math.isfinite(a) and math.isfinite(b)]
    if not finite:
        sys.exit(f"could not project the extent of {source.name}")
    return (
        min(a for a, _ in finite),
        min(b for _, b in finite),
        max(a for a, _ in finite),
        max(b for _, b in finite),
    )


def blocks_for_extent(extent: tuple[float, float, float, float],
                      block_zoom: int) -> list[tuple[int, int]]:
    left, bottom, right, top = extent
    span = 2 * WEBMERCATOR_SPAN / (2**block_zoom)
    n = 2**block_zoom

    def clamp(v: int) -> int:
        return max(0, min(n - 1, v))

    x0 = clamp(int((left + WEBMERCATOR_SPAN) // span))
    x1 = clamp(int((right + WEBMERCATOR_SPAN) // span))
    y0 = clamp(int((WEBMERCATOR_SPAN - top) // span))
    y1 = clamp(int((WEBMERCATOR_SPAN - bottom) // span))
    return [(x, y) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)]


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

def http_bytes(url: str, attempts: int = 5, timeout: int = 180) -> bytes:
    delay = 1.0
    last: Exception | None = None
    for attempt in range(attempts):
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except Exception as error:  # noqa: BLE001 - retry everything transient
            last = error
            if attempt == attempts - 1:
                break
            time.sleep(delay + random.random())
            delay = min(delay * 2, 30.0)
    raise RuntimeError(f"GET {url.split('?')[0]} failed: {last}")


def http_json(url: str) -> dict:
    return json.loads(http_bytes(url).decode("utf-8"))


def export_block(source: Source,
                 bounds: tuple[float, float, float, float],
                 size: int) -> np.ndarray | None:
    """Fetch one block as float32 metres, or None where the service has nothing.

    Uncovered areas come back as a ~1 KB stub TIFF rather than a full raster of
    no-data, so anything shorter than the raw pixel payload means "no coverage
    here" and must not be decoded -- a truncated decode would yield zeros,
    which are indistinguishable from a legitimate sea-level reading.
    """
    query = urllib.parse.urlencode({
        "bbox": ",".join(f"{v:.6f}" for v in bounds),
        "bboxSR": 3857,
        "imageSR": 3857,
        "size": f"{size},{size}",
        "format": "tiff",
        "pixelType": "F32",
        "noData": NODATA,
        "noDataInterpretation": "esriNoDataMatchAny",
        "interpolation": "RSP_BilinearInterpolation",
        "f": "image",
    })
    raw = http_bytes(f"{source.image_server}/exportImage?{query}")
    if len(raw) < size * size * 4:
        return None
    array = np.array(Image.open(io.BytesIO(raw)), dtype=np.float32)
    if array.shape != (size, size):
        return None
    return array


# --------------------------------------------------------------------------
# Encoding
# --------------------------------------------------------------------------

def encode_tile(heights: np.ndarray) -> bytes | None:
    """RGBA8 PNG for one tile, or None if the tile has no data at all."""
    valid = np.isfinite(heights) & (heights > NODATA + 1.0)
    if not valid.any():
        return None

    values = np.rint(np.where(valid, heights, 0.0)).astype(np.int32) + ELEVATION_OFFSET
    values = np.clip(values, 0, 65535)

    rgba = np.zeros(heights.shape + (4,), dtype=np.uint8)
    rgba[..., 0] = (values >> 8).astype(np.uint8)
    rgba[..., 1] = (values & 0xFF).astype(np.uint8)
    rgba[..., 3] = np.where(valid, 255, 0).astype(np.uint8)
    rgba[~valid] = 0

    buffer = io.BytesIO()
    Image.fromarray(rgba).save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def decode_tile(png: bytes) -> np.ndarray:
    """Inverse of `encode_tile`; no-data pixels come back as NaN."""
    rgba = np.array(Image.open(io.BytesIO(png)).convert("RGBA"))
    values = (rgba[..., 0].astype(np.int32) << 8) | rgba[..., 1].astype(np.int32)
    heights = (values - ELEVATION_OFFSET).astype(np.float32)
    heights[rgba[..., 3] == 0] = np.nan
    return heights


def tile_path(out_dir: Path, z: int, x: int, y: int) -> Path:
    return out_dir / str(z) / str(y) / f"{x}.png"


def marker_path(out_dir: Path, country: str, block_zoom: int, x: int, y: int) -> Path:
    """Resume marker for one rendered block.

    Namespaced by country: the two services overlap along the border, so a
    shared key would let Norway's markers convince the Swedish run that
    hundreds of blocks were already done.
    """
    return out_dir / ".blocks" / country / str(block_zoom) / f"{x}_{y}"


# --------------------------------------------------------------------------
# Sweden -- the local DEM mosaic shared with the slope build
# --------------------------------------------------------------------------

def load_slope_module():
    """Import build_sweden_slope_tiles from this script's own directory.

    The canonical grid (origin, resolution, CRS) and the Mosaic reader live
    there. Importing rather than copying keeps the elevation tiles on exactly
    the grid the slope tiles were cut from.
    """
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import build_sweden_slope_tiles as slope  # noqa: PLC0415

    return slope


def open_mosaic(source: Source):
    slope = load_slope_module()
    cache_dir = Path(source.cache_dir).expanduser()
    if not (cache_dir / "dem").is_dir():
        sys.exit(
            f"no DEM cache at {cache_dir / 'dem'} -- run\n"
            f"    python3 tools/build_sweden_slope_tiles.py fetch\n"
            f"first (about 9 GB, resumable)"
        )
    mosaic = slope.Mosaic(cache_dir)
    if not mosaic.extents:
        sys.exit(f"DEM cache at {cache_dir} is empty")
    return mosaic


def mosaic_block(mosaic, bounds: tuple[float, float, float, float]) -> np.ndarray | None:
    """One block of heights, warped from the native grid to WebMercator."""
    from rasterio.transform import from_origin
    from rasterio.warp import Resampling, reproject, transform_bounds

    slope = load_slope_module()
    left, bottom, right, top = bounds
    try:
        # The projection is not affine, so the corners alone under-cover the
        # footprint at these latitudes; densify along the edges as well.
        src_left, src_bottom, src_right, src_top = transform_bounds(
            "EPSG:3857", slope.GRID_CRS, left, bottom, right, top, densify_pts=21
        )
    except Exception:  # noqa: BLE001 - blocks outside the projection's domain
        return None

    margin = 3 * slope.GRID_RES
    col, row, width, height = slope.grid_window(
        src_left - margin, src_bottom - margin, src_right + margin, src_top + margin
    )
    if width <= 3 or height <= 3:
        return None
    if slope.disjoint_from_mosaic(mosaic, col, row, width, height):
        return None

    dem = mosaic.read(col, row, width, height)
    if not np.any(dem != slope.NODATA):
        return None

    destination = np.full((BLOCK_PIXELS, BLOCK_PIXELS), np.nan, dtype="float32")
    reproject(
        source=dem,
        destination=destination,
        src_transform=slope.grid_transform(col, row),
        src_crs=slope.GRID_CRS,
        src_nodata=slope.NODATA,
        dst_transform=from_origin(
            left, top, (right - left) / BLOCK_PIXELS, (top - bottom) / BLOCK_PIXELS
        ),
        dst_crs="EPSG:3857",
        dst_nodata=np.nan,
        # Heights are quantities, so unlike the slope layer's class labels they
        # interpolate meaningfully.
        resampling=Resampling.bilinear,
    )
    return destination if np.isfinite(destination).any() else None


def blocks_from_mosaic(mosaic, block_zoom: int) -> list[tuple[int, int]]:
    """Every block at `block_zoom` that overlaps cached data."""
    from rasterio.warp import transform_bounds

    slope = load_slope_module()
    blocks: set[tuple[int, int]] = set()
    for col, row, width, height, _ in mosaic.extents:
        left = slope.GRID_ORIGIN_X + col * slope.GRID_RES
        top = slope.GRID_ORIGIN_Y - row * slope.GRID_RES
        right = left + width * slope.GRID_RES
        bottom = top - height * slope.GRID_RES
        west, south, east, north = transform_bounds(
            slope.GRID_CRS, "EPSG:4326", left, bottom, right, top, densify_pts=21
        )
        x0, y0 = lonlat_to_tile(west, north, block_zoom)
        x1, y1 = lonlat_to_tile(east, south, block_zoom)
        for x in range(min(x0, x1), max(x0, x1) + 1):
            for y in range(min(y0, y1), max(y0, y1) + 1):
                blocks.add((x, y))
    return sorted(blocks)


# --------------------------------------------------------------------------
# Stage 1 -- render
# --------------------------------------------------------------------------

def merge_existing(path: Path, heights: np.ndarray) -> np.ndarray:
    """Fill this tile's no-data pixels from a tile already on disk.

    Both countries are rendered into one layer, and a tile on the border is
    covered by neither service alone. Without merging, whichever country ran
    second would blank out the other side of the line.
    """
    if not path.exists():
        return heights
    try:
        previous = decode_tile(path.read_bytes())
    except Exception:
        return heights
    if previous.shape != heights.shape:
        return heights
    missing = ~(np.isfinite(heights) & (heights > NODATA + 1.0))
    if not missing.any():
        return heights
    merged = heights.astype(np.float32, copy=True)
    merged[missing] = previous[missing]
    return merged


def render_block(source: Source,
                 out_dir: Path,
                 zoom: int,
                 block_zoom: int,
                 bx: int,
                 by: int,
                 mosaic=None) -> int:
    bounds = tile_bounds(block_zoom, bx, by)
    if source.is_mosaic:
        heights = mosaic_block(mosaic, bounds)
    else:
        heights = export_block(source, bounds, BLOCK_PIXELS)
    if heights is None:
        return 0

    written = 0
    scale = 2 ** (zoom - block_zoom)
    for row in range(BLOCK_TILES):
        for col in range(BLOCK_TILES):
            window = heights[row * TILE_SIZE:(row + 1) * TILE_SIZE,
                             col * TILE_SIZE:(col + 1) * TILE_SIZE]
            path = tile_path(out_dir, zoom, bx * scale + col, by * scale + row)
            window = merge_existing(path, window)
            png = encode_tile(window)
            if png is None:
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_suffix(".png.tmp")
            temporary.write_bytes(png)
            temporary.replace(path)
            written += 1
    return written


def stage_tiles(args) -> None:
    source = SOURCES[args.country]
    out_dir = Path(args.out).expanduser()
    zoom = args.zoom
    block_zoom = zoom - int(math.log2(BLOCK_TILES))
    if block_zoom < 0:
        sys.exit(f"--zoom must be at least {int(math.log2(BLOCK_TILES))}")

    mosaic = open_mosaic(source) if source.is_mosaic else None

    if args.bbox:
        west, south, east, north = (float(v) for v in args.bbox.split(","))
        x0, y1 = lonlat_to_tile(west, south, block_zoom)
        x1, y0 = lonlat_to_tile(east, north, block_zoom)
        blocks = [(x, y) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)]
        print(f"{source.name}: {len(blocks):,} blocks in --bbox", flush=True)
    elif source.is_mosaic:
        blocks = blocks_from_mosaic(mosaic, block_zoom)
        print(f"{source.name}: {len(blocks):,} blocks at z{block_zoom} "
              f"covering {len(mosaic.extents):,} cached rasters", flush=True)
    else:
        extent = service_extent_3857(source)
        blocks = blocks_for_extent(extent, block_zoom)
        print(f"{source.name}: {len(blocks):,} blocks at z{block_zoom} "
              f"covering the service extent", flush=True)

    if not args.overwrite:
        blocks = [b for b in blocks
                  if not marker_path(out_dir, args.country, block_zoom, *b).exists()]
    if args.limit:
        blocks = blocks[:args.limit]
    if not blocks:
        print("nothing to do")
        return

    print(f"rendering {len(blocks):,} blocks -> z{zoom} tiles in {out_dir}", flush=True)
    lock = threading.Lock()
    done = 0
    tiles = 0
    empty = 0

    def run(block: tuple[int, int]) -> None:
        nonlocal done, tiles, empty
        written = render_block(source, out_dir, zoom, block_zoom, *block, mosaic=mosaic)
        marker = marker_path(out_dir, args.country, block_zoom, *block)
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(str(written))
        with lock:
            done += 1
            tiles += written
            if written == 0:
                empty += 1
            if done % 25 == 0 or done == len(blocks):
                print(f"  {done:,}/{len(blocks):,} blocks, {tiles:,} tiles "
                      f"({empty:,} blocks empty)", flush=True)

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for future in as_completed([pool.submit(run, b) for b in blocks]):
            future.result()

    print(f"wrote {tiles:,} tiles from {len(blocks):,} blocks")


# --------------------------------------------------------------------------
# Stage 2 -- verify against the public point API
# --------------------------------------------------------------------------

def geonorge_heights(points: list[tuple[float, float]]) -> list[tuple[float | None, str]]:
    """(height, datakilde) from ws.geonorge.no for up to 50 lon/lat pairs."""
    if len(points) > GEONORGE_MAX_POINTS:
        raise ValueError(f"at most {GEONORGE_MAX_POINTS} points per request")
    payload = json.dumps([[round(lon, 7), round(lat, 7)] for lon, lat in points],
                         separators=(",", ":"))
    query = urllib.parse.urlencode({"koordsys": 4326, "punkter": payload})
    data = json.loads(http_bytes(f"{GEONORGE_PUNKT}?{query}", timeout=60).decode("utf-8"))
    return [(p.get("z"), str(p.get("datakilde"))) for p in data["punkter"]]


def markhojd_heights(points: list[tuple[float, float]]) -> list[float | None]:
    """Ground heights from Markhöjd Direkt for up to 1000 SWEREF99 TM points."""
    if len(points) > MARKHOJD_MAX_POINTS:
        raise ValueError(f"at most {MARKHOJD_MAX_POINTS} points per request")

    user = os.environ.get("LANTMATERIET_USERNAME")
    password = os.environ.get("LANTMATERIET_PASSWORD")
    if not (user and password):
        sys.exit("LANTMATERIET_USERNAME and LANTMATERIET_PASSWORD must be set")
    token = base64.b64encode(f"{user}:{password}".encode()).decode()

    body = json.dumps({
        "type": "MultiPoint",
        "coordinates": [[x, y] for x, y in points],
        "crs": {"type": "name", "properties": {"name": SWEREF99_TM}},
    }).encode()

    delay = 1.0
    last: Exception | None = None
    for attempt in range(5):
        request = urllib.request.Request(
            MARKHOJD_URL,
            data=body,
            method="POST",
            headers={
                "Authorization": f"Basic {token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": USER_AGENT,
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                payload = json.load(response)
            break
        except urllib.error.HTTPError as error:
            if error.code in (400, 401, 403):
                sys.exit(f"Markhöjd Direkt rejected the request: {error.code} "
                         f"{error.read()[:200].decode('utf-8', 'ignore')}")
            last = error
        except Exception as error:  # noqa: BLE001 - retry everything transient
            last = error
        if attempt == 4:
            raise RuntimeError(f"Markhöjd Direkt failed: {last}")
        time.sleep(delay + random.random())
        delay = min(delay * 2, 30.0)

    nodata = float(payload.get("properties", {}).get("nodatavalue", NODATA))
    heights: list[float | None] = []
    for coordinate in payload["geometry"]["coordinates"]:
        z = float(coordinate[2]) if len(coordinate) > 2 else nodata
        heights.append(None if abs(z - nodata) < 1e-6 else z)
    return heights


def sample_tiles(out_dir: Path, zoom: int, count: int, seed: int) -> list[Path]:
    paths = list((out_dir / str(zoom)).rglob("*.png"))
    if not paths:
        sys.exit(f"no tiles under {out_dir / str(zoom)} -- run the tiles stage first")
    rng = random.Random(seed)
    rng.shuffle(paths)
    return paths[:count]


def collect_samples(out_dir: Path, zoom: int, args) -> tuple[list[tuple[float, float]], list[float], int]:
    """Pick random valid pixels from random tiles; return their lon/lat and height."""
    paths = sample_tiles(out_dir, zoom, args.sample, args.seed)
    rng = random.Random(args.seed)
    points: list[tuple[float, float]] = []
    mine: list[float] = []
    tiles = 0
    for path in paths:
        x = int(path.stem)
        y = int(path.parent.name)
        heights = decode_tile(path.read_bytes())
        rows, cols = np.nonzero(np.isfinite(heights))
        if rows.size == 0:
            continue
        tiles += 1
        bounds = tile_bounds(zoom, x, y)
        for index in rng.sample(range(rows.size), min(args.per_tile, rows.size)):
            row, col = int(rows[index]), int(cols[index])
            points.append(pixel_center(bounds, TILE_SIZE, row, col))
            mine.append(float(heights[row, col]))
    return points, mine, tiles


def verify_norway(points, mine, args):
    """Compare against ws.geonorge.no, ignoring answers that describe water."""
    differences: list[float] = []
    by_source: dict[str, list[float]] = {}
    missing = 0
    skipped = 0
    for start in range(0, len(points), GEONORGE_MAX_POINTS):
        chunk = points[start:start + GEONORGE_MAX_POINTS]
        for (value, datakilde), ours in zip(geonorge_heights(chunk),
                                            mine[start:start + len(chunk)]):
            if value is None:
                missing += 1
            elif datakilde not in TERRAIN_DATAKILDER:
                skipped += 1
            else:
                difference = abs(float(value) - ours)
                differences.append(difference)
                by_source.setdefault(datakilde, []).append(difference)
        time.sleep(args.pause)
    return differences, by_source, missing, skipped, "answered with depth"


def verify_sweden(points, mine, args):
    """Compare against Lantmäteriet Markhöjd Direkt, which needs SWEREF99 TM."""
    from pyproj import Transformer

    transformer = Transformer.from_crs("EPSG:4326", "EPSG:3006", always_xy=True)
    xs, ys = transformer.transform([lon for lon, _ in points],
                                   [lat for _, lat in points])
    projected = list(zip(xs, ys))

    differences: list[float] = []
    missing = 0
    for start in range(0, len(projected), MARKHOJD_MAX_POINTS):
        chunk = projected[start:start + MARKHOJD_MAX_POINTS]
        for value, ours in zip(markhojd_heights(chunk),
                               mine[start:start + len(chunk)]):
            if value is None:
                missing += 1
            else:
                differences.append(abs(float(value) - ours))
        time.sleep(args.pause)
    return differences, {"markhojd": differences}, missing, 0, "no data"


def stage_verify(args) -> None:
    out_dir = Path(args.out).expanduser()
    zoom = args.zoom
    points, mine, compared_tiles = collect_samples(out_dir, zoom, args)
    if not points:
        sys.exit("no tiles with data to sample")

    oracle = verify_norway if args.country == "no" else verify_sweden
    differences, by_source, missing, skipped, skip_label = oracle(points, mine, args)

    if not differences:
        sys.exit("no comparable points -- every sample fell outside the reference service")

    array = np.array(differences)
    median = float(np.median(array))
    p90 = float(np.percentile(array, 90))
    p99 = float(np.percentile(array, 99))

    print(f"compared {array.size:,} points across {compared_tiles:,} tiles "
          f"({missing:,} outside the reference service, {skipped:,} {skip_label})")
    print(f"  median |delta| {median:6.2f} m")
    print(f"  p90    |delta| {p90:6.2f} m")
    print(f"  p99    |delta| {p99:6.2f} m")
    print(f"  max    |delta| {float(array.max()):6.2f} m")
    if len(by_source) > 1:
        for name, values in sorted(by_source.items(), key=lambda kv: -len(kv[1])):
            source_array = np.array(values)
            print(f"    {name:<12} n={source_array.size:<6,} "
                  f"median={float(np.median(source_array)):6.2f} m  "
                  f"p90={float(np.percentile(source_array, 90)):6.2f} m")

    failures = []
    if median > args.max_median:
        failures.append(f"median {median:.2f} m > {args.max_median} m")
    if p90 > args.max_p90:
        failures.append(f"p90 {p90:.2f} m > {args.max_p90} m")
    if failures:
        sys.exit("verify failed: " + "; ".join(failures))
    print("verify passed")


# --------------------------------------------------------------------------
# Stage 3 -- publish
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

    if not args.overwrite:
        existing = set()
        paginator = client.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=args.bucket, Prefix=prefix):
            for obj in page.get("Contents", ()):
                existing.add(obj["Key"])
        if existing:
            before = len(files)
            files = [f for f in files
                     if f"{prefix}{f.relative_to(out_dir).as_posix()}" not in existing]
            print(f"  {before - len(files):,} already in the bucket, "
                  f"{len(files):,} left", flush=True)
        if not files:
            print("nothing to upload")
            return

    done = 0
    lock = threading.Lock()

    def put(path: Path) -> None:
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
        description="Build elevation tiles for route ascent/descent profiles.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("stage", choices=("tiles", "verify", "upload"))
    parser.add_argument("--country", default="no", choices=sorted(SOURCES))
    parser.add_argument("--out", default="out/elevation")
    parser.add_argument(
        "--zoom",
        type=int,
        default=12,
        help="output zoom; z12 is about 18 m on the ground at 62 N, which "
             "matches the ~25 m spacing the app samples a route at",
    )
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--limit", type=int, default=0, help="cap blocks, for smoke tests")
    parser.add_argument("--bbox", help="tiles: limit to west,south,east,north in degrees")
    parser.add_argument("--overwrite", action="store_true",
                        help="tiles: re-render blocks that are already marked done")
    parser.add_argument("--bucket", help="R2 bucket (upload)")
    parser.add_argument("--prefix", default="elevation/v1", help="R2 key prefix (upload)")
    parser.add_argument("--sample", type=int, default=120,
                        help="verify: how many tiles to sample")
    parser.add_argument("--per-tile", type=int, default=10,
                        help="verify: points sampled per tile")
    parser.add_argument("--seed", type=int, default=1, help="verify: sampling seed")
    parser.add_argument("--pause", type=float, default=0.2,
                        help="verify: seconds between point API requests")
    parser.add_argument("--max-median", type=float, default=2.0,
                        help="verify: fail above this median absolute error, in metres")
    parser.add_argument("--max-p90", type=float, default=8.0,
                        help="verify: fail above this p90 absolute error, in metres")
    args = parser.parse_args()

    if args.stage == "tiles":
        stage_tiles(args)
    elif args.stage == "verify":
        stage_verify(args)
    else:
        if not args.bucket:
            sys.exit("--bucket is required for upload")
        stage_upload(args)


if __name__ == "__main__":
    main()
