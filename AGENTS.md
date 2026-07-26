# AGENTS.md

## Project overview
iOS app (SwiftUI + MapKit) that overlays topographic map tiles from Kartverket (Norway) and Lantmäteriet (Sweden) on top of Apple Maps.

## Key files
| File | Purpose |
|---|---|
| `fjallkartan/MapView.swift` | `UIViewRepresentable` wrapping `MKMapView`; adds the tile overlay |
| `fjallkartan/CustomTileOverlay.swift` | `MKTileOverlay` subclass; fetches tiles from the correct server |
| `fjallkartan/TileCoverageResolver.swift` | Determines per-tile coverage (Norway / Sweden / none) using GeoJSON polygons |
| `fjallkartan/fjallkartanApp.swift` | App entry point |
| `fjallkartan/ContentView.swift` | Root SwiftUI view |

## Architecture notes
- **`TileCoverageResolver`**
  - Coverage is determined by checking all 4 tile corners + center against `norway_coverage.geojson` and `sweden_coverage.geojson` using the [Turf](https://github.com/mapbox/turf-swift) library.
  - Returns `TileCoverage(norway: Bool, sweden: Bool)` — both can be true for border tiles.

- **`CustomTileOverlay`**
  - Two instances are created in `MapView.makeUIView` — one per server — added in order: Lantmäteriet first (opaque), Kartverket second (transparent on top), so MapKit composites them correctly at the border.
  - Both instances share a single `URLCache` (500 MB disk, 0 MB memory), TTL is 1 year
  - Cache lookup and storage is done **manually**
  - Cache key = real tile URL
