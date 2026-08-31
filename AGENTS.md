# AGENTS.md

## Project overview
iOS app (SwiftUI + MapLibre) that displays topographic map tiles from Kartverket (Norway), Lantmäteriet (Sweden), and Maanmittauslaitos (the Finnish border sliver near Treriksröset).

## Android sibling repository

- The Android port lives in the neighboring `../fjallkartan-android` repository. Its own `AGENTS.md` documents the Compose/MapLibre architecture, build commands, release configuration, and Google Play delivery.
- Treat this iOS repository as the source of truth for shared product content: `Localizable.xcstrings`, `fastlane/metadata/`, `resources/featured-routes.json`, `places.sqlite`, legend symbols, and the app-icon artwork.
- Android import tools intentionally read this repository through the sibling path:
  - `../fjallkartan-android/tools/import_localizations.py`
  - `../fjallkartan-android/tools/import_play_metadata.py`
  - `../fjallkartan-android/tools/import_legend_assets.py`
  - `../fjallkartan-android/tools/import_app_icon.py`
- When changing shared schemas, tile settings, review thresholds, onboarding/legend copy, featured routes, or map behavior, check whether the Android implementation needs the same change. Preserve saved-route and saved-pin JSON compatibility across both apps.
- Changes to one repository must be committed in that repository only. Never include sibling-repository files in an iOS commit, and never push either repository without explicit user authorization.

## Key files
| File | Purpose |
|---|---|
| `fjallkartan/fjallkartanApp.swift` | App entry point |
| `fjallkartan/ContentView.swift` | Root SwiftUI view; hosts `MapView` plus the scale bar, copyright notice and measurement overlays. |
| `fjallkartan/MapView.swift` | `UIViewRepresentable` wrapping `MLNMapView`: builds the raster style (base layers + slope), owns the measurement-capture view (`MapLibreMeasureCaptureView`), route/endpoint/distance-marker `MLNShapeSource`s, search/pin annotations, offline-region preview border, and user-location tracking. |
| `fjallkartan/DebugView.swift` | `DebugSheet`, opened by long-pressing the version row in `AboutSheet`: toggles the centre-tile `z/x/y` badge, exports unified logs, and clears MapLibre's ambient tile cache. |
| `fjallkartan/LogExporter.swift` | Exports the current process's app and MapLibre unified-log entries from the last 24 hours to a shareable temporary `.log` file. |
| `fjallkartan/MapLibreLoggingBridge.swift` | Routes MapLibre warnings/errors through unified logging so `LogExporter` can include tile, network, and style failures. |
| `fjallkartan/MetricKitReporter.swift` | Registers for MetricKit payloads at launch and records metric, crash, and hang summaries in unified logging. |
| `fjallkartan/DistanceMeasurement.swift` | `@Observable` model holding the traced route and its geodesic length, plus `LineSimplifier` (Ramer–Douglas–Peucker). |
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
| `fjallkartan/ElevationService.swift` | Samples terrain height from the prebaked z12 elevation tiles: network fetch, RGBA→metres decode, in-memory per-tile cache and in-flight dedupe, plus an offline disk cache. |
| `fjallkartan/ElevationProfile.swift` | `@Observable` profile of the measured route — fixed-spacing resampling, ascent/descent with hysteresis, coverage, and a `needsConnection` flag for the offline case. |
| `fjallkartan/ElevationProfileView.swift` | `ElevationProfileSheet`: Swift Charts terrain profile opened from the distance readout. |
| `fjallkartan/TilePyramid.swift` | Pure functions sizing the offline download estimate for the fixed z7–z14 `MLNTilePyramidOfflineRegion` range. |
| `fjallkartan/RemoteSettings.swift` | Remotely configurable tile URL templates (`TileSettings`: hosted Sweden/Finland base map, Kartverket, Norwegian slope, Swedish slope, elevation), fetched from `settings.json` with built-in fallbacks. |
| `fjallkartan/TileServer.swift` | One case per tile source; zoom limits, offline min/max zoom and URL construction shared by the style builder, the offline size estimate and `ElevationService`. |
| `fjallkartan/KartverketTileProxy.swift` | Loopback-only HTTP server (`Network.framework`) that fronts Kartverket tiles for MapLibre, rewriting the cream no-data fill (nested `NoDataFill` enum) for tiles at z≥15 before MapLibre's ambient cache stores the response. |
| `fjallkartan/LegendCatalog.swift` | All legend entries — grouped into sections. |
| `fjallkartan/LegendView.swift` | `LegendCountry` and `LegendSheet`; renders the bundled per-country legend PDFs (`legend_no` / `legend_se`) via PDFKit. |
| `fjallkartan/AboutView.swift` | `AboutButton` and `AboutSheet`: data-source attribution (Kartverket, Lantmäteriet, NVE) plus privacy-policy and support links, and the row that reopens the get-started guide. |
| `fjallkartan/OnboardingView.swift` | `OnboardingPage`/`OnboardingNote` content plus `OnboardingSheet`, the paged get-started guide opened on demand from About. |
| `fjallkartan/GuideTipView.swift` | `GuideTip` (one-time contextual hints, one `UserDefaults` key each) and the `GuideTipBadge` that renders them over the map. |
| `fjallkartan/ReviewPrompter.swift` | Throttling logic deciding when to ask for an App Store review. |
| `fjallkartan/NetworkCheck.swift` | One-shot `NWPathMonitor` connectivity check (no persistent monitor); used to postpone the review prompt while offline, and to tell "no connection" apart from "outside coverage" in the elevation profile. |
| `fjallkartan/OfflineRegionsView.swift` | `OfflineRegionsModel` (thin wrapper over `MLNOfflineStorage`/`MLNOfflinePack`, plus elevation-tile download) and `OfflineRegionsSheet` UI for starting/managing offline regions. |
| `fjallkartan/InfoPlist.xcstrings` | Localized `Info.plist` values: `CFBundleDisplayName` (home-screen name, translated for nb/da/fi) and `NSLocationWhenInUseUsageDescription`. |
| `fjallkartan/Localizable.xcstrings` | All in-app UI strings. |
| `fjallkartan/PrivacyInfo.xcprivacy` | Privacy manifest: no tracking, no collected data, and the required-reason API declarations. |
| `fjallkartan/fjallkartan.entitlements` | iCloud Documents entitlements that `DocumentDirectoryStore` needs for its ubiquity container. |
| `fastlane/metadata/` | **Source of truth for the App Store copy**, checked in and hand-edited: one directory per App Store locale holding name/subtitle/promotional text/keywords/description plus the support and privacy URLs, and `copyright.txt` and the two category files at the top level. |
| `fastlane/Fastfile` | `check_metadata` / `metadata` / `screenshots` / `verify_screenshots` / `store` / `submit` / `pull` lanes, authenticated with an App Store Connect API key. `check_metadata!` enforces Apple's per-field character limits. `submit` attaches the latest processed build (e.g. from Xcode Cloud) to the editable version and files the review submission. |
| `docs/privacy.html`, `docs/support.html` | GitHub Pages pages linked from `AboutSheet` and App Store. |
| `tools/extract_legend_symbols.py` | Clips the 27 Swedish legend symbols out of `tools/legend_se_source.pdf` into vector assets (`preview` → `verify` → `assets`); `verify` diffs each against an embed-and-crop oracle. |
| `tools/build_no_legend_symbols.py` | Draws the 16 Norwegian legend symbols from Kartverket's `Skjermkartografi.otf` using the glyph codes, colours and dash patterns in their published specification (`fetch` → `preview` → `assets`). |
| `tools/fill_legend_translations.py` | Fills the legend strings in `Localizable.xcstrings` from one table, so the 43 symbol names stay consistent across the 10 translations. |
| `tools/build_places_db.py` | Builds `places.sqlite` (place, alias, municipality tables + `place_fts` FTS5 index) bundled with the app. |
| `tools/compose_screenshots.py` | Composes captioned App Store screenshots straight into `fastlane/screenshots/<App Store locale>/`, ready for deliver. Owns the repo-language → App Store-locale mapping (`DELIVER_LOCALES`). |
| `tools/make_app_icon.py` | Regenerates the app icon. |
| `tools/build_elevation_tiles.py` | Builds the z12 elevation tiles for both countries and uploads them to R2 (`tiles` → `verify` → `upload`). |
| `tools/build_sweden_slope_tiles.py` | Derives the Swedish slope tiles from Lantmäteriet elevation data and uploads them to R2 (`fetch` → `tiles` → `verify` → `upload`). |
| `tools/upload_gpkg_tiles_to_r2.py` | Streams selected zooms or explicit tiles from Lantmäteriet's GeoPackage to the hosted `z/y/x` R2 base-map pyramid, with dry-run and retry support. |
| `tools/build_finland_gap_tiles.py` | Fetches MML tiles, composites the Finnish Treriksröset gap into the hosted Lantmäteriet pyramid, renders verification previews, and uploads only after explicit confirmation. |
| `tools/serve_finland_gap_local.py` | Local test proxy that serves composited Finland-gap tiles and falls back to/caches the production base map for all other requests. |

## Architecture notes

- **`MapView`**
  - Route/endpoint/distance-marker rendering uses `MLNShapeSource` + `MLNLineStyleLayer`/`MLNCircleStyleLayer`, added once in `mapView(_:didFinishLoading:)` and updated by replacing the source's `shape` — not `MKOverlayRenderer`.
  - `MapLibreMeasureCaptureView` is a same-size subview added on top of the map. MapLibre's own pan/pinch/rotate gesture recognizers live on the map view itself, an *ancestor* of the capture view, so they still see every touch unless explicitly disabled — `setMeasuring(_:on:)` toggles `map.isScrollEnabled`/`isZoomEnabled`/`isRotateEnabled` off and the capture view's `isUserInteractionEnabled` on, together, whenever measuring starts or stops. The capture view brings in its own two-finger pinch/pan recognizers so panning and zooming still work one-handed while drawing.
  - `mapViewRegionIsChanging`/`regionDidChangeAnimated` both funnel into one `updateRegion(for:)` that recomputes `metersPerPoint`/`visibleMapRect`/`zoomLevel` and only writes back to the `@Binding`s that actually changed — MapLibre's region-changing delegate callback fires far more often than MapKit's did, so an unconditional write would re-render the scale bar every frame.
  - The hidden debug overlay shows the Web Mercator tile containing the map centre as `z/x/y`; `updateRegion(for:)` derives it with `TilePyramid.tileCoordinate(for:z:)`.
  - Search results, saved pins and route-distance markers are all `MLNAnnotation`s with their own `MLNAnnotationView` subclasses (`SearchResultMarkerView`, `SavedPinMarkerView`, `RouteDistanceMarkerView`) rather than `MKAnnotationView`; only `SearchResultAnnotation` gets a callout (`annotationCanShowCallout`), with the bookmark/✗ accessories reproduced via `leftCalloutAccessoryViewFor`/`rightCalloutAccessoryViewFor`.
  - Tapping a saved pin goes through `mapView(_:didSelect:)`, which immediately deselects and opens `PinDetailSheet` — same behaviour as the MapKit version, just on the MapLibre delegate.
  - Location tracking calls `locationManager.requestWhenInUseAuthorization()` lazily, only when the user first taps the tracking button (`setTrackingMode`), and defers actually engaging `.follow` until `locationManagerDidChangeAuthorization` reports authorized.


- **Remote settings**
  - `RemoteSettings.shared.refresh()` runs on scene activation and fetches `https://tiles.wallman.dev/settings.json` at most once per 6 h, so a provider that changes its URL can be followed without an app update.
  - `RemoteSettings.builtIn` holds the original hardcoded templates and is always a working configuration. An accepted payload is persisted as raw JSON in `UserDefaults`, so later launches start from the last known-good value.
  - The built-in `lantmaterietUrl` points at the app's R2-backed `tiles.wallman.dev/v1` pyramid rather than Lantmäteriet directly. That hosted pyramid contains Lantmäteriet's base tiles plus the composited MML coverage described below.

- **Finnish gap near Treriksröset**
  - Lantmäteriet's map ends at Sweden's border, leaving the Finnish Käsivarsi/Kilpisjärvi sliver blank between Norway and Sweden. `tools/build_finland_gap_tiles.py` fills only that gap with MML's `maastokartta` WMTS tiles.
  - The production composite uses only z11–z16. Its WGS84 fetch bounding box is `20.412598,68.196052,23.977661,69.373541` (`min_lon,min_lat,max_lon,max_lat`).
  - Both providers encode no-data as opaque pure white rather than transparency. The composite keeps the Swedish pixel unless it is white, then substitutes a non-white Finnish pixel, preventing either provider's blank fill from covering real map content at the seam.
  - The workflow is deliberately staged: `fetch` caches MML source tiles, `composite` writes only changed tiles under `out/finland-gap`, `verify` creates side-by-side previews, and `upload --confirm` overwrites the corresponding live R2 objects.
  - `tools/serve_finland_gap_local.py` supports manual Simulator/device testing before upload by overlaying those local composites on the otherwise unchanged production tile pyramid.

- **Slope layer**
  - Two raster sources/layers (`norway-slope`, `sweden-slope`) in the same style document, both painted at `raster-opacity: 0.6`, replacing the old per-country `SlopeTileOverlay` (`MKTileOverlay`) instances. `MapView.Coordinator.setSlopeVisible(_:)` toggles `MLNRasterStyleLayer.isVisible` on both rather than adding/removing overlays. Norway serves NVE's finished `Bratthet_med_utlop_2024` pictures (z5–16); Sweden has no such service, so we render our own (z5–13) — each source still carries its own `TileServer.sourceMaximumZ` as `maxzoom`, so MapLibre's own overzoom handles anything deeper.
  - Both tilesets are sparse, so 404s are the normal case there.
  - The Swedish tiles are built offline by `tools/build_sweden_slope_tiles.py` and match NVE's palette exactly, minus the runout blues (Sweden publishes no runout model) and minus the green <30° band.
  - Slope is computed with Horn 3×3 in EPSG:3006 **before** warping to Web Mercator — Mercator inflates distances by 1/cos(lat) (~2.2× at 63°N), which would flatten every slope. The warp is nearest-neighbour because the pixel values are class labels, not quantities. Only z13 is computed from elevation; lower zooms are max-pooled from their four children so a steep face stays visible as it shrinks below a pixel.
  - Agreement with NVE across the border is 96.6 % exact / 99.5 % within one class over 1,395,357 pixels sampled from 60 border tiles.
  - The tiles are hosted on Cloudflare R2 (bucket `tiles`, prefix `slope/v1`), fronted by `tiles.wallman.dev`.

- **Kartverket cream fill at the border**
  - From ~z15, Kartverket's opaque cream no-data fill (~255,255,230) covers Lantmäteriet on the Swedish side of the border instead of letting it show through, so the map used to go cream above z15 near the border in Sweden.
  - Fixed by `KartverketTileProxy`: a loopback-only `NWListener` HTTP server that the "kartverket" raster source's tile URL points at instead of the real host. Rewritten before MapLibre sees it, and MapLibre caches the rewritten tile.
  - `KartverketTileProxy.NoDataFill.rewritten(_:)` does the actual rewrite. Only applied for `z >= 15` (`KartverketTileProxy.rewriteMinimumZoom`) since the fill never appears below that — tiles below z15 are proxied unmodified, skipping the decode/pixel-scan pass for the vast majority of requests.
  - Kartverket 429/5xx responses (and connection failures) are forwarded to MapLibre as their real status rather than a 404, so they read as transient and retryable.
  - The proxy uses a fixed loopback port (`8062`). Because iOS suspends the listener in the background, `fjallkartanApp` recreates it when the scene returns from `.background` to `.active`.

- **Diagnostics**
  - `fjallkartanApp.init` starts `MetricKitReporter` and `MapLibreLoggingBridge` before `ContentView` is created.
  - `MapLibreLoggingBridge` installs MapLibre's global logging handler at warning level and writes messages under the `org.maplibre` subsystem; app components use the bundle identifier subsystem.
  - `LogExporter` reads both subsystems from the current process's unified log and writes a timestamped temporary file. The hidden `DebugSheet` presents the system share sheet for that file.
  - The same debug sheet can clear `MLNOfflineStorage.shared`'s ambient cache. This does not delete user-created offline packs.

- **Elevation**
  - Elevation comes from prebaked XYZ tiles (`https://tiles.wallman.dev/elevation/v1/{z}/{y}/{x}.png`).
  - The tiles are **data, not pictures**, and are never added to the map: each pixel carries `metres + 32768` as `R = value >> 8`, `G = value & 0xFF`, `B = 0`, with a fully transparent pixel meaning no data. The offset puts every Nordic height in the R ≈ 128–137 band, which is why an elevation tile looks like flat dark red with fine noise when opened in an image viewer.
  - 1 m precision is deliberate: decimetres would put noise in the low byte and roughly triple the PNG size for no gain.
  - Published at **z12 only** (~18 m per pixel at 62°N), which matches the 25 m spacing routes are sampled at. z13 was built and measured: it is ~60% better per point but changes ascent totals by well under 1%.
  - Norway is exported from Kartverket's `NHM_DTM_25833` ImageServer (the same source behind the Geonorge point API, which the build script uses only as a verification oracle); Sweden is warped from the local DEM mosaic shared with the slope build. Both verified against their official point service: median error 0.60 m (NO) and 0.33 m (SE). Border tiles merge the two sources, since neither service alone covers a tile on the line.
  - `ElevationProfile` resamples at a fixed 25 m so totals don't depend on how fast the route was traced, and applies 4 m hysteresis so metre-level model noise doesn't accumulate into phantom climb (measured: ~2.5% of the total). A no-data gap **breaks** the run rather than being bridged, so the unknown step across it is never invented.

- **Offline map regions**
  - Built on `MLNOfflinePack`/`MLNOfflineStorage` via `MLNTilePyramidOfflineRegion`. `OfflineRegionsModel.startDownload(name:rect:)` creates a region for the fixed `TilePyramid.minZoom...maxZoom` (z7–z14) range using the same style URL the map uses, JSON-encodes a small `RegionContext` (id/name/createdAt) into the pack's opaque `context` since a pack has no name/date of its own, and calls `resume()` immediately.
  - Progress/completion/error come from `NotificationCenter` (`.MLNOfflinePackProgressChanged`, `.MLNOfflinePackError`), not a custom downloader; `OfflineRegionsModel` decodes each pack's `context` back into a `RegionSummary` for the list. `pause`/`resume`/`delete` map straight onto `MLNOfflinePack.suspend()`/`resume()`/`MLNOfflineStorage.removePack(_:)`.
  - Elevation tiles are never part of the style, so the pack never downloads them; `OfflineRegionsModel` runs its own `ElevationService.prefetchTiles(_:onProgress:)` in parallel for the same rect, and merges its `(tilesDone, tilesTotal, bytesDone)` into the pack's own progress for one combined `RegionSummary`. Since the download `Task` doesn't survive a relaunch, `refresh()` recomputes each pack's elevation tile keys from its stored bounds and resumes any that are incomplete and not paused.
  - `TilePyramid` is now just the download-size *estimate*: `estimate(rect:)` still uses `TileServer.covers(zoom:)` and per-zoom measured-bytes tables (base map, slope, elevation-at-its-single-zoom) to size the region before it's downloaded, plus `availableCapacityBytes` for the disk-space guard and `maxDownloadBytes` (~1.5 GB) as a hard refusal. This estimate is **known to be inaccurate**. Revisiting it means empirically-measured multipliers per zoom range.
  - `OfflineRegionsSheet`'s "current view" download area is an inset of `MapView`'s `visibleMapRect`; the same rect is drawn as a dashed `RegionPreviewBorderView` on the map while the sheet is open.

- **Distance measurement**
  - While measuring, `MapLibreMeasureCaptureView` becomes interactive and swallows every touch (see `MapView` above), which is what stops MapLibre's own pan/zoom recognisers from competing with drawing. Live feedback is drawn in screen space (`CAShapeLayer`) so the map is not re-rendered mid-drag.
  - On touch-up the stroke is simplified in screen space, converted to coordinates and appended to `DistanceMeasurement`; consecutive strokes are joined by a straight connector so the user can pan between them.
  - Distances are geodesic (`CLLocation.distance(from:)`). A Mercator-space measurement would overstate by ~2.7x at 68°N.
  - `MapView` rebuilds the route `MLNShapeSource`'s shape only when `DistanceMeasurement.version` changes. `ContentView` passes `isMeasuring` / `routeVersion` as plain values so Observation triggers `updateUIView`.


- **Get started guide**
  - Two layers. `OnboardingSheet` is the paged tour, opened on demand from `AboutSheet`; do not present the full guide automatically at app launch. `GuideTip` is the contextual layer: a hint shown the first time a mode is actually entered, which is the only moment a gesture can be acted on.
  - Both cover the interactions that are invisible in the UI: two-finger pan/pinch while drawing, tapping the distance readout for the profile, long-press to drop a pin or rename a saved route, the search callout's bookmark/✗, and where a saved route reappears. The tile-metrics debug sheet is deliberately left out.
  - `ContentView` owns tip arbitration: `updateVisibleTip()` shows the highest-priority unseen tip whose condition holds, marks it seen **on display** (an ignored tip has had its chance), and retires it when the condition ends or after 7 s. Only one tip is ever on screen, so placement is a single overlay.
  - Guide strings are `LocalizedStringResource` rather than `LocalizedStringKey` so `OnboardingGuideTests` can assert every string is in the catalog (a missing entry resolves back to its own key) and every SF Symbol exists — both fail silently at runtime otherwise.

- **App Store review prompt**
  - Two conditions must line up: **≥3 app opens** (engagement) and a success — either an offline region download reaching `.completed`, or **3 finished measurements** of ≥500 m (`ReviewPrompter.minimumMeasurementMeters`). Only a success arms the prompt; `noteBecameActive()` just accrues opens, so crossing the open threshold alone never triggers anything.
  - A measurement counts when `isMeasuring` goes false and the route grew during that session (`ContentView` snapshots `measurement.version` at session start), so toggling the ruler on and off doesn't inflate the count.
  - Throttled to one prompt per app version with a 120-day floor between prompts. `ReviewPrompter` only sets `pendingToken`; `ContentView` fires `@Environment(\.requestReview)` after a 3 s pause once no sheet, region picker or measurement is active.
  - `OfflineRegionsModel.onRegionDownloadCompleted` is injectable so tests don't touch the shared prompter's `UserDefaults`.

- **App Store screenshots**
  - `compose_screenshots.py` keeps geometry and colours in `SCENES` and the marketing copy in `COPY[language][scene]`, so adding a language means adding one `COPY` entry plus one `locale_for()` case. Background gradients are built from `make_app_icon.py`'s `LIGHT` palette, imported at runtime so the screenshots and the icon can't drift apart.
  - Two guards fail the build rather than shipping a bad frame: `check_contrast` enforces WCAG ratios of the caption against its background, and `fitted_font` shrinks any line wider than `TEXT_SAFE_WIDTH` (German and Finnish need it) before a caption can collide with the device frame.
  - SF Pro has no CJK glyphs, so `font()` swaps in Hiragino Sans GB for `zh-*` — and unlike the SF Pro variable font, that face must not be given `set_variation_by_name`.

- **App Store delivery**
  - fastlane/metadata/` is checked in and hand-edited — it is the source of truth, not a build artefact.
  - Because the tree is committed, `fastlane ios pull` overwrites it in place and drift shows up as `git diff`.
  - Metadata edits are only accepted while the version is in *Prepare for Submission*; every other state answers 409.
  - Everything authenticates with an App Store Connect API key, except two one-time actions that Apple offers no key-based API for: the **App Privacy** questionnaire ("Data Not Collected") and creating the app record. Both stay manual by choice, rather than downgrading the whole pipeline to Apple ID + 2FA.
  - Release notes are per version, so `release_notes.txt` is simply absent from the tree until a release has notes to show; deliver leaves the existing What's New untouched when the file is missing. Apple ignores the field for a first submission.
  - **deliver's screenshot upload is not idempotent, so `verify_screenshots!` runs after every screenshot upload.** deliver decides whether a file arrived by looking for its checksum in `source_file_checksum` on App Store Connect, but Apple only fills that in once processing finishes — so anything still processing reads as *missing*, and deliver deletes the incomplete uploads and re-sends the whole set, appending a second copy of everything that did finish in time. One `fastlane ios store` run left 38 surplus images, unevenly spread (sets held 4 to 10 for 4 local files, `it` iPad hitting deliver's 10-per-set cap). The repair keeps the *first* copy of each filename, which is both the original upload and the one in the right display position.

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

- **Saved pins**
  - A saved pin (`SavedPin`: id/createdAt/coordinate/name/subtitle/schemaVersion) is created either by long-pressing the map (name defaults to nil, so `displayName` falls back to a formatted date) or by tapping the bookmark `rightCalloutAccessoryViewFor` on a search-result marker (named after the `PlaceResult`). Both go through `SavedPinStore`, the `DocumentDirectoryStore<SavedPin>` wrapper, under `Application Support/Pins` — its own iCloud migration `UserDefaults` key keeps pin migration independent of route migration.
  - `MapView.Coordinator` owns a `UILongPressGestureRecognizer` added directly to the `MLNMapView` (not the measurement capture view), disabled whenever `isMeasuring` or `isRegionPreviewVisible` is true (`setLongPressEnabled(_:)`) so it never competes with drawing or the offline-region picker.
  - Pins are managed entirely on the map, not in the "Saved" sheet (that sheet is routes-only): `SavedPinMapAnnotation` has no title/subtitle/callout at all — tapping one directly fires `mapView(_:didSelect:)`, which opens `PinDetailSheet` (a small `.presentationDetents([.height(260)])` sheet with Rename + destructive Delete) and immediately deselects, so no callout ever flashes on screen. `SavedPinsModel` (load/save/rename/delete) still backs this, it's just driven from the map instead of a list.

- **Actor isolation**
  - The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (and `SWIFT_APPROACHABLE_CONCURRENCY`), so **every type is implicitly `@MainActor` unless it says otherwise**. That is why `TileServer`, `ElevationService`, `TileSettings`, `Coord` and friends are explicitly marked `nonisolated`.
  - The trap: implicit isolation also covers a type's *synthesized conformances*. A main-actor-isolated `Hashable`/`Equatable` can't be used from a nonisolated context, and Swift Testing's `#expect` macro expands into exactly that — so comparing such a value in a test produces `main actor-isolated conformance of 'X' to 'Equatable' cannot be used in nonisolated context; this is an error in the Swift 6 language mode`.
  - So: any value type that is compared in tests, persisted, or otherwise touched off the main thread must be declared `nonisolated`. Reach for that rather than annotating the test, and treat the warning as a real isolation bug — it becomes an error under Swift 6.
  - The same applies to overridden UIKit/MapLibre members: any main-actor-isolated method a test overrides or calls directly (e.g. `MLNMapViewDelegate` callbacks) needs its test helper marked `@MainActor` too.

## Build & test
- Xcode project: `fjallkartan.xcodeproj`, scheme `fjallkartan`.
- The project uses filesystem-synced groups (`PBXFileSystemSynchronizedRootGroup`), so new source files added under `fjallkartan/` or `fjallkartanTests/` are picked up automatically — no `project.pbxproj` edit needed.
- Tests: `xcodebuild -scheme fjallkartan -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test` (Swift Testing).
