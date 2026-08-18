# AGENTS.md

## Project overview
iOS app (SwiftUI + MapKit) that displays topographic map tiles from Kartverket (Norway) and Lantmäteriet (Sweden).

## Key files
| File | Purpose |
|---|---|
| `fjallkartan/fjallkartanApp.swift` | App entry point |
| `fjallkartan/ContentView.swift` | Root SwiftUI view; hosts `MapView` plus the scale bar, copyright notice and measurement overlays. |
| `fjallkartan/MapView.swift` | `UIViewRepresentable` wrapping `MKMapView`; adds the tile overlays, sets camera limits, reports scale, and renders the measured route. |
| `fjallkartan/TileFetcher.swift` | Shared tile layer: does offline store → `URLCache` → network → ancestor upscale (fixed-TTL cache, retry with backoff, `success`/`noData`/`failure`). |
| `fjallkartan/TileMetrics.swift` | On-device aggregate counters for tile requests (source breakdown, fault rate, latency histogram), persisted to `Application Support/tile-metrics.json`. |
| `fjallkartan/DebugView.swift` | DebugSheet  reading `TileMetrics`, opened by long-pressing the version row in `AboutSheet`. |
| `fjallkartan/DistanceMeasurement.swift` | `@Observable` model holding the traced route and its geodesic length, plus `LineSimplifier` (Ramer–Douglas–Peucker). |
| `fjallkartan/MeasureCaptureView.swift` | Transparent `UIView` over the map that captures freehand strokes and draws live preview. |
| `fjallkartan/PlaceSearch.swift` | SQLite-backed FTS5 lookup of place names (`PlaceSearch`, `PlaceResult`, `PlaceKind`) against the bundled `places.sqlite`. |
| `fjallkartan/PlaceSearchView.swift` | `PlaceSearchModel` (debounced async search) and `PlaceSearchSheet` UI presenting results. |
| `fjallkartan/SavedRoute.swift` | Codable model for one saved measurement (id, createdAt, coordinates, strokeSizes, optional name, schemaVersion, displayName). |
| `fjallkartan/SavedRouteStore.swift` | Thin wrapper over `DocumentDirectoryStore<SavedRoute>` for one-JSON-file-per-route persistence. |
| `fjallkartan/SavedRoutesView.swift` | `SavedRoutesModel` and `SavedRoutesList` UI (embedded in `SavedSheet`) for listing/loading/renaming/deleting saved routes. |
| `fjallkartan/FeaturedRoutes.swift` | Read-only catalogue of bundled suggested routes, decoded once from `resources/featured-routes.json`. |
| `fjallkartan/RouteNameSheet.swift` | Small sheet used both to name a route on save and to rename one from the saved list. |
| `fjallkartan/Coord.swift` | Shared `Coord` (lat/lon pair) used by both `SavedRoute` and `SavedPin`, since `CLLocationCoordinate2D` isn't `Codable`. |
| `fjallkartan/DocumentDirectoryStore.swift` | Generic one-JSON-file-per-item store; local-first with optional iCloud Documents sync (migration, `NSFileCoordinator` writes, `NSMetadataQuery` change observation). Backs both `SavedRouteStore` and `SavedPinStore`. |
| `fjallkartan/SavedPin.swift` | Codable model for a saved pin (id, createdAt, coordinate, optional name/subtitle, schemaVersion, displayName). |
| `fjallkartan/SavedPinStore.swift` | Thin wrapper over `DocumentDirectoryStore<SavedPin>`, adding `rename(_:to:)`. |
| `fjallkartan/SavedPinsView.swift` | `SavedPinsModel` (load/save/rename/delete for saved pins) and `SavedSheet` (the "Saved" toolbar sheet, routes-only). |
| `fjallkartan/PinDetailSheet.swift` | Low bottom sheet (Rename + destructive Delete) opened when a pin annotation is tapped on the map. |
| `fjallkartan/ElevationService.swift` | Samples terrain height from the prebaked z12 elevation tiles: fetch via `TileFetcher`, RGBA→metres decode, per-tile cache and in-flight dedupe. |
| `fjallkartan/ElevationProfile.swift` | `@Observable` profile of the measured route — fixed-spacing resampling, ascent/descent with hysteresis, coverage. |
| `fjallkartan/ElevationProfileView.swift` | `ElevationProfileSheet`: Swift Charts terrain profile opened from the distance readout. |
| `fjallkartan/TilePyramid.swift` | Pure functions enumerating the fixed z7–z14 offline tile pyramid — positions, per-layer `Job`s and download size estimate. |
| `fjallkartan/RemoteSettings.swift` | Remotely configurable tile URL templates (`TileSettings`: Lantmäteriet, Kartverket, Norwegian slope, Swedish slope), fetched from `settings.json` with built-in fallbacks. |
| `fjallkartan/SlopeTileOverlay.swift` | `MKTileOverlay` for the steepness layer; one instance per `Country`, each with its own zoom limits. |
| `fjallkartan/TileUpscaler.swift` | Shared helper that builds a deep-zoom tile by cropping and magnifying the ancestor containing it; used by both tile layers. |
| `fjallkartan/LegendCatalog.swift` | All legend entries — grouped into sections. |
| `fjallkartan/AboutView.swift` | `AboutButton` and `AboutSheet`: data-source attribution (Kartverket, Lantmäteriet, NVE) plus privacy-policy and support links. |
| `fjallkartan/ReviewPrompter.swift` | Throttling logic deciding when to ask for an App Store review. |
| `fjallkartan/NetworkCheck.swift` | One-shot `NWPathMonitor` connectivity check (no persistent monitor); used to postpone the review prompt while offline. |
| `fjallkartan/OfflineTileStore.swift` | SQLite blob store for downloaded tiles (`tiles`, `region_tiles`, `regions` tables), with refcounted region deletion and ancestor lookup for upscaling. |
| `fjallkartan/OfflineRegionDownloader.swift` | `@Observable` downloader: bounded-concurrency fetch of a region's tiles into `OfflineTileStore`, with pause/resume/cancel and retry/backoff. |
| `fjallkartan/OfflineRegionsView.swift` | `OfflineRegionsModel` (region list + active downloaders) and `OfflineRegionsSheet` UI for starting/managing offline regions. |
| `fjallkartan/InfoPlist.xcstrings` | Localized `Info.plist` values: `CFBundleDisplayName` (home-screen name, translated for nb/da/fi) and `NSLocationWhenInUseUsageDescription`. |
| `fjallkartan/Localizable.xcstrings` | All in-app UI strings. |
| `fjallkartan/PrivacyInfo.xcprivacy` | Privacy manifest: no tracking, no collected data, and the required-reason API declarations. |
| `fjallkartan/fjallkartan.entitlements` | iCloud Documents entitlements that `DocumentDirectoryStore` needs for its ubiquity container. |
| `marketing/store-copy.md` | Per-locale App Store name/subtitle/description copy plus the support and privacy URLs. |
| `docs/privacy.html`, `docs/support.html` | GitHub Pages pages linked from `AboutSheet` and App Store. |
| `tools/extract_legend_symbols.py` | Clips the 27 Swedish legend symbols out of `tools/legend_se_source.pdf` into vector assets (`preview` → `verify` → `assets`); `verify` diffs each against an embed-and-crop oracle. |
| `tools/build_no_legend_symbols.py` | Draws the 16 Norwegian legend symbols from Kartverket's `Skjermkartografi.otf` using the glyph codes, colours and dash patterns in their published specification (`fetch` → `preview` → `assets`). |
| `tools/fill_legend_translations.py` | Fills the legend strings in `Localizable.xcstrings` from one table, so the 43 symbol names stay consistent across the 10 translations. |
| `tools/build_places_db.py` | Builds `places.sqlite` (place, alias, municipality tables + `place_fts` FTS5 index) bundled with the app. |
| `tools/compose_screenshots.py` | Composes screenshots into captioned App Store screenshots in `marketing/appstore/<lang>/`. |
| `tools/make_app_icon.py` | Regenerates the app icon. |
| `tools/build_elevation_tiles.py` | Builds the z12 elevation tiles for both countries and uploads them to R2 (`tiles` → `verify` → `upload`). |
| `tools/build_sweden_slope_tiles.py` | Derives the Swedish slope tiles from Lantmäteriet elevation data and uploads them to R2 (`fetch` → `tiles` → `verify` → `upload`). |

## Architecture notes

- **`MapView`**
  - Two `CustomTileOverlay` instances are added in `makeUIView`: Lantmäteriet first (opaque base), Kartverket second (composited on top). Order matters for the border to render correctly.

- **`CustomTileOverlay`**
  - Tiles are always requested from both servers, and empty/no-data areas simply come back blank.
  - Kartverket's no-data fill is transparent at low zoom but an opaque cream (~255,255,230) from ~z15; `kartverketNoDataToTransparentPNG` rewrites those pixels to transparent so Lantmäteriet shows through. Lantmäteriet tiles are passed through untouched.

- **Tile metrics**
  - Counters are **aggregate-only and coordinate-free**: the key is `(layer, zoom)`, never `(x, y)`. Nothing leaves the device.
  - Attribution lives entirely inside `TileFetcher`: a private `Resolution` tags each lookup as offline store / `URLCache` / network / upscaled ancestor / no-data / failure.
  - Latency is a fixed-bound histogram rather than a running mean, and percentiles are reported as the containing bucket bound (`≤ 300 ms`).
  - Recording is a lock plus a dictionary increment on the URLSession completion thread; the file is written only every 200 records and on scene-background.

- **Remote settings**
  - `RemoteSettings.shared.refresh()` runs on scene activation and fetches `https://tiles.wallman.dev/settings.json` at most once per 6 h, so a provider that changes its URL can be followed without an app update.
  - `RemoteSettings.builtIn` holds the original hardcoded templates and is always a working configuration. An accepted payload is persisted as raw JSON in `UserDefaults`, so later launches start from the last known-good value.
  - A changed URL only affects online fetches: `URLCache` is keyed on the real URL (so it self-invalidates), but `OfflineTileStore` is keyed by `(server, z, x, y)` and is consulted first, so already-downloaded regions keep serving the old provider's tiles until the region is re-downloaded.

- **Slope layer**
  - Two `SlopeTileOverlay` instances, one per country, both drawn at `alpha = 0.6`. Norway serves NVE's finished `Bratthet_med_utlop_2024` pictures (z5–16); Sweden has no such service, so we render our own (z5–13) — hence the per-country zoom limits. Above `sourceMaximumZ` the overlay itself fetches the deepest published ancestor and magnifies it.
  - Both tilesets are sparse, so 404s is the normal case. `TileFetcher` therefore caches a no-data marker for a 4xx in the same `URLCache`.
  - The Swedish tiles are built offline by `tools/build_sweden_slope_tiles.py` and match NVE's palette exactly, minus the runout blues (Sweden publishes no runout model) and minus the green <30° band.
  - Slope is computed with Horn 3×3 in EPSG:3006 **before** warping to Web Mercator — Mercator inflates distances by 1/cos(lat) (~2.2× at 63°N), which would flatten every slope. The warp is nearest-neighbour because the pixel values are class labels, not quantities. Only z13 is computed from elevation; lower zooms are max-pooled from their four children so a steep face stays visible as it shrinks below a pixel.
  - Agreement with NVE across the border is 96.6 % exact / 99.5 % within one class over 1,395,357 pixels sampled from 60 border tiles.
  - The tiles are hosted on Cloudflare R2 (bucket `tiles`, prefix `slope/v1`), fronted by `tiles.wallman.dev`.

- **Elevation**
  - Elevation come from prebaked XYZ tiles (`https://tiles.wallman.dev/elevation/v1/{z}/{y}/{x}.png`). This makes it work offline. 
  - The tiles are **data, not pictures**, and are never added to the map: each pixel carries `metres + 32768` as `R = value >> 8`, `G = value & 0xFF`, `B = 0`, with a fully transparent pixel meaning no data. The offset puts every Nordic height in the R ≈ 128–137 band, which is why an elevation tile looks like flat dark red with fine noise when opened in an image viewer.
  - 1 m precision is deliberate: decimetres would put noise in the low byte and roughly triple the PNG size for no gain.
  - Published at **z12 only** (~18 m per pixel at 62°N), which matches the 25 m spacing routes are sampled at. z13 was built and measured: it is ~60% better per point but changes ascent totals by well under 1%.
  - Norway is exported from Kartverket's `NHM_DTM_25833` ImageServer (the same source behind the Geonorge point API, which the build script uses only as a verification oracle); Sweden is warped from the local DEM mosaic shared with the slope build. Both verified against their official point service: median error 0.60 m (NO) and 0.33 m (SE). Border tiles merge the two sources, since neither service alone covers a tile on the line.
  - `ElevationProfile` resamples at a fixed 25 m so totals don't depend on how fast the route was traced, and applies 4 m hysteresis so metre-level model noise doesn't accumulate into phantom climb (measured: ~2.5% of the total). A no-data gap **breaks** the run rather than being bridged, so the unknown step across it is never invented.

- **Offline map regions**
  - Downloads are capped to a fixed **z7–z14** pyramid (`TilePyramid`) — enough for route/terrain reading, still smaller than the online z18 ceiling, with a hard refusal above ~1.5 GB (purely a guard against selecting the whole of Scandinavia) or when `OfflineTileStore.availableCapacityBytes` shows the device doesn't have enough free space for the estimate.
  - All layers are downloaded, each within its own `offlineMinimumZ...offlineMaximumZ`, so the Swedish slope tiles (published only to z13) are never requested at z14. `TilePyramid.jobs(in:)` is the single enumeration both the downloader and the size estimate use, so a progress bar can't disagree with what is actually fetched.
  - `OfflineTileStore` persists raw (pre-`CustomTileOverlay`-processing) tile bytes in `Application Support/offline-tiles.sqlite` (excluded from backup). Tiles are deduped and refcounted across regions via `region_tiles`; `deleteRegion` only removes tiles with no remaining owner.
  - `OfflineRegionDownloader` fetches both servers for every tile position (borders need both). It reads the shared browse cache (`TileFetcher.sharedTileCache`) before going to the network, so tiles the user already panned over are copied straight into the offline store; that lookup is read-only (`storesResponses: false`) since the downloader keeps its own copy anyway and a bulk region download would otherwise evict the map's cached tiles. Progress is written to SQLite in ~50-tile batches, so `resume` (or a fresh app launch) just re-enumerates and skips tiles already present. A SQLite write failure (e.g. disk full) aborts the download and surfaces as `.failed(message)`, shown in the region row instead of silently reporting success.
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

- **App Store screenshots**
  - `compose_screenshots.py` keeps geometry and colours in `SCENES` and the marketing copy in `COPY[language][scene]`, so adding a language means adding one `COPY` entry plus one `locale_for()` case. Background gradients are built from `make_app_icon.py`'s `LIGHT` palette, imported at runtime so the screenshots and the icon can't drift apart.
  - Two guards fail the build rather than shipping a bad frame: `check_contrast` enforces WCAG ratios of the caption against its background, and `fitted_font` shrinks any line wider than `TEXT_SAFE_WIDTH` (German and Finnish need it) before a caption can collide with the device frame.
  - SF Pro has no CJK glyphs, so `font()` swaps in Hiragino Sans GB for `zh-*` — and unlike the SF Pro variable font, that face must not be given `set_variation_by_name`.

- **Place search**
  - `PlaceSearch` opens `places.sqlite` read-only and runs a single prepared statement (`searchSQL`) that matches, scores, deduplicates and hydrates results in one pass via `place_fts` (FTS5), `alias`, `place` and `municipality`.
  - `ftsExpression(for:)` tokenizes free text into terms; scoring favors exact-length matches, lower `p.rank`, primary names over aliases, and demotes less map-relevant `PlaceKind`s.
  - Coordinates are stored as scaled integers (`coordinateScale = 100_000`) to keep the `place` table compact.
  - `PlaceSearchModel` debounces input (150 ms) on a background queue. `PlaceSearchSheet` renders results and feeds a selected `PlaceResult` back to `ContentView`.

- **Saved routes**
  - A saved route is one JSON file per route (`SavedRoute`, id/createdAt/coordinates/strokeSizes/schemaVersion) under `Application Support/Routes`.
  - `SavedRouteStore` (and `SavedPinStore`, below) is a thin wrapper over the generic `DocumentDirectoryStore<Item>`, which owns the shared local/iCloud logic; `SavedRouteStore` starts pointed at the local directory so the app works fully offline from first launch, then `syncWithiCloudIfAvailable()` (called once from `SavedRoutesModel.init` in a background `Task`) resolves the ubiquity container off the main thread and, the first time it succeeds, migrates existing local files over (copy-then-delete-on-success, so a failure mid-migration can't lose a route) before repointing `directory` at it. `startObservingRemoteChanges` uses an `NSMetadataQuery` to refresh the list.
  - `save`/`delete` are wrapped in `NSFileCoordinator` so they never race the iCloud daemon; `load`'s directory listing is plain `FileManager` since a miss just self-corrects on the next `NSMetadataQuery` update.
  - iCloud Documents requires a signed-in iCloud account, without it, `syncWithiCloudIfAvailable()` is a no-op and the store just keeps using the local directory.
  - Loading a saved route is always replace, never merge, with the sheet warning first if the current route is unsaved.

- **Featured (suggested) routes**
  - Eight well known trails ship in the bundle as `resources/featured-routes.json` so the "Saved routes" sheet is never empty on a fresh install.
  - They are **read-only and never enter `SavedRouteStore`** — no iCloud sync, no rename or delete, and a bad geometry is fixed by shipping a new build rather than migrating anyone's files. Selecting one goes through the same `measurement.load` / `elevation.load` path as a saved route, so it can be edited and then saved as the user's own; `SavedRoute.id` is derived deterministically from the catalogue id so saving the same one twice can't collide.

- **Saved pins**  - A saved pin (`SavedPin`: id/createdAt/coordinate/name/subtitle/schemaVersion) is created either by long-pressing the map (name defaults to nil, so `displayName` falls back to a formatted date) or by tapping the bookmark `rightCalloutAccessoryView` on a search-result marker (named after the `PlaceResult`). Both go through `SavedPinStore`, the `DocumentDirectoryStore<SavedPin>` wrapper, under `Application Support/Pins` — its own iCloud migration `UserDefaults` key keeps pin migration independent of route migration.
  - `MapView.Coordinator` owns a `UILongPressGestureRecognizer` added directly to the `MKMapView` (not the measurement capture view), disabled whenever `isMeasuring` or `isRegionPreviewVisible` is true so it never competes with drawing or the offline-region picker.
  - Pins are managed entirely on the map, not in the "Saved" sheet (that sheet is routes-only): `SavedPinAnnotation` has no title/subtitle/callout at all — tapping one directly fires `mapView(_:didSelect:)`, which opens `PinDetailSheet` (a small `.presentationDetents([.height(260)])` sheet with Rename + destructive Delete) and immediately deselects, so no callout ever flashes on screen. `SavedPinsModel` (load/save/rename/delete) still backs this, it's just driven from the map instead of a list.

## Build & test
- Xcode project: `fjallkartan.xcodeproj`, scheme `fjallkartan`.
- The project uses filesystem-synced groups (`PBXFileSystemSynchronizedRootGroup`), so new source files added under `fjallkartan/` or `fjallkartanTests/` are picked up automatically — no `project.pbxproj` edit needed.
- Tests: `xcodebuild -scheme fjallkartan -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test` (Swift Testing).
