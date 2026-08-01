# AGENTS.md

## Project overview
iOS app (SwiftUI + MapKit) that displays topographic map tiles from Kartverket (Norway) and Lantmäteriet (Sweden).

## Key files
| File | Purpose |
|---|---|
| `fjallkartan/fjallkartanApp.swift` | App entry point |
| `fjallkartan/ContentView.swift` | Root SwiftUI view; hosts `MapView` plus the scale bar, copyright notice, zoom-level and measurement overlays. |
| `fjallkartan/MapView.swift` | `UIViewRepresentable` wrapping `MKMapView`; adds the tile overlays, sets camera limits, reports zoom / scale, and renders the measured route. |
| `fjallkartan/CustomTileOverlay.swift` | `MKTileOverlay` subclass; fetches, caches and post-processes tiles for one server |
| `fjallkartan/DistanceMeasurement.swift` | `@Observable` model holding the traced route and its geodesic length, plus `LineSimplifier` (Ramer–Douglas–Peucker). |
| `fjallkartan/MeasureCaptureView.swift` | Transparent `UIView` over the map that captures freehand strokes and draws live preview. |
| `fjallkartanTests/DistanceMeasurementTests.swift` | Swift Testing coverage for distance maths, stroke bookkeeping and simplification. |
| `Tools/make_app_icon.py` | Regenerates the app icon

## Architecture notes

- **`MapView`**
  - Two `CustomTileOverlay` instances are added in `makeUIView`: Lantmäteriet first (opaque base), Kartverket second (composited on top). Order matters for the border to render correctly.

- **`CustomTileOverlay`**
  - Tiles are always requested from both servers, and empty/no-data areas simply come back blank.
  - Kartverket's no-data fill is transparent at low zoom but an opaque cream (~255,255,230) from ~z15; `kartverketNoDataToTransparentPNG` rewrites those pixels to transparent so Lantmäteriet shows through. Lantmäteriet tiles are passed through untouched.
  - All instances share one `URLSession` / `URLCache` (64 MB memory, 500 MB disk).
  - Cache lookup and storage is done **manually** with a TTL of 1 year.
  - Cache key = the real tile URL.

- **Distance measurement**
  - While measuring, `MeasureCaptureView` becomes interactive and swallows every touch, which is what stops MapKit's pan/zoom recognisers from competing with drawing. Live feedback is drawn in screen space (`CAShapeLayer`) so the map is not re-rendered mid-drag.
  - On touch-up the stroke is simplified in screen space, converted to coordinates and appended to `DistanceMeasurement`; consecutive strokes are joined by a straight connector so the user can pan between them.
  - Distances are geodesic (`CLLocation.distance(from:)`). A Mercator-space measurement would overstate by ~2.7x at 68°N.
  - `MapView` rebuilds the route overlay only when `DistanceMeasurement.version` changes. `ContentView` passes `isMeasuring` / `routeVersion` as plain values so Observation triggers `updateUIView`.

## Build & test
- Xcode project: `fjallkartan.xcodeproj`, scheme `fjallkartan`, iOS deployment target 26.5.
- Tests: `xcodebuild -scheme fjallkartan -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test` (Swift Testing).
