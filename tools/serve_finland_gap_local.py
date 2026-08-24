#!/usr/bin/env python3
"""Local HTTP server for testing the Finland-gap composite before uploading
anything to R2.

Serves `out/finland-gap/{z}/{y}/{x}.png` when a composited tile exists there
(i.e. `build_finland_gap_tiles.py composite` produced it), and transparently
falls back to the real production tile from https://tiles.wallman.dev for
every other request -- so pointing the app at this server gives an
otherwise-identical map with only the gap area patched in. Fallback tiles
are cached to disk so repeated Simulator panning doesn't keep hitting the
network.

Usage
-----
    python3 tools/serve_finland_gap_local.py [--port 8765]

Then either:
  - point the app at http://127.0.0.1:<port>/v1/{z}/{y}/{x}.png with
    `tools/point_app_at_local_tiles.py`, or
  - hardcode that URL directly in MapView.swift for a quick manual test.

127.0.0.1 is ATS-exempt on iOS, so plain HTTP works with no Info.plist
changes, both from a device on the same network and from the Simulator.
"""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

TILE_PATTERN = "/v1/{z}/{y}/{x}.png"
PROD_BASE = "https://tiles.wallman.dev/v1"

REPO_ROOT = Path(__file__).resolve().parent.parent
COMPOSITE_DIR = REPO_ROOT / "out" / "finland-gap"
PROXY_CACHE_DIR = REPO_ROOT / "out" / "finland-gap-proxy-cache"


def parse_tile_path(path: str) -> tuple[int, int, int] | None:
    parts = path.strip("/").split("/")
    if len(parts) != 4 or parts[0] != "v1" or not parts[3].endswith(".png"):
        return None
    try:
        z = int(parts[1])
        y = int(parts[2])
        x = int(parts[3][: -len(".png")])
    except ValueError:
        return None
    return z, x, y


class TileHandler(BaseHTTPRequestHandler):
    server_version = "FinlandGapLocal/1.0"

    def log_message(self, fmt: str, *args) -> None:  # quieter default logging
        print(f"  {self.address_string()} {fmt % args}")

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        parsed = parse_tile_path(self.path)
        if parsed is None:
            self.send_error(404, "not a tile path")
            return
        z, x, y = parsed

        composite_path = COMPOSITE_DIR / str(z) / str(y) / f"{x}.png"
        if composite_path.is_file():
            self._serve_file(composite_path, source="composite")
            return

        cache_path = PROXY_CACHE_DIR / str(z) / str(y) / f"{x}.png"
        if cache_path.is_file():
            self._serve_file(cache_path, source="proxy-cache")
            return

        prod_url = f"{PROD_BASE}/{z}/{y}/{x}.png"
        try:
            with urlopen(prod_url, timeout=10) as resp:
                data = resp.read()
        except HTTPError as e:
            self.send_error(e.code, f"upstream {e.code}")
            return
        except URLError as e:
            self.send_error(502, f"upstream unreachable: {e.reason}")
            return

        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_bytes(data)
        self._serve_bytes(data, source="proxy")

    def _serve_file(self, path: Path, source: str) -> None:
        self._serve_bytes(path.read_bytes(), source=source)

    def _serve_bytes(self, data: bytes, source: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Tile-Source", source)
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    PROXY_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    n_composited = sum(1 for _ in COMPOSITE_DIR.glob("*/*/*.png")) if COMPOSITE_DIR.is_dir() else 0
    print(f"Serving {n_composited} composited tile(s) from {COMPOSITE_DIR}")
    print(f"Falling back to {PROD_BASE} for everything else (cached under {PROXY_CACHE_DIR})")

    server = ThreadingHTTPServer((args.host, args.port), TileHandler)
    print(f"Listening on http://{args.host}:{args.port}{TILE_PATTERN}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")


if __name__ == "__main__":
    main()
