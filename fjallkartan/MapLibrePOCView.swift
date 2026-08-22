import SwiftUI
import MapLibre

// Throwaway POC to compare browsing feel against the MapKit-based MapView.
// Lantmäteriet + Kartverket raster tiles, stacked like the production
// MapView (Lantmäteriet first as the opaque base, Kartverket second on top
// for the border) — but with no no-data-to-transparent pixel rewrite, so
// Kartverket's opaque cream fill (from ~z15) will cover Lantmäteriet there
// instead of showing through. Freehand distance measurement, long-press pin
// dropping, and the elevation profile (via `ElevationProfile`/`ElevationService`)
// are wired up, mirroring MapView/MeasureCaptureView/ContentView.
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

private final class SavedPinMapAnnotation: NSObject, MLNAnnotation {
    let coordinate: CLLocationCoordinate2D
    let pin: SavedPin

    var title: String? { pin.displayName.isEmpty ? nil : pin.displayName }
    var subtitle: String? { nil }

    init(pin: SavedPin) {
        coordinate = pin.coordinate.coordinate
        self.pin = pin
    }
}

private final class SavedPinMarkerView: MLNAnnotationView {
    static let reuseIdentifier = "SavedPinMarker"

    private let iconView = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        scalesWithViewingDistance = false
        let diameter: CGFloat = 28
        bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        backgroundColor = .systemIndigo
        layer.cornerRadius = diameter / 2
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)

        iconView.image = UIImage(systemName: "bookmark.fill")
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.frame = bounds.insetBy(dx: 6, dy: 6)
        addSubview(iconView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class MapLibreMeasureCaptureView: UIView, UIGestureRecognizerDelegate {
    var anchorProvider: (() -> CLLocationCoordinate2D?)?
    var onStrokeProgress: ((Double) -> Void)?
    var onStrokeFinished: (([CLLocationCoordinate2D]) -> Void)?

    private weak var mapView: MLNMapView?

    private let casingLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()

    private var activeTouch: UITouch?
    private var screenPoints: [CGPoint] = []
    private var lastCoordinate: CLLocationCoordinate2D?
    private var runningMeters: Double = 0
    private var anchorScreenPoint: CGPoint?

    private let minSampleSpacing: CGFloat = 3
    private let simplifyTolerance: CGFloat = 2

    init(mapView: MLNMapView) {
        self.mapView = mapView
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isMultipleTouchEnabled = true

        for (layer, color, width) in [
            (casingLayer, MeasurementStyle.casingColor, MeasurementStyle.casingWidth),
            (strokeLayer, MeasurementStyle.strokeColor, MeasurementStyle.lineWidth),
        ] {
            layer.fillColor = UIColor.clear.cgColor
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            layer.lineCap = .round
            layer.lineJoin = .round
            self.layer.addSublayer(layer)
        }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        addGestureRecognizer(twoFingerPan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    // MARK: - Map gesture handlers

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let mapView else { return }
        switch recognizer.state {
        case .began:
            cancelStroke()
        case .changed:
            let scale = recognizer.scale
            guard scale > 0 else { return }
            mapView.zoomLevel += log2(scale)
            recognizer.scale = 1.0
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard let mapView else { return }
        switch recognizer.state {
        case .began:
            cancelStroke()
        case .changed:
            let translation = recognizer.translation(in: mapView)
            let centerPt = mapView.convert(mapView.centerCoordinate, toPointTo: mapView)
            let newCenterPt = CGPoint(x: centerPt.x - translation.x, y: centerPt.y - translation.y)
            mapView.centerCoordinate = mapView.convert(newCenterPt, toCoordinateFrom: mapView)
            recognizer.setTranslation(.zero, in: mapView)
        default:
            break
        }
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if (event?.allTouches?.count ?? touches.count) > 1 {
            cancelStroke()
            return
        }
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch

        let point = touch.location(in: self)
        let coordinate = coordinate(for: point)

        screenPoints = [point]
        lastCoordinate = coordinate
        runningMeters = 0
        anchorScreenPoint = nil

        if let anchor = anchorProvider?() {
            runningMeters = DistanceMeasurement.meters(from: anchor, to: coordinate)
            anchorScreenPoint = screenPoint(for: anchor)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if (event?.allTouches?.count ?? touches.count) > 1 {
            cancelStroke()
            return
        }
        guard let active = activeTouch, touches.contains(active),
              let previousPoint = screenPoints.last else { return }

        let point = active.location(in: self)
        guard hypot(point.x - previousPoint.x, point.y - previousPoint.y) >= minSampleSpacing else { return }

        let coordinate = coordinate(for: point)
        if let last = lastCoordinate {
            runningMeters += DistanceMeasurement.meters(from: last, to: coordinate)
        }
        screenPoints.append(point)
        lastCoordinate = coordinate

        onStrokeProgress?(runningMeters)
        redrawPreview()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }

        let simplified = LineSimplifier.simplify(screenPoints, tolerance: simplifyTolerance)
        let coordinates = simplified.map(coordinate(for:))
        resetStroke()
        onStrokeFinished?(coordinates.count >= 2 ? coordinates : [])
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
        cancelStroke()
    }

    private func cancelStroke() {
        guard activeTouch != nil else { return }
        resetStroke()
        onStrokeFinished?([])
    }

    private func resetStroke() {
        activeTouch = nil
        screenPoints.removeAll()
        lastCoordinate = nil
        anchorScreenPoint = nil
        runningMeters = 0
        casingLayer.path = nil
        strokeLayer.path = nil
    }

    // MARK: - Drawing

    private func redrawPreview() {
        guard !screenPoints.isEmpty else {
            casingLayer.path = nil
            strokeLayer.path = nil
            return
        }

        let path = UIBezierPath()
        if let anchorScreenPoint {
            path.move(to: anchorScreenPoint)
            path.addLine(to: screenPoints[0])
        } else {
            path.move(to: screenPoints[0])
        }
        for point in screenPoints.dropFirst() {
            path.addLine(to: point)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        casingLayer.frame = bounds
        strokeLayer.frame = bounds
        casingLayer.path = path.cgPath
        strokeLayer.path = path.cgPath
        CATransaction.commit()
    }

    // MARK: - Conversion

    private func coordinate(for point: CGPoint) -> CLLocationCoordinate2D {
        mapView?.convert(point, toCoordinateFrom: self) ?? kCLLocationCoordinate2DInvalid
    }

    private func screenPoint(for coordinate: CLLocationCoordinate2D) -> CGPoint? {
        mapView.map { $0.convert(coordinate, toPointTo: self) }
    }
}

struct MapLibrePOCView: View {
    @State private var trackingMode: MLNUserTrackingMode = .none
    @State private var slopeVisible = false
    @State private var download = OfflineDownloadState()
    @State private var showSavedRoutes = false
    @State private var savedRoutesModel: SavedRoutesModel? = {
        guard let store = try? SavedRouteStore() else { return nil }
        return SavedRoutesModel(store: store)
    }()

    @State private var measurement = DistanceMeasurement()
    @State private var elevation = ElevationProfile()
    @State private var isElevationPresented = false
    @State private var routeFitToken = 0
    @State private var savedPinsModel: SavedPinsModel? = {
        guard let store = try? SavedPinStore() else { return nil }
        return SavedPinsModel(store: store)
    }()
    @State private var pinDetail: SavedPin?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MapLibreRasterMap(trackingMode: $trackingMode, slopeVisible: $slopeVisible,
                              measurement: measurement,
                              routeCoordinates: measurement.coordinates,
                              routeFitToken: routeFitToken,
                              pins: savedPinsModel?.pins ?? [],
                              download: download,
                              onDropPin: { coordinate in
                                  savedPinsModel?.save(SavedPin(coordinate: Coord(coordinate)))
                              },
                              onOpenPinDetail: { pin in
                                  pinDetail = pin
                              })
                .ignoresSafeArea()
            VStack(spacing: 12) {
                measureToggleButton
                slopeToggleButton
                userLocationButton
                savedRoutesButton
                downloadButton
            }
            .padding()
        }
        .overlay(alignment: .top) {
            MeasureReadoutView(measurement: measurement, elevation: elevation) {
                isElevationPresented = true
            } onClose: {
                measurement.clear()
                elevation.clear()
            }
            .padding(.top, 16)
        }
        .alert("Offline download failed", isPresented: download.errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(download.errorMessage ?? "")
        }
        .sheet(isPresented: $showSavedRoutes) {
            if let savedRoutesModel {
                SavedRoutesSheet(model: savedRoutesModel, hasUnsavedRoute: false) { route in
                    measurement.load(route)
                    elevation.load(route)
                    routeFitToken += 1
                }
            }
        }
        .sheet(item: $pinDetail) { pin in
            PinDetailSheet(pin: pin,
                          onSave: { updated in savedPinsModel?.save(updated) },
                          onDelete: { savedPinsModel?.delete(pin) })
        }
        .sheet(isPresented: $isElevationPresented) {
            ElevationProfileSheet(profile: elevation)
        }
        // Debounced so tracing a long route in several strokes does not start
        // an elevation tile fetch per stroke; `task(id:)` cancels the previous run
        // whenever the route changes again.
        .task(id: measurement.version) {
            guard !measurement.isEmpty else {
                elevation.clear()
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await elevation.update(for: measurement.coordinates)
        }
    }

    private var measureToggleButton: some View {
        Button {
            measurement.isMeasuring.toggle()
        } label: {
            Image(systemName: "ruler")
                .font(.system(size: 18, weight: .medium))
                .symbolVariant(measurement.isMeasuring ? .fill : .none)
                .foregroundStyle(measurement.isMeasuring ? Color.accentColor : Color.primary)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
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
    let measurement: DistanceMeasurement
    let routeCoordinates: [CLLocationCoordinate2D]
    var routeFitToken: Int = 0
    let pins: [SavedPin]
    let download: OfflineDownloadState
    var onDropPin: ((CLLocationCoordinate2D) -> Void)?
    var onOpenPinDetail: ((SavedPin) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(trackingMode: $trackingMode, slopeVisible: $slopeVisible) }

    func makeUIView(context: Context) -> MLNMapView {
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(500 * 1024 * 1024) { _ in } // 500mb

        let mapView = MLNMapView(frame: .zero, styleURL: Self.styleURL)
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.showsUserLocation = true
        mapView.isPitchEnabled = false
        mapView.setCenter(
            CLLocationCoordinate2D(latitude: 62.0, longitude: 15.0),
            zoomLevel: 5,
            animated: false
        )
        download.attach(mapView: mapView)
        context.coordinator.installCaptureView(on: mapView, measurement: measurement)
        context.coordinator.installLongPressRecognizer(on: mapView)
        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        // Only push down when the button (not the map itself, e.g. via a
        // user pan) caused the change, to avoid fighting MapLibre's own
        // reset-to-.none-on-pan behaviour.
        if uiView.userTrackingMode != trackingMode {
            uiView.setUserTrackingMode(trackingMode, animated: true, completionHandler: nil)
        }
        context.coordinator.onDropPin = onDropPin
        context.coordinator.onOpenPinDetail = onOpenPinDetail
        context.coordinator.setSlopeVisible(slopeVisible)
        context.coordinator.setRoute(routeCoordinates, on: uiView)
        context.coordinator.fitRouteIfNeeded(on: uiView, fitToken: routeFitToken)
        context.coordinator.setMeasuring(measurement.isMeasuring, on: uiView)
        context.coordinator.syncPins(on: uiView, pins: pins)
        context.coordinator.setLongPressEnabled(!measurement.isMeasuring)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        @Binding var trackingMode: MLNUserTrackingMode
        @Binding var slopeVisible: Bool
        private var slopeLayers: [MLNRasterStyleLayer] = []
        private var routeSource: MLNShapeSource?
        private var renderedRouteCoordinates: [CLLocationCoordinate2D] = []
        private var renderedFitToken = 0
        /// Coordinates requested before the source existed (e.g. a route
        /// selected while the style was still loading), applied once ready.
        private var pendingRouteCoordinates: [CLLocationCoordinate2D] = []

        private weak var mapView: MLNMapView?
        private var captureView: MapLibreMeasureCaptureView?
        private weak var longPressRecognizer: UILongPressGestureRecognizer?
        private var renderedPins: [SavedPin] = []
        var onDropPin: ((CLLocationCoordinate2D) -> Void)?
        var onOpenPinDetail: ((SavedPin) -> Void)?

        init(trackingMode: Binding<MLNUserTrackingMode>, slopeVisible: Binding<Bool>) {
            _trackingMode = trackingMode
            _slopeVisible = slopeVisible
        }

        // MARK: - Measuring

        func installCaptureView(on map: MLNMapView, measurement: DistanceMeasurement) {
            mapView = map
            let capture = MapLibreMeasureCaptureView(mapView: map)
            capture.translatesAutoresizingMaskIntoConstraints = false
            capture.anchorProvider = { [weak measurement] in measurement?.anchor }
            capture.onStrokeProgress = { [weak measurement] meters in
                measurement?.previewMeters = meters
            }
            capture.onStrokeFinished = { [weak measurement] coordinates in
                measurement?.appendStroke(coordinates)
            }

            map.addSubview(capture)
            NSLayoutConstraint.activate([
                capture.topAnchor.constraint(equalTo: map.topAnchor),
                capture.bottomAnchor.constraint(equalTo: map.bottomAnchor),
                capture.leadingAnchor.constraint(equalTo: map.leadingAnchor),
                capture.trailingAnchor.constraint(equalTo: map.trailingAnchor),
            ])
            captureView = capture
        }

        /// MapLibre's gesture recognizers are attached directly to the map view itself —
        /// an ancestor of the capture view — so they still receive the same
        /// touches even once the capture view is on top. They must be
        /// disabled explicitly, or a single-finger drag both draws *and*
        /// pans the map underneath it.
        func setMeasuring(_ isMeasuring: Bool, on map: MLNMapView) {
            guard let captureView, captureView.isUserInteractionEnabled != isMeasuring else { return }
            captureView.isUserInteractionEnabled = isMeasuring
            map.isScrollEnabled = !isMeasuring
            map.isZoomEnabled = !isMeasuring
            map.isRotateEnabled = !isMeasuring
            if isMeasuring {
                map.bringSubviewToFront(captureView)
            }
        }

        // MARK: - Saved pins

        func syncPins(on map: MLNMapView, pins: [SavedPin]) {
            guard pins != renderedPins else { return }
            renderedPins = pins

            let existing = map.annotations?.compactMap { $0 as? SavedPinMapAnnotation } ?? []
            map.removeAnnotations(existing)
            map.addAnnotations(pins.map { SavedPinMapAnnotation(pin: $0) })
        }

        func installLongPressRecognizer(on map: MLNMapView) {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            recognizer.minimumPressDuration = 0.5
            map.addGestureRecognizer(recognizer)
            longPressRecognizer = recognizer
        }

        func setLongPressEnabled(_ isEnabled: Bool) {
            longPressRecognizer?.isEnabled = isEnabled
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let mapView else { return }
            let point = recognizer.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onDropPin?(coordinate)
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
            syncDistanceMarkers(on: mapView, force: true)
        }

        /// Recenters on the route, gated by `fitToken` so this only fires when
        /// a saved route is loaded, never on every freehand stroke.
        func fitRouteIfNeeded(on mapView: MLNMapView, fitToken: Int) {
            guard fitToken != renderedFitToken else { return }
            renderedFitToken = fitToken

            let coordinates = pendingRouteCoordinates
            guard coordinates.count >= 2 else { return }

            var bounds = MLNCoordinateBounds(sw: coordinates[0], ne: coordinates[0])
            for coordinate in coordinates {
                bounds.sw.longitude = min(bounds.sw.longitude, coordinate.longitude)
                bounds.sw.latitude = min(bounds.sw.latitude, coordinate.latitude)
                bounds.ne.longitude = max(bounds.ne.longitude, coordinate.longitude)
                bounds.ne.latitude = max(bounds.ne.latitude, coordinate.latitude)
            }
            mapView.setVisibleCoordinateBounds(bounds,
                                               edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40),
                                               animated: true,
                                               completionHandler: nil)
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
            if let routeMarker = annotation as? RouteDistanceMarker {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: RouteDistanceMarkerView.reuseIdentifier)
                    as? RouteDistanceMarkerView
                    ?? RouteDistanceMarkerView(reuseIdentifier: RouteDistanceMarkerView.reuseIdentifier)
                view.annotation = routeMarker
                return view
            }
            if annotation is SavedPinMapAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: SavedPinMarkerView.reuseIdentifier)
                    ?? SavedPinMarkerView(reuseIdentifier: SavedPinMarkerView.reuseIdentifier)
            }
            return nil
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            !(annotation is RouteDistanceMarker) && !(annotation is SavedPinMapAnnotation)
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let pinAnnotation = annotation as? SavedPinMapAnnotation else { return }
            onOpenPinDetail?(pinAnnotation.pin)
            mapView.deselectAnnotation(pinAnnotation, animated: false)
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
