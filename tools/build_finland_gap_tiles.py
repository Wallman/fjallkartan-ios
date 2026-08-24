#!/usr/bin/env python3
"""Fill the missing Finnish sliver near Treriksröset in the "lantmateriet"
R2 layer with tiles from Maanmittauslaitos (MML), Finland's national land
survey.

Background
----------
The app's base map is Lantmäteriet's Topowebb, which stops dead at Sweden's
border. Just north of the Treriksröset tripoint, Finland's Käsivarsi/
Kilpisjärvi tip pokes in between Norway and Sweden -- an area neither
existing source covers, so the map is blank there.

MML publishes an open WMTS ("avoin-karttakuva") with a `maastokartta` layer
already in the `WGS84_Pseudo-Mercator` tile matrix set -- confirmed to be
plain XYZ/EPSG:3857, 256x256 tiles, same grid origin as Lantmäteriet's own
tiles, so no reprojection is needed (unlike the Sweden slope build, which
has to warp out of SWEREF99 TM).

Nodata is not transparency here
--------------------------------
Both Lantmäteriet's and MML's tiles render "no data" as an *opaque solid
white* fill (255,255,255), not an alpha hole. A naive overlay would let one
side's white blank overwrite the other side's real content right at the
seam. So compositing treats pure white as the nodata sentinel on both
sources: keep the Swedish pixel unless it is white, in which case take the
Finnish pixel there if that one is not white either. Same idea as
`merge_existing` in build_elevation_tiles.py, just keyed on a colour
sentinel instead of an alpha channel.

Usage
-----
    export MML_API_KEY=...   # see https://omatili.maanmittauslaitos.fi/

    # 1. download MML tiles covering the gap bbox (resumable, cached)
    python3 tools/build_finland_gap_tiles.py fetch \\
        --bbox 20.412598,68.196052,23.977661,69.373541

    # 2. composite against the local Lantmäteriet tile pyramid, writing only
    #    tiles that actually gain pixels to out/finland-gap/{z}/{y}/{x}.png
    python3 tools/build_finland_gap_tiles.py composite \\
        --gpkg ~/Downloads/webbkarta_raster.gpkg

    # 3. render side-by-side previews (existing | MML | composite) for the
    #    tiles that changed, for manual eyeballing along the border --
    #    nothing is uploaded by this or the previous stage
    python3 tools/build_finland_gap_tiles.py verify

    # 4. only after manually checking the previews: publish to R2. Requires
    #    --confirm, since this overwrites live tiles.
    python3 tools/build_finland_gap_tiles.py upload \\
        --bucket tiles --prefix v1 --confirm

Requires: pillow, numpy, requests (pip install pillow numpy requests)
          boto3 only for `upload`.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import sqlite3
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import numpy as np
import requests
from PIL import Image

TILE_SIZE = 256
WMTS_BASE = "https://avoin-karttakuva.maanmittauslaitos.fi/avoin/wmts/1.0.0"
DEFAULT_LAYER = "maastokartta"
DEFAULT_MATRIX_SET = "WGS84_Pseudo-Mercator"
WHITE = (255, 255, 255)

RETRYABLE_ERROR_CODES = {"ServiceUnavailable", "SlowDown", "InternalError"}
MAX_TILE_RETRIES = 6
BASE_BACKOFF_SECONDS = 0.5


# --------------------------------------------------------------------------
# Tile math
# --------------------------------------------------------------------------

def lonlat_to_tile(lon: float, lat: float, z: int) -> tuple[int, int]:
    n = 2**z
    x = int((lon + 180.0) / 360.0 * n)
    lat = max(min(lat, 85.05112878), -85.05112878)
    rad = math.radians(lat)
    y = int((1.0 - math.log(math.tan(rad) + 1.0 / math.cos(rad)) / math.pi) / 2.0 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))


def tile_range(bbox: tuple[float, float, float, float], z: int) -> tuple[int, int, int, int]:
    """(x_min, x_max, y_min, y_max) inclusive, for a lon/lat bbox at zoom z."""
    min_lon, min_lat, max_lon, max_lat = bbox
    x0, y0 = lonlat_to_tile(min_lon, max_lat, z)  # top-left
    x1, y1 = lonlat_to_tile(max_lon, min_lat, z)  # bottom-right
    return min(x0, x1), max(x0, x1), min(y0, y1), max(y0, y1)


def parse_bbox(spec: str) -> tuple[float, float, float, float]:
    parts = [float(p) for p in spec.split(",")]
    if len(parts) != 4:
        raise ValueError(f"invalid bbox {spec!r}, expected 'min_lon,min_lat,max_lon,max_lat'")
    return parts[0], parts[1], parts[2], parts[3]


# --------------------------------------------------------------------------
# Stage 1 -- fetch
# --------------------------------------------------------------------------

def mml_tile_url(layer: str, matrix_set: str, z: int, x: int, y: int) -> str:
    return f"{WMTS_BASE}/{layer}/default/{matrix_set}/{z}/{y}/{x}.png"


def cache_path(cache_dir: Path, z: int, x: int, y: int) -> Path:
    return cache_dir / str(z) / str(x) / f"{y}.png"


def fetch_one(session: requests.Session, api_key: str, layer: str, matrix_set: str,
              z: int, x: int, y: int, path: Path, overwrite: bool) -> str:
    if path.exists() and not overwrite:
        return "cached"
    url = mml_tile_url(layer, matrix_set, z, x, y)
    for attempt in range(1, MAX_TILE_RETRIES + 1):
        try:
            response = session.get(url, auth=(api_key, ""), timeout=20)
        except requests.RequestException:
            if attempt == MAX_TILE_RETRIES:
                return "error"
            time.sleep(BASE_BACKOFF_SECONDS * (2 ** (attempt - 1)))
            continue
        if response.status_code == 200:
            path.parent.mkdir(parents=True, exist_ok=True)
            temp = path.with_suffix(".png.tmp")
            temp.write_bytes(response.content)
            temp.replace(path)
            return "fetched"
        if response.status_code == 404:
            return "missing"  # outside MML's coverage/matrix bounds
        if response.status_code in (429, 500, 502, 503, 504) and attempt < MAX_TILE_RETRIES:
            time.sleep(BASE_BACKOFF_SECONDS * (2 ** (attempt - 1)) + random.uniform(0, 0.5))
            continue
        return f"http{response.status_code}"
    return "error"


def stage_fetch(args: argparse.Namespace) -> None:
    api_key = os.environ.get("MML_API_KEY")
    if not api_key:
        sys.exit("MML_API_KEY must be set (https://omatili.maanmittauslaitos.fi/)")

    bbox = parse_bbox(args.bbox)
    cache_dir = Path(args.cache_dir).expanduser()
    jobs = []
    for z in range(args.min_zoom, args.max_zoom + 1):
        x0, x1, y0, y1 = tile_range(bbox, z)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                jobs.append((z, x, y))
    if args.limit:
        jobs = jobs[: args.limit]
    print(f"Fetching {len(jobs)} tile(s) from MML zoom {args.min_zoom}-{args.max_zoom}")

    counts: dict[str, int] = {}
    with requests.Session() as session, ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {
            pool.submit(
                fetch_one, session, api_key, args.layer, args.matrix_set,
                z, x, y, cache_path(cache_dir, z, x, y), args.overwrite,
            ): (z, x, y)
            for z, x, y in jobs
        }
        done = 0
        for future in as_completed(futures):
            result = future.result()
            counts[result] = counts.get(result, 0) + 1
            done += 1
            if done % 200 == 0 or done == len(jobs):
                print(f"  {done}/{len(jobs)} ({counts})")
    print(f"Done: {counts}")


# --------------------------------------------------------------------------
# Stage 2 -- composite
# --------------------------------------------------------------------------

def load_se_tile(conn: sqlite3.Connection, table: str, z: int, x: int, y: int) -> bytes | None:
    cur = conn.execute(
        f'SELECT tile_data FROM "{table}" WHERE zoom_level=? AND tile_column=? AND tile_row=?',
        (z, x, y),
    )
    row = cur.fetchone()
    return row[0] if row else None


def _bytes_io(data: bytes):
    import io
    return io.BytesIO(data)


def decode_rgb(data: bytes) -> np.ndarray:
    return np.array(Image.open(_bytes_io(data)).convert("RGB"))


def composite_tile(se_bytes: bytes | None, mml_bytes: bytes) -> tuple[np.ndarray | None, int]:
    """Return (composited RGB array, pixels filled) or (None, 0) if nothing changed."""
    mml = decode_rgb(mml_bytes)
    mml_white = np.all(mml == WHITE, axis=-1)
    if mml_white.all():
        return None, 0  # MML has nothing here either

    if se_bytes is not None:
        base = decode_rgb(se_bytes)
        if base.shape != mml.shape:
            return None, 0
    else:
        base = np.full((TILE_SIZE, TILE_SIZE, 3), 255, dtype=np.uint8)

    base_white = np.all(base == WHITE, axis=-1)
    fillable = base_white & ~mml_white
    if not fillable.any():
        return None, 0

    out = base.copy()
    out[fillable] = mml[fillable]
    return out, int(fillable.sum())


def stage_composite(args: argparse.Namespace) -> None:
    gpkg_path = Path(args.gpkg).expanduser()
    if not gpkg_path.is_file():
        sys.exit(f"gpkg not found: {gpkg_path}")

    cache_dir = Path(args.cache_dir).expanduser()
    out_dir = Path(args.out).expanduser()
    conn = sqlite3.connect(f"file:{gpkg_path}?mode=ro", uri=True)

    tile_files = sorted(cache_dir.glob("*/*/*.png")) if cache_dir.exists() else []
    total = len(tile_files)
    print(f"Compositing {total} cached MML tile(s) against {gpkg_path.name}")

    manifest: list[dict] = []
    scanned = 0
    written = 0
    start = time.monotonic()
    for tile_file in tile_files:
        y = int(tile_file.stem)
        x = int(tile_file.parent.name)
        z = int(tile_file.parent.parent.name)
        scanned += 1
        mml_bytes = tile_file.read_bytes()
        se_bytes = load_se_tile(conn, args.table, z, x, y)
        composited, filled = composite_tile(se_bytes, mml_bytes)
        if composited is not None:
            dest = out_dir / str(z) / str(y) / f"{x}.png"
            dest.parent.mkdir(parents=True, exist_ok=True)
            Image.fromarray(composited).save(dest, optimize=True)
            manifest.append({"z": z, "x": x, "y": y, "filled_pixels": filled,
                              "had_existing_tile": se_bytes is not None})
            written += 1
        if scanned % 2000 == 0 or scanned == total:
            elapsed = time.monotonic() - start
            rate = scanned / elapsed if elapsed > 0 else 0
            remaining = (total - scanned) / rate if rate > 0 else 0
            print(f"  scanned {scanned}/{total}, composited {written} "
                  f"({rate:.0f}/s, ~{remaining/60:.1f} min remaining)")
    conn.close()

    manifest_path = out_dir / "manifest.json"
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print(f"Scanned {scanned} cached MML tile(s), composited {written} that gain pixels")
    print(f"Manifest: {manifest_path}")


# --------------------------------------------------------------------------
# Stage 3 -- verify (manual eyeballing, no upload)
# --------------------------------------------------------------------------

def stage_verify(args: argparse.Namespace) -> None:
    out_dir = Path(args.out).expanduser()
    manifest_path = out_dir / "manifest.json"
    if not manifest_path.is_file():
        sys.exit(f"no manifest at {manifest_path}; run `composite` first")
    manifest = json.loads(manifest_path.read_text())
    if not manifest:
        print("Manifest is empty -- nothing to verify (no gap found in the fetched area).")
        return

    manifest.sort(key=lambda t: -t["filled_pixels"])
    sample = manifest[: args.sample]

    cache_dir = Path(args.cache_dir).expanduser()
    gpkg_path = Path(args.gpkg).expanduser()
    conn = sqlite3.connect(f"file:{gpkg_path}?mode=ro", uri=True) if gpkg_path.is_file() else None

    preview_dir = Path(args.preview_out).expanduser()
    preview_dir.mkdir(parents=True, exist_ok=True)

    print(f"{'z':>3} {'x':>6} {'y':>6} {'filled_px':>10}  preview")
    for entry in sample:
        z, x, y = entry["z"], entry["x"], entry["y"]
        mml_path = cache_path(cache_dir, z, x, y)
        composited_path = out_dir / str(z) / str(y) / f"{x}.png"
        panels = []
        if conn is not None:
            se_bytes = load_se_tile(conn, args.table, z, x, y)
            se_img = Image.open(_bytes_io(se_bytes)).convert("RGB") if se_bytes else \
                Image.new("RGB", (TILE_SIZE, TILE_SIZE), WHITE)
        else:
            se_img = Image.new("RGB", (TILE_SIZE, TILE_SIZE), WHITE)
        panels.append(se_img)
        panels.append(Image.open(mml_path).convert("RGB"))
        panels.append(Image.open(composited_path).convert("RGB"))

        strip = Image.new("RGB", (TILE_SIZE * 3 + 8, TILE_SIZE), (30, 30, 30))
        for i, panel in enumerate(panels):
            strip.paste(panel, (i * (TILE_SIZE + 4), 0))
        preview_path = preview_dir / f"{z}_{x}_{y}.png"
        strip.save(preview_path)
        print(f"{z:>3} {x:>6} {y:>6} {entry['filled_pixels']:>10}  {preview_path}")

    if conn is not None:
        conn.close()
    print()
    print(f"Wrote {len(sample)} preview(s) (existing | MML | composite, left-to-right) to {preview_dir}")
    print("Nothing has been uploaded. Inspect the previews along the border before running `upload`.")


# --------------------------------------------------------------------------
# Stage 4 -- upload (guarded)
# --------------------------------------------------------------------------

def make_r2_client(account_id: str, access_key: str, secret_key: str, max_pool_connections: int):
    import boto3
    from botocore.config import Config

    return boto3.client(
        "s3",
        endpoint_url=f"https://{account_id}.r2.cloudflarestorage.com",
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        config=Config(
            signature_version="s3v4",
            retries={"max_attempts": 5, "mode": "adaptive"},
            max_pool_connections=max_pool_connections,
        ),
        region_name="auto",
    )


def upload_one(client, bucket: str, prefix: str, z: int, x: int, y: int, data: bytes) -> str:
    from botocore.exceptions import ClientError

    key = f"{prefix}{z}/{y}/{x}.png"
    for attempt in range(1, MAX_TILE_RETRIES + 1):
        try:
            client.put_object(
                Bucket=bucket, Key=key, Body=data, ContentType="image/png",
                CacheControl="public, max-age=15768000",
            )
            return key
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code not in RETRYABLE_ERROR_CODES or attempt == MAX_TILE_RETRIES:
                raise
            time.sleep(BASE_BACKOFF_SECONDS * (2 ** (attempt - 1)) + random.uniform(0, 0.5))
    raise RuntimeError(f"unreachable: exhausted retries for {key}")  # pragma: no cover


def stage_upload(args: argparse.Namespace) -> None:
    if not args.confirm:
        sys.exit(
            "refusing to upload without --confirm: this overwrites live tiles in "
            f"R2 bucket {args.bucket!r}. Run `verify` and manually check the border "
            "previews first."
        )
    out_dir = Path(args.out).expanduser()
    manifest_path = out_dir / "manifest.json"
    if not manifest_path.is_file():
        sys.exit(f"no manifest at {manifest_path}; run `composite` (and `verify`) first")
    manifest = json.loads(manifest_path.read_text())

    account_id = os.environ.get("R2_ACCOUNT_ID")
    access_key = os.environ.get("R2_ACCESS_KEY_ID")
    secret_key = os.environ.get("R2_SECRET_ACCESS_KEY")
    if not (account_id and access_key and secret_key):
        sys.exit("R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY must be set")

    client = make_r2_client(account_id, access_key, secret_key, args.jobs)
    prefix = args.prefix if args.prefix.endswith("/") else args.prefix + "/"

    print(f"Uploading {len(manifest)} tile(s) to r2://{args.bucket}/{prefix}")
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {}
        for entry in manifest:
            z, x, y = entry["z"], entry["x"], entry["y"]
            data = (out_dir / str(z) / str(y) / f"{x}.png").read_bytes()
            futures[pool.submit(upload_one, client, args.bucket, prefix, z, x, y, data)] = (z, x, y)
        done = 0
        for future in as_completed(futures):
            future.result()
            done += 1
            if done % 100 == 0 or done == len(futures):
                print(f"  {done}/{len(futures)}")
    print("Upload complete.")


# --------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fill the Finnish gap near Treriksröset using MML tiles.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("stage", choices=("fetch", "composite", "verify", "upload"))
    parser.add_argument(
        "--bbox", default="20.412598,68.196052,23.977661,69.373541",
        help="min_lon,min_lat,max_lon,max_lat (fetch)",
    )
    parser.add_argument("--layer", default=DEFAULT_LAYER, help="MML WMTS layer (fetch)")
    parser.add_argument("--matrix-set", default=DEFAULT_MATRIX_SET, help="MML WMTS tile matrix set (fetch)")
    parser.add_argument("--cache-dir", default="~/.cache/fjallkartan-mml")
    parser.add_argument("--out", default="out/finland-gap")
    parser.add_argument("--preview-out", default="out/finland-gap-preview")
    parser.add_argument("--gpkg", default="~/Downloads/webbkarta_raster.gpkg",
                         help="local Lantmäteriet tile pyramid (composite, verify)")
    parser.add_argument("--table", default="topowebb", help="tile table inside the gpkg")
    parser.add_argument("--min-zoom", type=int, default=7)
    parser.add_argument("--max-zoom", type=int, default=16)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--limit", type=int, default=0, help="cap tiles fetched, for smoke tests")
    parser.add_argument("--overwrite", action="store_true", help="fetch: re-download cached tiles")
    parser.add_argument("--sample", type=int, default=30, help="verify: how many tiles to preview")
    parser.add_argument("--bucket", default="tiles", help="R2 bucket (upload)")
    parser.add_argument("--prefix", default="v1", help="R2 key prefix (upload)")
    parser.add_argument("--confirm", action="store_true",
                         help="required for upload: acknowledges this overwrites live tiles")
    args = parser.parse_args()

    if args.stage == "fetch":
        stage_fetch(args)
    elif args.stage == "composite":
        stage_composite(args)
    elif args.stage == "verify":
        stage_verify(args)
    else:
        stage_upload(args)


if __name__ == "__main__":
    main()
