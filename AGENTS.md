# AGENTS.md

## Project overview
iOS app (SwiftUI + MapKit) that displays topographic map tiles from Kartverket (Norway) and Lantmäteriet (Sweden).

## Key files
| File | Purpose |
|---|---|
| `fjallkartan/fjallkartanApp.swift` | App entry point |
| `fjallkartan/ContentView.swift` | Root SwiftUI view; hosts `MapView` plus the scale bar, copyright notice and measurement overlays. |
| `fjallkartan/MapView.swift` | `UIViewRepresentable` wrapping `MKMapView`; adds the tile overlays, sets camera limits, reports scale, and renders the measured route. |
| `fjallkartan/CustomTileOverlay.swift` | `MKTileOverlay` subclass; fetches, caches and post-processes tiles for one server |
| `fjallkartan/DistanceMeasurement.swift` | `@Observable` model holding the traced route and its geodesic length, plus `LineSimplifier` (Ramer–Douglas–Peucker). |
| `fjallkartan/MeasureCaptureView.swift` | Transparent `UIView` over the map that captures freehand strokes and draws live preview. |
| `fjallkartan/PlaceSearch.swift` | SQLite-backed FTS5 lookup of place names (`PlaceSearch`, `PlaceResult`, `PlaceKind`) against the bundled `places.sqlite`. |
| `fjallkartan/PlaceSearchView.swift` | `PlaceSearchModel` (debounced async search) and `PlaceSearchSheet` UI presenting results. |
| `fjallkartan/TilePyramid.swift` | Pure functions enumerating the fixed z7–z14 offline tile pyramid and estimating its download size. |
| `fjallkartan/ReviewPrompter.swift` | Throttling logic deciding when to ask for an App Store review. |
| `fjallkartan/OfflineTileStore.swift` | SQLite blob store for downloaded tiles (`tiles`, `region_tiles`, `regions` tables), with refcounted region deletion and ancestor lookup for upscaling. |
| `fjallkartan/OfflineRegionDownloader.swift` | `@Observable` downloader: bounded-concurrency fetch of a region's tiles into `OfflineTileStore`, with pause/resume/cancel and retry/backoff. |
| `fjallkartan/OfflineRegionsView.swift` | `OfflineRegionsModel` (region list + active downloaders) and `OfflineRegionsSheet` UI for starting/managing offline regions. |
| `tools/build_places_db.py` | Builds `places.sqlite` (place, alias, municipality tables + `place_fts` FTS5 index) bundled with the app. |
| `tools/make_app_icon.py` | Regenerates the app icon

## Architecture notes

- **`MapView`**
  - Two `CustomTileOverlay` instances are added in `makeUIView`: Lantmäteriet first (opaque base), Kartverket second (composited on top). Order matters for the border to render correctly.

- **`CustomTileOverlay`**
  - Tiles are always requested from both servers, and empty/no-data areas simply come back blank.
  - Kartverket's no-data fill is transparent at low zoom but an opaque cream (~255,255,230) from ~z15; `kartverketNoDataToTransparentPNG` rewrites those pixels to transparent so Lantmäteriet shows through. Lantmäteriet tiles are passed through untouched.
  - All instances share one `URLSession` / `URLCache` (64 MB memory, 500 MB disk).
  - Cache lookup and storage is done **manually** with a TTL of 1 year.
  - Cache key = the real tile URL.
  - Lookup order is **offline store → `URLCache` → network**; the offline store wins even when online, since a disk read beats a round trip. Above the downloaded z14 cap, an offline miss with no network falls back to `OfflineTileStore.nearestAncestorTile`, cropping and upscaling the nearest stored ancestor instead of leaving the tile blank.

- **Offline map regions**
  - Downloads are capped to a fixed **z7–z14** pyramid (`TilePyramid`) — enough for route/terrain reading, still smaller than the online z18 ceiling, with a hard refusal above ~1.5 GB (purely a guard against selecting the whole of Scandinavia) or when `OfflineTileStore.availableCapacityBytes` shows the device doesn't have enough free space for the estimate.
  - `OfflineTileStore` persists raw (pre-`CustomTileOverlay`-processing) tile bytes in `Application Support/offline-tiles.sqlite` (excluded from backup). Tiles are deduped and refcounted across regions via `region_tiles`; `deleteRegion` only removes tiles with no remaining owner.
  - `OfflineRegionDownloader` fetches both servers for every tile position (borders need both), with max 4 concurrent requests, exponential backoff on `429`/`503`, and up to 3 retries before skipping a tile and continuing. Progress is written to SQLite in ~50-tile batches, so `resume` (or a fresh app launch) just re-enumerates and skips tiles already present. A SQLite write failure (e.g. disk full) aborts the download and surfaces as `.failed(message)`, shown in the region row instead of silently reporting success.
  - `OfflineRegionsSheet`'s "current view" download area is an inset of `MapView`'s `visibleMapRect`; the same rect is drawn as a dashed `RegionPreviewOverlay` on the map while the sheet is open.

- **Distance measurement**
  - While measuring, `MeasureCaptureView` becomes interactive and swallows every touch, which is what stops MapKit's pan/zoom recognisers from competing with drawing. Live feedback is drawn in screen space (`CAShapeLayer`) so the map is not re-rendered mid-drag.
  - On touch-up the stroke is simplified in screen space, converted to coordinates and appended to `DistanceMeasurement`; consecutive strokes are joined by a straight connector so the user can pan between them.
  - Distances are geodesic (`CLLocation.distance(from:)`). A Mercator-space measurement would overstate by ~2.7x at 68°N.
  - `MapView` rebuilds the route overlay only when `DistanceMeasurement.version` changes. `ContentView` passes `isMeasuring` / `routeVersion` as plain values so Observation triggers `updateUIView`.

- **App Store review prompt**
  - Two conditions must line up: **≥3 app opens** (engagement) and a success — either an offline region download reaching `.completed`, or **3 finished measurements** of ≥500 m (`ReviewPrompter.minimumMeasurementMeters`). Only a success arms the prompt; `noteBecameActive()` just accrues opens, so crossing the open threshold alone never triggers anything.
  - A measurement counts when `isMeasuring` goes false and the route grew during that session (`ContentView` snapshots `measurement.version` at session start), so toggling the ruler on and off doesn't inflate the count.
  - Throttled to one prompt per app version with a 120-day floor between prompts. `ReviewPrompter` only sets `pendingToken`; `ContentView` fires `@Environment(\.requestReview)` after a 3 s pause once no sheet, region picker or measurement is active.
  - `OfflineRegionsModel.onRegionDownloadCompleted` is injectable so tests don't touch the shared prompter's `UserDefaults`.

- **Place search**
  - `PlaceSearch` opens `places.sqlite` read-only and runs a single prepared statement (`searchSQL`) that matches, scores, deduplicates and hydrates results in one pass via `place_fts` (FTS5), `alias`, `place` and `municipality`.
  - `ftsExpression(for:)` tokenizes free text into terms; scoring favors exact-length matches, lower `p.rank`, primary names over aliases, and demotes less map-relevant `PlaceKind`s.
  - Coordinates are stored as scaled integers (`coordinateScale = 100_000`) to keep the `place` table compact.
  - `PlaceSearchModel` debounces input (150 ms) on a background queue. `PlaceSearchSheet` renders results and feeds a selected `PlaceResult` back to `ContentView`.

## Build & test
- Xcode project: `fjallkartan.xcodeproj`, scheme `fjallkartan`.
- The project uses filesystem-synced groups (`PBXFileSystemSynchronizedRootGroup`), so new source files added under `fjallkartan/` or `fjallkartanTests/` are picked up automatically — no `project.pbxproj` edit needed.
- Tests: `xcodebuild -scheme fjallkartan -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test` (Swift Testing).
