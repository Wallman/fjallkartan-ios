#!/usr/bin/env python3
"""Upload z0-9 raster tiles from a GeoPackage (.gpkg) tile pyramid to a
Cloudflare R2 bucket, laid out as PNG objects under a z/y/x key scheme.

The GeoPackage's `tile_row` column is stored top-down (row 0 = northernmost
row), matching the standard XYZ/slippy-map `y` directly -- no row flip is
needed to go from GeoPackage -> XYZ.

Usage:
    export R2_ACCOUNT_ID=...
    export R2_ACCESS_KEY_ID=...
    export R2_SECRET_ACCESS_KEY=...
    python3 tools/upload_gpkg_tiles_to_r2.py \
        --gpkg ~/Downloads/webbkarta_raster.gpkg \
        --table topowebb \
        --bucket tiles \
        --max-zoom 9

Requires: boto3 (pip install boto3). Uses only the Python stdlib otherwise
(sqlite3 for reading the GeoPackage).
"""

from __future__ import annotations

import argparse
import os
import random
import sqlite3
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

RETRYABLE_ERROR_CODES = {"ServiceUnavailable", "SlowDown", "InternalError"}
MAX_TILE_RETRIES = 6
BASE_BACKOFF_SECONDS = 0.5


@dataclass(frozen=True)
class Tile:
    z: int
    x: int
    y: int
    data: bytes


def iter_tiles(gpkg_path: str, table: str, min_zoom: int, max_zoom: int):
    """Yield Tile rows with min_zoom <= zoom_level <= max_zoom from the GeoPackage."""
    # Read-only URI connection avoids accidentally locking/writing the
    # (possibly huge) source file.
    uri = f"file:{gpkg_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        cur = conn.execute(
            f"SELECT zoom_level, tile_column, tile_row, tile_data "
            f'FROM "{table}" WHERE zoom_level >= ? AND zoom_level <= ? ORDER BY zoom_level',
            (min_zoom, max_zoom),
        )
        for zoom_level, tile_column, tile_row, tile_data in cur:
            yield Tile(z=zoom_level, x=tile_column, y=tile_row, data=tile_data)
    finally:
        conn.close()


def iter_specific_tiles(gpkg_path: str, table: str, coords: set[tuple[int, int, int]]):
    """Yield Tile rows matching an explicit set of (z, x, y) coordinates.

    Used to re-upload a small list of previously-failed tiles without
    re-scanning/re-uploading an entire zoom range.
    """
    uri = f"file:{gpkg_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        zooms = sorted({z for z, _, _ in coords})
        placeholders = ",".join("?" * len(zooms))
        cur = conn.execute(
            f"SELECT zoom_level, tile_column, tile_row, tile_data "
            f'FROM "{table}" WHERE zoom_level IN ({placeholders})',
            zooms,
        )
        for zoom_level, tile_column, tile_row, tile_data in cur:
            if (zoom_level, tile_column, tile_row) in coords:
                yield Tile(z=zoom_level, x=tile_column, y=tile_row, data=tile_data)
    finally:
        conn.close()


def parse_tile_coord(spec: str) -> tuple[int, int, int]:
    """Parse a tile coordinate spec into (z, x, y).

    Accepts both the plain 'z/y/x' or 'z:y:x' form and the letter-prefixed
    form used in this script's own error messages, e.g. 'z15/y9862/x17573'.
    """
    parts = spec.replace(":", "/").strip().split("/")
    if len(parts) != 3:
        raise ValueError(f"invalid tile spec {spec!r}, expected 'z/y/x'")
    numbers = [part.lstrip("zyxZYX") for part in parts]
    try:
        z, y, x = (int(p) for p in numbers)
    except ValueError as exc:
        raise ValueError(f"invalid tile spec {spec!r}, expected 'z/y/x'") from exc
    return (z, x, y)


def count_tiles(gpkg_path: str, table: str, min_zoom: int, max_zoom: int) -> int:
    uri = f"file:{gpkg_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        (n,) = conn.execute(
            f'SELECT COUNT(*) FROM "{table}" WHERE zoom_level >= ? AND zoom_level <= ?',
            (min_zoom, max_zoom),
        ).fetchone()
        return n
    finally:
        conn.close()


def make_r2_client(account_id: str, access_key: str, secret_key: str, max_pool_connections: int):
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


def upload_tile(client, bucket: str, prefix: str, tile: Tile) -> str:
    key = f"{prefix}{tile.z}/{tile.y}/{tile.x}.png"
    for attempt in range(1, MAX_TILE_RETRIES + 1):
        try:
            client.put_object(
                Bucket=bucket,
                Key=key,
                Body=tile.data,
                ContentType="image/png",
                CacheControl="public, max-age=15768000",
            )
            return key
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code not in RETRYABLE_ERROR_CODES or attempt == MAX_TILE_RETRIES:
                raise
            sleep_for = BASE_BACKOFF_SECONDS * (2 ** (attempt - 1)) + random.uniform(0, 0.5)
            time.sleep(sleep_for)
    raise RuntimeError(f"unreachable: exhausted retries for {key}")  # pragma: no cover


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gpkg", required=True, help="Path to the .gpkg file")
    parser.add_argument(
        "--table", default="topowebb", help="Tile table name inside the GeoPackage"
    )
    parser.add_argument("--bucket", default="tiles", help="R2 bucket name")
    parser.add_argument(
        "--prefix", required=True, help="Key prefix, e.g. 'v1'"
    )
    parser.add_argument(
        "--min-zoom", type=int, help="Lowest zoom level to upload (ignored with --only-tiles)"
    )
    parser.add_argument("--max-zoom", type=int, default=9, help="Highest zoom level to upload")
    parser.add_argument(
        "--workers", type=int, default=48, help="Concurrent upload workers"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="List what would be uploaded, skip network calls"
    )
    parser.add_argument(
        "--only-tiles",
        nargs="+",
        metavar="Z/Y/X",
        help=(
            "Re-upload only these specific tile coordinates (e.g. previously-failed "
            "ones), given as 'z/y/x' (matching the error log format). Bypasses "
            "--min-zoom/--max-zoom scanning entirely."
        ),
    )
    args = parser.parse_args()

    gpkg_path = os.path.expanduser(args.gpkg)
    if not os.path.isfile(gpkg_path):
        print(f"error: gpkg not found: {gpkg_path}", file=sys.stderr)
        return 1

    prefix = args.prefix
    if prefix and not prefix.endswith("/"):
        prefix += "/"

    if args.only_tiles:
        try:
            coords = {parse_tile_coord(spec) for spec in args.only_tiles}
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        total = len(coords)
        print(f"Re-uploading {total} specific tile(s) from table '{args.table}'")
    else:
        if args.min_zoom is None:
            print("error: --min-zoom is required unless --only-tiles is given", file=sys.stderr)
            return 1
        total = count_tiles(gpkg_path, args.table, args.min_zoom, args.max_zoom)
        print(
            f"Found {total} tiles at zoom {args.min_zoom}-{args.max_zoom} in table '{args.table}'"
        )

    def make_tile_source():
        if args.only_tiles:
            return iter_specific_tiles(gpkg_path, args.table, coords)
        return iter_tiles(gpkg_path, args.table, args.min_zoom, args.max_zoom)

    if args.dry_run:
        for tile in make_tile_source():
            print(f"{prefix}{tile.z}/{tile.y}/{tile.x}.png ({len(tile.data)} bytes)")
        return 0

    account_id = os.environ.get("R2_ACCOUNT_ID")
    access_key = os.environ.get("R2_ACCESS_KEY_ID")
    secret_key = os.environ.get("R2_SECRET_ACCESS_KEY")
    if not all([account_id, access_key, secret_key]):
        print(
            "error: set R2_ACCOUNT_ID, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY",
            file=sys.stderr,
        )
        return 1

    client = make_r2_client(
        account_id, access_key, secret_key, max_pool_connections=args.workers
    )

    uploaded = 0
    failed = 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        tiles = list(make_tile_source())
        random.shuffle(tiles)  # spread out adjacent keys across workers to avoid hot partitions
        futures = {
            pool.submit(upload_tile, client, args.bucket, prefix, tile): tile
            for tile in tiles
        }
        for future in as_completed(futures):
            tile = futures[future]
            try:
                key = future.result()
                uploaded += 1
                if uploaded % 500 == 0 or uploaded == total:
                    print(f"[{uploaded}/{total}] uploaded {key}")
            except Exception as exc:  # noqa: BLE001 - report and keep going
                failed += 1
                print(
                    f"error uploading z{tile.z}/y{tile.y}/x{tile.x}: {exc}",
                    file=sys.stderr,
                )

    print(f"Done. Uploaded {uploaded}/{total} tiles, {failed} failed.")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
