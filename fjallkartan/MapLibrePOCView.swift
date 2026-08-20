import SwiftUI
import MapLibre

// Throwaway POC to compare browsing feel against the MapKit-based MapView.
// Lantmäteriet + Kartverket raster tiles, stacked like the production
// MapView (Lantmäteriet first as the opaque base, Kartverket second on top
// for the border) — but with no no-data-to-transparent pixel rewrite, so
// Kartverket's opaque cream fill (from ~z15) will cover Lantmäteriet there
// instead of showing through. No measurement/elevation.
// Delete once the comparison is done.

private final class RouteDistanceMarker: NSObject, MLNAnnotation {
    let coordinate: CLLocationCoordinate2D
    let meters: Double
    var title: String? { nil }
    var subtitle: String? { nil }

    var label: String { DistanceMeasurement.markerLabel(meters: meters) }

    init(coordinate: CLLocationCoordinate2D, meters: Double) {
        self.coordinate = coordinate
        self.meters = meters
    }
}

private final class RouteDistanceMarkerView: MLNAnnotationView {
    static let reuseIdentifier = "RouteDistanceMarker"

    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        isUserInteractionEnabled = false
        scalesWithViewingDistance = false
        backgroundColor = MeasurementStyle.casingColor
        layer.borderWidth = 2
        layer.borderColor = MeasurementStyle.strokeColor.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)

        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .label
        label.textAlignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var annotation: MLNAnnotation? {
        didSet { applyAnnotation() }
    }

    private func applyAnnotation() {
        guard let marker = annotation as? RouteDistanceMarker else { return }
        label.text = marker.label
        accessibilityLabel = marker.label

        let height: CGFloat = 20
        let width = max(height, (label.intrinsicContentSize.width + 14).rounded())
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        label.frame = bounds
        layer.cornerRadius = height / 2
    }
}

struct MapLibrePOCView: View {
    @State private var trackingMode: MLNUserTrackingMode = .none
    @State private var slopeVisible = false
    @State private var download = OfflineDownloadState()
    @State private var routeCoordinates: [CLLocationCoordinate2D] = []
    @State private var showSavedRoutes = false
    @State private var savedRoutesModel: SavedRoutesModel? = {
        guard let store = try? SavedRouteStore() else { return nil }
        return SavedRoutesModel(store: store)
    }()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MapLibreRasterMap(trackingMode: $trackingMode, slopeVisible: $slopeVisible,
                              routeCoordinates: routeCoordinates, download: download)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                slopeToggleButton
                userLocationButton
                savedRoutesButton
                downloadButton
            }
            .padding()
        }
        .alert("Offline download failed", isPresented: download.errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(download.errorMessage ?? "")
        }
        .sheet(isPresented: $showSavedRoutes) {
            if let savedRoutesModel {
                SavedRoutesSheet(model: savedRoutesModel, hasUnsavedRoute: false) { route in
                    routeCoordinates = route.coordinates.map(\.coordinate)
                }
            }
        }
    }

    private var savedRoutesButton: some View {
        Button {
            showSavedRoutes = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
        }
        .disabled(savedRoutesModel == nil)
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
    let routeCoordinates: [CLLocationCoordinate2D]
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
        context.coordinator.setRoute(routeCoordinates, on: uiView)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        @Binding var trackingMode: MLNUserTrackingMode
        @Binding var slopeVisible: Bool
        private var slopeLayers: [MLNRasterStyleLayer] = []
        private var routeSource: MLNShapeSource?
        private var renderedRouteCoordinates: [CLLocationCoordinate2D] = []
        /// Coordinates requested before the source existed (e.g. a route
        /// selected while the style was still loading), applied once ready.
        private var pendingRouteCoordinates: [CLLocationCoordinate2D] = []

        init(trackingMode: Binding<MLNUserTrackingMode>, slopeVisible: Binding<Bool>) {
            _trackingMode = trackingMode
            _slopeVisible = slopeVisible
        }

        func setSlopeVisible(_ visible: Bool) {
            for layer in slopeLayers where layer.isVisible != visible {
                layer.isVisible = visible
            }
        }

        func setRoute(_ coordinates: [CLLocationCoordinate2D], on mapView: MLNMapView) {
            pendingRouteCoordinates = coordinates
            guard routeSource != nil else { return }
            applyPendingRoute(on: mapView)
        }

        private func applyPendingRoute(on mapView: MLNMapView) {
            guard let routeSource else { return }
            let coordinates = pendingRouteCoordinates
            guard !Self.coordinatesEqual(coordinates, renderedRouteCoordinates) else { return }
            renderedRouteCoordinates = coordinates

            guard coordinates.count >= 2 else {
                routeSource.shape = nil
                syncDistanceMarkers(on: mapView, force: true)
                return
            }

            var mutableCoordinates = coordinates
            routeSource.shape = MLNPolylineFeature(coordinates: &mutableCoordinates, count: UInt(mutableCoordinates.count))

            var bounds = MLNCoordinateBounds(sw: coordinates[0], ne: coordinates[0])
            for coordinate in coordinates {
                bounds.sw.longitude = min(bounds.sw.longitude, coordinate.longitude)
                bounds.sw.latitude = min(bounds.sw.latitude, coordinate.latitude)
                bounds.ne.longitude = max(bounds.ne.longitude, coordinate.longitude)
                bounds.ne.latitude = max(bounds.ne.latitude, coordinate.latitude)
            }
            mapView.setVisibleCoordinateBounds(bounds,
                                               edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40),
                                               animated: true)
            syncDistanceMarkers(on: mapView, force: true)
        }

        // MARK: - Distance markers

        private var markerAnnotations: [RouteDistanceMarker] = []
        private var renderedMarkerSpacing: Double = 0

        /// Mirrors MapView's `syncDistanceMarkers`: spacing widens as the map
        /// zooms out so km markers stay legible instead of piling up.
        func syncDistanceMarkers(on mapView: MLNMapView, force: Bool = false) {
            let spacing = renderedRouteCoordinates.count >= 2
                ? DistanceMeasurement.markerSpacing(forZoomLevel: mapView.zoomLevel,
                                                    routeLength: DistanceMeasurement.length(of: renderedRouteCoordinates))
                : 0
            guard force || spacing != renderedMarkerSpacing else { return }
            renderedMarkerSpacing = spacing

            mapView.removeAnnotations(markerAnnotations)
            markerAnnotations = []
            guard spacing > 0 else { return }

            markerAnnotations = DistanceMeasurement.distanceMarkers(along: renderedRouteCoordinates, spacing: spacing).map {
                RouteDistanceMarker(coordinate: $0.coordinate, meters: $0.meters)
            }
            mapView.addAnnotations(markerAnnotations)
        }

        // CLLocationCoordinate2D isn't Equatable, so routes are compared
        // element-wise rather than relying on a version token like MapView does.
        private static func coordinatesEqual(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Bool {
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            syncDistanceMarkers(on: mapView)
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard annotation is RouteDistanceMarker else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: RouteDistanceMarkerView.reuseIdentifier)
                as? RouteDistanceMarkerView
                ?? RouteDistanceMarkerView(reuseIdentifier: RouteDistanceMarkerView.reuseIdentifier)
            view.annotation = annotation
            return view
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            !(annotation is RouteDistanceMarker)
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

            let source = MLNShapeSource(identifier: "route", shape: nil, options: nil)
            style.addSource(source)
            routeSource = source

            let casingLayer = MLNLineStyleLayer(identifier: "route-casing", source: source)
            casingLayer.lineColor = NSExpression(forConstantValue: MeasurementStyle.casingColor)
            casingLayer.lineWidth = NSExpression(forConstantValue: MeasurementStyle.casingWidth)
            casingLayer.lineCap = NSExpression(forConstantValue: "round")
            casingLayer.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(casingLayer)

            let lineLayer = MLNLineStyleLayer(identifier: "route-line", source: source)
            lineLayer.lineColor = NSExpression(forConstantValue: MeasurementStyle.strokeColor)
            lineLayer.lineWidth = NSExpression(forConstantValue: MeasurementStyle.lineWidth)
            lineLayer.lineCap = NSExpression(forConstantValue: "round")
            lineLayer.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(lineLayer)

            applyPendingRoute(on: mapView)
        }
    }
}

#Preview {
    MapLibrePOCView()
}
