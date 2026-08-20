import SwiftUI
import MapLibre

// Throwaway POC to compare browsing feel against the MapKit-based MapView.
// Lantmäteriet + Kartverket raster tiles, stacked like the production
// MapView (Lantmäteriet first as the opaque base, Kartverket second on top
// for the border) — but with no no-data-to-transparent pixel rewrite, so
// Kartverket's opaque cream fill (from ~z15) will cover Lantmäteriet there
// instead of showing through. No measurement/elevation.
// Delete once the comparison is done.
struct MapLibrePOCView: View {
    @State private var trackingMode: MLNUserTrackingMode = .none
    @State private var slopeVisible = false
    @State private var download = OfflineDownloadState()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MapLibreRasterMap(trackingMode: $trackingMode, slopeVisible: $slopeVisible, download: download)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                slopeToggleButton
                userLocationButton
                downloadButton
            }
            .padding()
        }
        .alert("Offline download failed", isPresented: download.errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(download.errorMessage ?? "")
        }
    }

    private var userLocationButton: some View {
        Button {
            trackingMode = nextTrackingMode(after: trackingMode)
        } label: {
            Image(systemName: trackingButtonSymbol(for: trackingMode))
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
        }
    }

    private var slopeToggleButton: some View {
        Button {
            slopeVisible.toggle()
        } label: {
            Image(systemName: "triangle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(slopeVisible ? Color.accentColor : Color.primary)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
        }
    }

    private var downloadButton: some View {
        Button {
            download.start()
        } label: {
            Group {
                if download.isDownloading {
                    ProgressView(value: download.progress)
                        .progressViewStyle(.circular)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18, weight: .medium))
                }
            }
            .frame(width: 44, height: 44)
            .background(.thinMaterial, in: Circle())
        }
        .disabled(download.isDownloading)
    }

    private func nextTrackingMode(after mode: MLNUserTrackingMode) -> MLNUserTrackingMode {
        switch mode {
        case .none: return .follow
        case .follow: return .followWithHeading
        default: return .none
        }
    }

    private func trackingButtonSymbol(for mode: MLNUserTrackingMode) -> String {
        switch mode {
        case .none: return "location"
        case .followWithHeading: return "location.north.line.fill"
        default: return "location.fill"
        }
    }
}

@Observable
final class OfflineDownloadState: NSObject {
    var isDownloading = false
    var progress: Double = 0
    var errorMessage: String?

    var errorBinding: Binding<Bool> {
        Binding(
            get: { self.errorMessage != nil },
            set: { if !$0 { self.errorMessage = nil } }
        )
    }

    private weak var mapView: MLNMapView?
    private var pack: MLNOfflinePack?

    func attach(mapView: MLNMapView) {
        self.mapView = mapView
    }

    func start() {
        guard !isDownloading, let mapView, let styleURL = mapView.styleURL else { return }

        // A handful of zoom levels around the current one: enough to keep
        // panning/zooming around the visible area working offline without
        // downloading the whole world at max depth.
        let currentZoom = mapView.zoomLevel
        let fromZoom = max(0, currentZoom - 1)
        let toZoom = min(16, currentZoom + 3)

        let region = MLNTilePyramidOfflineRegion(
            styleURL: styleURL,
            bounds: mapView.visibleCoordinateBounds,
            fromZoomLevel: fromZoom,
            toZoomLevel: toZoom
        )
        let context = Data("current-view".utf8)

        isDownloading = true
        progress = 0
        NotificationCenter.default.addObserver(
            self, selector: #selector(progressChanged(_:)),
            name: NSNotification.Name.MLNOfflinePackProgressChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(packErrored(_:)),
            name: NSNotification.Name.MLNOfflinePackError, object: nil
        )

        MLNOfflineStorage.shared.addPack(for: region, withContext: context) { [weak self] pack, error in
            guard let self else { return }
            if let error {
                self.finish(errorMessage: error.localizedDescription)
                return
            }
            self.pack = pack
            pack?.resume()
        }
    }

    @objc private func progressChanged(_ notification: Notification) {
        guard let pack = notification.object as? MLNOfflinePack, pack === self.pack else { return }
        let progress = pack.progress
        let expected = max(progress.countOfResourcesExpected, 1)
        self.progress = Double(progress.countOfResourcesCompleted) / Double(expected)

        if pack.state == .complete {
            finish(errorMessage: nil)
        }
    }

    @objc private func packErrored(_ notification: Notification) {
        guard let pack = notification.object as? MLNOfflinePack, pack === self.pack else { return }
        let error = notification.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
        finish(errorMessage: error?.localizedDescription ?? "Unknown error")
    }

    private func finish(errorMessage: String?) {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.MLNOfflinePackProgressChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.MLNOfflinePackError, object: nil)
        isDownloading = false
        progress = 0
        self.errorMessage = errorMessage
    }
}

private struct MapLibreRasterMap: UIViewRepresentable {
    private static let lantmaterietTileURL = "https://tiles.wallman.dev/v1/{z}/{y}/{x}.png"
    private static let kartverketTileURL =
        "https://cache.kartverket.no/v1/wmts/1.0.0/topo/default/webmercator/{z}/{y}/{x}.png"
    private static let norwaySlopeTileURL = "https://gis3.nve.no/arcgis/rest/services/wmts/Bratthet_med_utlop_2024/MapServer/tile/{z}/{y}/{x}"
    private static let swedenSlopeTileURL = "https://tiles.wallman.dev/slope/v1/{z}/{y}/{x}.png"

    private static let styleURL: URL = {
        let json = """
        {
          "version": 8,
          "sources": {
            "lantmateriet": {
              "type": "raster",
              "tiles": ["\(lantmaterietTileURL)"],
              "tileSize": 128,
              "minzoom": 0,
              "maxzoom": 16
            },
            "kartverket": {
              "type": "raster",
              "tiles": ["\(kartverketTileURL)"],
              "tileSize": 128,
              "minzoom": 0,
              "maxzoom": 18
            },
            "norway-slope": {
              "type": "raster",
              "tiles": ["\(norwaySlopeTileURL)"],
              "tileSize": 128,
              "minzoom": 5,
              "maxzoom": 18
            },
            "sweden-slope": {
              "type": "raster",
              "tiles": ["\(swedenSlopeTileURL)"],
              "tileSize": 128,
              "minzoom": 5,
              "maxzoom": 13
            }
          },
          "layers": [
            {"id": "lantmateriet-layer", "type": "raster", "source": "lantmateriet"},
            {"id": "kartverket-layer", "type": "raster", "source": "kartverket"},
            {"id": "norway-slope-layer", "type": "raster", "source": "norway-slope", "paint": {"raster-opacity": 0.6}},
            {"id": "sweden-slope-layer", "type": "raster", "source": "sweden-slope", "paint": {"raster-opacity": 0.6}}
          ]
        }
        """
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("maplibre-poc-style.json")
        try? json.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }()

    @Binding var trackingMode: MLNUserTrackingMode
    @Binding var slopeVisible: Bool
    let download: OfflineDownloadState

    func makeCoordinator() -> Coordinator { Coordinator(trackingMode: $trackingMode, slopeVisible: $slopeVisible) }

    func makeUIView(context: Context) -> MLNMapView {
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(500 * 1024 * 1024) { _ in } // 500mb

        let mapView = MLNMapView(frame: .zero, styleURL: Self.styleURL)
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.showsUserLocation = true
        mapView.setCenter(
            CLLocationCoordinate2D(latitude: 62.0, longitude: 15.0),
            zoomLevel: 5,
            animated: false
        )
        download.attach(mapView: mapView)
        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        // Only push down when the button (not the map itself, e.g. via a
        // user pan) caused the change, to avoid fighting MapLibre's own
        // reset-to-.none-on-pan behaviour.
        if uiView.userTrackingMode != trackingMode {
            uiView.setUserTrackingMode(trackingMode, animated: true, completionHandler: nil)
        }
        context.coordinator.setSlopeVisible(slopeVisible)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        @Binding var trackingMode: MLNUserTrackingMode
        @Binding var slopeVisible: Bool
        private var slopeLayers: [MLNRasterStyleLayer] = []

        init(trackingMode: Binding<MLNUserTrackingMode>, slopeVisible: Binding<Bool>) {
            _trackingMode = trackingMode
            _slopeVisible = slopeVisible
        }

        func setSlopeVisible(_ visible: Bool) {
            for layer in slopeLayers where layer.isVisible != visible {
                layer.isVisible = visible
            }
        }

        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            // Keeps the button in sync when MapLibre resets tracking to
            // .none on its own, e.g. the user panning the map away.
            trackingMode = mode
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            slopeLayers = ["norway-slope-layer", "sweden-slope-layer"].compactMap {
                style.layer(withIdentifier: $0) as? MLNRasterStyleLayer
            }
            setSlopeVisible(slopeVisible)
        }
    }
}

#Preview {
    MapLibrePOCView()
}
