# AGENTS.md

## Project overview
iOS app (SwiftUI + MapKit) that displays topographic map tiles from Kartverket (Norway) and Lantmäteriet (Sweden).

## Key files
| File | Purpose |
|---|---|
| `fjallkartan/fjallkartanApp.swift` | App entry point |
| `fjallkartan/ContentView.swift` | Root SwiftUI view; hosts `MapView` plus the scale bar, copyright notice and zoom-level overlays. |
| `fjallkartan/MapView.swift` | `UIViewRepresentable` wrapping `MKMapView`; adds the tile overlays, sets camera limits, and reports zoom / scale. |
| `fjallkartan/CustomTileOverlay.swift` | `MKTileOverlay` subclass; fetches, caches and post-processes tiles for one server |

## Architecture notes

- **`MapView`**
  - Two `CustomTileOverlay` instances are added in `makeUIView`: Lantmäteriet first (opaque base), Kartverket second (composited on top). Order matters for the border to render correctly.

- **`CustomTileOverlay`**
  - Tiles are always requested from both servers, and empty/no-data areas simply come back blank.
  - Kartverket's no-data fill is transparent at low zoom but an opaque cream (~255,255,230) from ~z15; `kartverketNoDataToTransparentPNG` rewrites those pixels to transparent so Lantmäteriet shows through. Lantmäteriet tiles are passed through untouched.
  - All instances share one `URLSession` / `URLCache` (64 MB memory, 500 MB disk).
  - Cache lookup and storage is done **manually** with a TTL of 1 year.
  - Cache key = the real tile URL.

## Build & test
- Xcode project: `fjallkartan.xcodeproj`, scheme `fjallkartan`, iOS deployment target 26.5.
