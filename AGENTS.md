# AGENTS.md

## Project overview
iOS app (SwiftUI + MapKit) that overlays topographic map tiles from Kartverket (Norway) and Lantmäteriet (Sweden) on top of Apple Maps.

## Key files
| File | Purpose |
|---|---|
| `MapView.swift` | `UIViewRepresentable` wrapping `MKMapView`; adds the tile overlay |
| `CustomTileOverlay.swift` | `MKTileOverlay` subclass; fetches tiles from the correct server |
| `TileServerResolver.swift` | Determines per-tile coverage (Norway / Sweden / none) using GeoJSON polygons |
| `fjallkartanApp.swift` | App entry point |
| `ContentView.swift` | Root SwiftUI view |

## Architecture notes
- **`TileServerResolver`**
  - Coverage is determined by checking the centre point of each tile against `norway_coverage.geojson` and `sweden_coverage.geojson` using the [Turf](https://github.com/mapbox/turf-swift) library.

- **`CustomTileOverlay`**
  - Uses a dedicated `URLCache` (500 MB disk, 0 MB memory), TTL is 1 year
  - Cache lookup and storage is done **manually**
  - Cache key = real tile URL
